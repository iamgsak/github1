import { query, queryOne, type RequestContext } from '@/lib/db';

export interface GuestListItem {
  id: string; guestCode: string | null; fullName: string;
  email: string | null; phone: string | null; city: string | null;
  totalStays: number; totalRevenue: number; lastStay: string | null; isBlacklisted: boolean;
}

export async function listGuests(
  organizationId: string,
  opts: { q?: string; page?: number; pageSize?: number } = {},
  ctx?: RequestContext,
): Promise<{ items: GuestListItem[]; total: number }> {
  const page = Math.max(opts.page ?? 1, 1);
  const pageSize = Math.min(Math.max(opts.pageSize ?? 25, 1), 200);

  const params: unknown[] = [organizationId];
  let search = '';
  if (opts.q) {
    params.push(`%${opts.q}%`);
    search = ` AND (g.full_name ILIKE $2 OR g.email::text ILIKE $2 OR g.phone ILIKE $2
                    OR g.guest_code ILIKE $2)`;
  }

  const totalRow = await queryOne<{ count: string }>(
    `SELECT count(*)::int AS count FROM guests g WHERE g.organization_id = $1${search}`,
    params, ctx,
  );

  params.push(pageSize, (page - 1) * pageSize);

  // Stay statistics are aggregated from completed reservations, so the
  // profile shows real history rather than a counter that could drift.
  const rows = await query<Record<string, string>>(
    `SELECT g.id, g.guest_code, g.full_name, g.email, g.phone, g.city, g.is_blacklisted,
            COALESCE(s.stays, 0) AS total_stays, COALESCE(s.revenue, 0) AS total_revenue, s.last_stay
       FROM guests g
       LEFT JOIN LATERAL (
         SELECT count(*)::int AS stays, sum(r.total_amount) AS revenue,
                max(r.departure_date) AS last_stay
           FROM reservations r
          WHERE r.guest_id = g.id AND r.status <> 'CANCELLED'
       ) s ON true
      WHERE g.organization_id = $1${search}
      ORDER BY g.full_name
      LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params, ctx,
  );

  return {
    total: Number(totalRow?.count ?? 0),
    items: rows.map((r) => ({
      id: r.id, guestCode: r.guest_code ?? null, fullName: r.full_name,
      email: r.email ?? null, phone: r.phone ?? null, city: r.city ?? null,
      totalStays: Number(r.total_stays), totalRevenue: Number(r.total_revenue),
      lastStay: r.last_stay ?? null, isBlacklisted: String(r.is_blacklisted) === 'true',
    })),
  };
}
