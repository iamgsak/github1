import { Pool, type PoolClient, type QueryResultRow } from 'pg';

/**
 * Connection pool. Uses DATABASE_URL when set, otherwise falls back to
 * standard libpq environment variables (PGHOST/PGPORT/...), which is what
 * lets the app talk to a local unix-socket cluster in development.
 */
declare global {
  // eslint-disable-next-line no-var
  var __hotelErpPool: Pool | undefined;
}

function createPool(): Pool {
  const pool = new Pool(
    process.env.DATABASE_URL
      ? { connectionString: process.env.DATABASE_URL, max: 10 }
      : { max: 10 },
  );
  pool.on('error', (err) => console.error('[db] idle client error', err));
  return pool;
}

// Reused across hot reloads in development so we don't exhaust connections.
export const pool: Pool = globalThis.__hotelErpPool ?? createPool();
if (process.env.NODE_ENV !== 'production') globalThis.__hotelErpPool = pool;

export interface RequestContext {
  userId?: string | null;
  userEmail?: string | null;
  ip?: string | null;
  requestId?: string | null;
}

/**
 * Publishes the request context to the transaction so the database-side
 * audit trigger and RLS helpers know who is acting. SET LOCAL means it is
 * scoped to this transaction and cannot leak to the next borrower of this
 * pooled connection.
 */
async function applyContext(client: PoolClient, ctx?: RequestContext) {
  if (!ctx) return;
  const settings: Array<[string, string | null | undefined]> = [
    ['app.current_user_id', ctx.userId],
    ['app.current_user_email', ctx.userEmail],
    ['app.current_ip', ctx.ip],
    ['app.request_id', ctx.requestId],
  ];
  for (const [key, value] of settings) {
    if (value) await client.query('SELECT set_config($1, $2, true)', [key, value]);
  }
}

export async function query<T extends QueryResultRow = QueryResultRow>(
  text: string, params: unknown[] = [], ctx?: RequestContext,
): Promise<T[]> {
  const client = await pool.connect();
  try {
    // A context-carrying read still needs a transaction for SET LOCAL.
    if (ctx?.userId) {
      await client.query('BEGIN');
      await applyContext(client, ctx);
      const res = await client.query<T>(text, params as never[]);
      await client.query('COMMIT');
      return res.rows;
    }
    const res = await client.query<T>(text, params as never[]);
    return res.rows;
  } finally {
    client.release();
  }
}

export async function queryOne<T extends QueryResultRow = QueryResultRow>(
  text: string, params: unknown[] = [], ctx?: RequestContext,
): Promise<T | null> {
  const rows = await query<T>(text, params, ctx);
  return rows[0] ?? null;
}

/**
 * Runs `fn` inside a single transaction with the request context applied.
 * One business action is one transaction.
 */
export async function withTransaction<T>(
  fn: (client: PoolClient) => Promise<T>, ctx?: RequestContext,
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await applyContext(client, ctx);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}
