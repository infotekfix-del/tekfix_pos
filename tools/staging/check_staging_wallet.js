const { Client } = require('pg');
const dotenv = require('dotenv');
const fs = require('fs');

const envConfig = dotenv.parse(fs.readFileSync('.env.staging'));
const client = new Client({
  connectionString: envConfig.SUPABASE_DB_URL,
  ssl: { rejectUnauthorized: false }
});

async function check() {
  await client.connect();
  const wRes = await client.query("SELECT * FROM public.recharge_wallets WHERE shop_id = 'tekfix' AND wallet_id = 'WALLET_VI'");
  console.log('WALLET_VI:', JSON.stringify(wRes.rows[0], null, 2));

  const dRes = await client.query("SELECT * FROM public.recharge_deposits WHERE shop_id = 'tekfix' AND wallet_id = 'WALLET_VI' ORDER BY created_at DESC");
  console.log('DEPOSITS COUNT:', dRes.rows.length);
  console.log('DEPOSITS:', JSON.stringify(dRes.rows, null, 2));
  await client.end();
}
check().catch(console.error);
