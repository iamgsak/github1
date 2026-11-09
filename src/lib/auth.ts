import { randomBytes, scrypt as _scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';
import { cookies } from 'next/headers';
import { query, queryOne, withTransaction } from './db';

const scrypt = promisify(_scrypt) as (p: string, s: Buffer, k: number) => Promise<Buffer>;

export const SESSION_COOKIE = 'hotel_erp_session';
const SESSION_TTL_HOURS = 12;
const MAX_FAILED_ATTEMPTS = 5;
const LOCKOUT_MINUTES = 15;

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scrypt(password, salt, 64);
  return `${salt.toString('hex')}:${key.toString('hex')}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [saltHex, keyHex] = stored.split(':');
  if (!saltHex || !keyHex) return false;
  const key = await scrypt(password, Buffer.from(saltHex, 'hex'), 64);
  const expected = Buffer.from(keyHex, 'hex');
  // Constant-time: never leak how much of the hash matched.
  return key.length === expected.length && timingSafeEqual(key, expected);
}

const hashToken = (token: string) => createHash('sha256').update(token).digest('hex');

export interface SessionUser {
  id: string;
  email: string;
  fullName: string;
  organizationId: string | null;
  isPlatformAdmin: boolean;
  permissions: string[];
  properties: Array<{ id: string; code: string; name: string }>;
  roles: string[];
}

export interface LoginResult {
  ok: boolean;
  token?: string;
  error?: 'INVALID_CREDENTIALS' | 'ACCOUNT_LOCKED' | 'ACCOUNT_INACTIVE';
  retryAfterMinutes?: number;
}

export async function login(
  email: string, password: string,
  meta: { ip?: string | null; userAgent?: string | null } = {},
): Promise<LoginResult> {
  const row = await queryOne<{
    id: string; email: string; is_active: boolean;
    password_hash: string | null; failed_attempts: number; locked_until: Date | null;
  }>(
    `SELECT u.id, u.email, u.is_active,
            c.password_hash, c.failed_attempts, c.locked_until
       FROM users u
       LEFT JOIN user_credentials c ON c.user_id = u.id
      WHERE u.email = $1`,
    [email],
  );

  // Uniform failure for unknown accounts: do not confirm which emails exist.
  if (!row || !row.password_hash) {
    await recordAuditFailure(email, meta.ip ?? null);
    return { ok: false, error: 'INVALID_CREDENTIALS' };
  }

  if (row.locked_until && row.locked_until > new Date()) {
    const mins = Math.ceil((row.locked_until.getTime() - Date.now()) / 60000);
    return { ok: false, error: 'ACCOUNT_LOCKED', retryAfterMinutes: mins };
  }

  if (!row.is_active) return { ok: false, error: 'ACCOUNT_INACTIVE' };

  if (!(await verifyPassword(password, row.password_hash))) {
    const attempts = row.failed_attempts + 1;
    // Every placeholder is cast explicitly. Without the casts Postgres
    // deduces $2 as text from the CASE comparison and then conflicts with
    // the integer column in the SET clause.
    await query(
      `UPDATE user_credentials
          SET failed_attempts = $2::int,
              locked_until = CASE WHEN $2::int >= $3::int
                                  THEN now() + ($4::text || ' minutes')::interval END
        WHERE user_id = $1::uuid`,
      [row.id, attempts, MAX_FAILED_ATTEMPTS, String(LOCKOUT_MINUTES)],
    );
    await recordAuditFailure(email, meta.ip ?? null);
    return attempts >= MAX_FAILED_ATTEMPTS
      ? { ok: false, error: 'ACCOUNT_LOCKED', retryAfterMinutes: LOCKOUT_MINUTES }
      : { ok: false, error: 'INVALID_CREDENTIALS' };
  }

  const token = randomBytes(32).toString('base64url');

  await withTransaction(async (client) => {
    await client.query(
      `UPDATE user_credentials SET failed_attempts = 0, locked_until = NULL WHERE user_id = $1`,
      [row.id],
    );
    await client.query(`UPDATE users SET last_login_at = now() WHERE id = $1`, [row.id]);
    await client.query(
      `INSERT INTO user_sessions (user_id, token_hash, ip_address, user_agent, expires_at)
       VALUES ($1, $2, $3::inet, $4, now() + ($5 || ' hours')::interval)`,
      [row.id, hashToken(token), meta.ip || null, meta.userAgent || null, String(SESSION_TTL_HOURS)],
    );
    // user_id is uuid and record_id is text, so the id is passed twice
    // rather than reusing one placeholder for two different types.
    await client.query(
      `INSERT INTO audit_logs (user_id, user_email, action, module, table_name, record_id, ip_address)
       VALUES ($1, $2, 'LOGIN', 'SECURITY', 'user_sessions', $3, $4::inet)`,
      [row.id, row.email, row.id, meta.ip || null],
    );
  });

  return { ok: true, token };
}

async function recordAuditFailure(email: string, ip: string | null) {
  await query(
    `INSERT INTO audit_logs (user_email, action, module, table_name, ip_address)
     VALUES ($1, 'LOGIN_FAILED', 'SECURITY', 'users', $2::inet)`,
    [email, ip],
  );
}

export async function logout(token: string) {
  await query(
    `UPDATE user_sessions SET revoked_at = now()
      WHERE token_hash = $1 AND revoked_at IS NULL`,
    [hashToken(token)],
  );
}

/**
 * Resolves the session cookie to a user with every permission and property
 * they hold. Returns null for an expired, revoked or unknown session, or
 * for a user since deactivated -- which is what makes deactivation take
 * effect on the very next request.
 */
export async function getSessionUser(): Promise<SessionUser | null> {
  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  if (!token) return null;

  const row = await queryOne<{
    id: string; email: string; full_name: string;
    organization_id: string | null; is_platform_admin: boolean;
    permissions: string[] | null; roles: string[] | null;
  }>(
    `SELECT u.id, u.email, u.full_name, u.organization_id, u.is_platform_admin,
            ARRAY(SELECT DISTINCT rp.permission_code
                    FROM user_roles ur
                    JOIN role_permissions rp ON rp.role_id = ur.role_id
                   WHERE ur.user_id = u.id
                     AND (ur.expires_at IS NULL OR ur.expires_at > now())) AS permissions,
            ARRAY(SELECT DISTINCT r.code
                    FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                   WHERE ur.user_id = u.id) AS roles
       FROM user_sessions s
       JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = $1
        AND s.revoked_at IS NULL
        AND s.expires_at > now()
        AND u.is_active`,
    [hashToken(token)],
  );
  if (!row) return null;

  const properties = await query<{ id: string; code: string; name: string }>(
    `SELECT p.id, p.code, p.name
       FROM properties p
      WHERE p.organization_id = $2
        AND (EXISTS (SELECT 1 FROM user_roles ur
                      WHERE ur.user_id = $1
                        AND (ur.property_id IS NULL OR ur.property_id = p.id)
                        AND (ur.expires_at IS NULL OR ur.expires_at > now()))
             OR $3)
      ORDER BY p.name`,
    [row.id, row.organization_id, row.is_platform_admin],
  );

  // Touch last_seen_at without blocking the request.
  void query(`UPDATE user_sessions SET last_seen_at = now() WHERE token_hash = $1`, [
    hashToken(token),
  ]).catch(() => undefined);

  return {
    id: row.id,
    email: row.email,
    fullName: row.full_name,
    organizationId: row.organization_id,
    isPlatformAdmin: row.is_platform_admin,
    permissions: row.permissions ?? [],
    roles: row.roles ?? [],
    properties,
  };
}

export function can(user: SessionUser | null, permission: string): boolean {
  if (!user) return false;
  return user.isPlatformAdmin || user.permissions.includes(permission);
}
