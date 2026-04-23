#!/usr/bin/env node
// Create a Supabase auth user + set tenant_id.
// Usage: node .claude-scripts/create_user.js <email> <password> [tenant_uuid]
// Requires SUPABASE_DB_URL env.

const { Client } = require("pg");

const DEFAULT_TENANT = "00000000-0000-0000-0000-000000000001";

async function main() {
  const [, , email, password, tenantArg] = process.argv;
  if (!email || !password) {
    console.error("usage: node create_user.js <email> <password> [tenant_uuid]");
    process.exit(1);
  }
  const tenantId = tenantArg || DEFAULT_TENANT;
  const url = process.env.SUPABASE_DB_URL;
  if (!url) { console.error("missing SUPABASE_DB_URL env"); process.exit(1); }

  const c = new Client({
    connectionString: url.replace(/[?&]sslmode=[^&]*/g, ""),
    ssl: { rejectUnauthorized: false },
  });
  await c.connect();
  try {
    // check if user exists
    const existing = await c.query(`SELECT id FROM auth.users WHERE email=$1`, [email]);
    if (existing.rowCount > 0) {
      console.error(`[FAIL] user ${email} already exists (id=${existing.rows[0].id})`);
      process.exit(1);
    }

    // insert user with bcrypt-hashed password
    // IMPORTANT: token fields must be '' not NULL or GoTrue throws
    // "Database error querying schema" on login.
    const ins = await c.query(
      `INSERT INTO auth.users (
         instance_id, id, aud, role, email, encrypted_password,
         email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
         created_at, updated_at, is_sso_user, is_anonymous,
         confirmation_token, recovery_token, email_change_token_new,
         email_change, email_change_token_current,
         phone_change, phone_change_token, reauthentication_token
       ) VALUES (
         '00000000-0000-0000-0000-000000000000',
         gen_random_uuid(),
         'authenticated',
         'authenticated',
         $1,
         crypt($2, gen_salt('bf')),
         NOW(),
         jsonb_build_object('tenant_id', $3::text, 'provider', 'email', 'providers', jsonb_build_array('email')),
         jsonb_build_object('email_verified', true),
         NOW(), NOW(), FALSE, FALSE,
         '', '', '', '', '', '', '', ''
       ) RETURNING id, email, raw_app_meta_data`,
      [email, password, tenantId]
    );
    console.log(`[OK] user created:`);
    console.log(`     id    = ${ins.rows[0].id}`);
    console.log(`     email = ${ins.rows[0].email}`);
    console.log(`     meta  = ${JSON.stringify(ins.rows[0].raw_app_meta_data)}`);

    // insert an identity row (required by Supabase Auth for email login)
    // IMPORTANT: provider_id must be the user UUID (as text), not the email.
    await c.query(
      `INSERT INTO auth.identities (
         id, user_id, identity_data, provider, provider_id,
         last_sign_in_at, created_at, updated_at
       ) VALUES (
         gen_random_uuid(),
         $1::uuid,
         jsonb_build_object('sub', $1::text, 'email', $2::text, 'email_verified', false, 'phone_verified', false),
         'email',
         $1::text,
         NOW(), NOW(), NOW()
       )`,
      [ins.rows[0].id, email]
    );
    console.log(`[OK] email identity inserted`);
    console.log(`\ndone. login with ${email} / ${password}`);
  } finally {
    await c.end();
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
