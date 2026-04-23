const { Client } = require("pg");

(async () => {
  const email = process.argv[2];
  if (!email) { console.error("usage: node add_identity.js <email>"); process.exit(1); }
  const c = new Client({
    connectionString: process.env.SUPABASE_DB_URL.replace(/[?&]sslmode=[^&]*/g, ""),
    ssl: { rejectUnauthorized: false },
  });
  await c.connect();
  const u = await c.query("SELECT id FROM auth.users WHERE email=$1", [email]);
  if (u.rowCount === 0) { console.error("no user"); process.exit(1); }
  const uid = u.rows[0].id;
  await c.query(
    `INSERT INTO auth.identities (
       id, user_id, identity_data, provider, provider_id,
       last_sign_in_at, created_at, updated_at
     ) VALUES (
       gen_random_uuid(), $1::uuid,
       jsonb_build_object('sub', $1::text, 'email', $2::text, 'email_verified', true, 'phone_verified', false),
       'email', $2::text,
       NOW(), NOW(), NOW()
     )`,
    [uid, email]
  );
  console.log(`[OK] identity inserted for ${email} (id=${uid})`);
  await c.end();
})().catch(e => { console.error(e.message); process.exit(1); });
