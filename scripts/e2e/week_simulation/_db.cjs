// Shared DB helper for week simulation
const { Client } = require('pg');

const TENANT = '00000000-0000-0000-0000-000000000001';
const ADMIN_UID = '39fd694d-3af6-4978-beab-6e826dff7246';
const CHANNEL_ID = 1; // LC-MAIN — 主社群

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

async function setJwt(client) {
  await client.query(`SELECT set_config('request.jwt.claims', $1, true)`,
    [JSON.stringify({ tenant_id: TENANT, sub: ADMIN_UID, role: 'authenticated' })]);
}

module.exports = { newClient, setJwt, TENANT, ADMIN_UID, CHANNEL_ID };
