const { Client } = require("pg");

(async () => {
  const email = process.argv[2];
  const c = new Client({
    connectionString: process.env.SUPABASE_DB_URL.replace(/[?&]sslmode=[^&]*/g, ""),
    ssl: { rejectUnauthorized: false },
  });
  await c.connect();
  const u = await c.query(
    `SELECT id, aud, role, email, encrypted_password IS NOT NULL AS has_pwd,
            email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
            instance_id, is_sso_user, is_anonymous, banned_until, deleted_at
       FROM auth.users WHERE email=$1`, [email]);
  console.log("user:", JSON.stringify(u.rows[0], null, 2));
  if (u.rows[0]) {
    const i = await c.query(
      `SELECT provider, provider_id, identity_data, last_sign_in_at
         FROM auth.identities WHERE user_id=$1`, [u.rows[0].id]);
    console.log("identities:", JSON.stringify(i.rows, null, 2));
  }
  await c.end();
})().catch(e => { console.error(e); process.exit(1); });
