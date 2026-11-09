#!/usr/bin/env node
/**
 * Creates demo staff accounts for local development.
 *
 * Passwords are scrypt-hashed with the same code path the application
 * uses. DEMO ONLY -- refuses to run when NODE_ENV=production.
 */
import { randomBytes, scrypt as _scrypt } from 'node:crypto';
import { promisify } from 'node:util';
import pg from 'pg';

const scrypt = promisify(_scrypt);

if (process.env.NODE_ENV === 'production') {
  console.error('Refusing to seed demo accounts with NODE_ENV=production.');
  process.exit(1);
}

const DEMO_PASSWORD = process.env.DEMO_PASSWORD ?? 'Amoha@2026';

const USERS = [
  ['owner@hotelamoha.test',        'Ravi Amoha',   'OWNER',           null],
  ['gm@hotelamoha.test',           'Sunita Desai', 'GENERAL_MANAGER', null],
  ['frontdesk@hotelamoha.test',    'Kiran Kumar',  'FRONT_DESK',      'AMOHA'],
  ['accounts@hotelamoha.test',     'Deepa Raman',  'ACCOUNTANT',      'AMOHA'],
  ['housekeeping@hotelamoha.test', 'Lakshmi Bai',  'HOUSEKEEPING',    'AMOHA'],
];

async function hashPassword(password) {
  const salt = randomBytes(16);
  const key = await scrypt(password, salt, 64);
  return `${salt.toString('hex')}:${key.toString('hex')}`;
}

const pool = new pg.Pool(
  process.env.DATABASE_URL ? { connectionString: process.env.DATABASE_URL } : {},
);

const client = await pool.connect();
try {
  await client.query('BEGIN');

  const { rows: orgs } = await client.query(
    `SELECT id FROM organizations ORDER BY created_at LIMIT 1`);
  if (orgs.length === 0) throw new Error('No organization found. Run the demo seed first.');
  const orgId = orgs[0].id;

  const hash = await hashPassword(DEMO_PASSWORD);

  for (const [email, fullName, roleCode, propertyCode] of USERS) {
    const { rows: userRows } = await client.query(
      `INSERT INTO users (id, organization_id, email, full_name)
       VALUES (gen_random_uuid(), $1, $2, $3)
       ON CONFLICT (email) DO UPDATE SET full_name = EXCLUDED.full_name
       RETURNING id`,
      [orgId, email, fullName],
    );
    const userId = userRows[0].id;

    await client.query(
      `INSERT INTO user_credentials (user_id, password_hash)
       VALUES ($1, $2)
       ON CONFLICT (user_id) DO UPDATE
         SET password_hash = EXCLUDED.password_hash, failed_attempts = 0, locked_until = NULL`,
      [userId, hash],
    );

    // property_id NULL means the grant covers every property in the org.
    await client.query(
      `INSERT INTO user_roles (user_id, role_id, property_id)
       SELECT $1, r.id,
              CASE WHEN $3::text IS NULL THEN NULL
                   ELSE (SELECT p.id FROM properties p
                          WHERE p.organization_id = $4 AND p.code = $3) END
         FROM roles r WHERE r.code = $2 AND r.is_system
       ON CONFLICT DO NOTHING`,
      [userId, roleCode, propertyCode, orgId],
    );

    console.log(`  ${email.padEnd(32)} ${roleCode}`);
  }

  await client.query('COMMIT');
  console.log(`\nDemo accounts ready. Password for all: ${DEMO_PASSWORD}`);
} catch (err) {
  await client.query('ROLLBACK');
  console.error('Seeding failed:', err.message);
  process.exitCode = 1;
} finally {
  client.release();
  await pool.end();
}
