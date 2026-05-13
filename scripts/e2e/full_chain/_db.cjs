// Shared DB connection helper for E2E full-chain scripts.
// 連 anfyoeviuhmzzrhilwtm dev pooler、所有 step script 共用。
const { Client } = require('pg');

const TENANT = '00000000-0000-0000-0000-000000000001';
const ADMIN_UID = '39fd694d-3af6-4978-beab-6e826dff7246'; // cktalex@gmail.com

function newClient() {
  return new Client({
    host: 'aws-1-ap-southeast-1.pooler.supabase.com',
    port: 5432,
    user: 'postgres.anfyoeviuhmzzrhilwtm',
    password: '@Ss0929283575',
    database: 'postgres',
    ssl: { rejectUnauthorized: false },
  });
}

// SECURITY DEFINER RPC 依賴 _current_tenant_id() 從 JWT claim 取 tenant。
// 在 transaction 內呼叫 setJwt(client) 注入 claim、然後跑 RPC。
async function setJwt(client, { tenant = TENANT, sub = ADMIN_UID, role = 'authenticated' } = {}) {
  await client.query(`SELECT set_config('request.jwt.claims', $1, true)`,
    [JSON.stringify({ tenant_id: tenant, sub, role })]);
}

module.exports = { newClient, setJwt, TENANT, ADMIN_UID };
