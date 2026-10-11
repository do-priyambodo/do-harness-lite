/**
 * Singleton PostgreSQL / AlloyDB Connection Pool for Node.js (pg).
 *
 * Anti-pattern fixed:
 *   Creating `new Client()` + `await client.connect()` inside every HTTP request
 *   exhausts database max_connections under concurrency.
 *
 * Usage:
 *   const { query, pool } = require('./node_pg_pool');
 *   const { rows } = await query('SELECT * FROM records WHERE status = $1', ['OPEN']);
 */

const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.DB_HOST || process.env.PGHOST || '127.0.0.1',
  port: parseInt(process.env.DB_PORT || process.env.PGPORT || '5432', 10),
  user: process.env.DB_USER || process.env.PGUSER || 'postgres',
  password: process.env.DB_PASSWORD || process.env.DB_PASS || process.env.PGPASSWORD || '',
  database: process.env.DB_NAME || process.env.PGDATABASE || 'postgres',
  max: parseInt(process.env.DB_POOL_MAX || '20', 10),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error('[pg-pool] Unexpected error on idle database client:', err.message);
});

async function query(text, params) {
  return pool.query(text, params);
}

module.exports = {
  pool,
  query,
};
