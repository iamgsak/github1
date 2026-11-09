import { query, queryOne, type RequestContext } from '@/lib/db';

export interface ReservationListItem {
  id: string; reservationNumber: string; guestName: string; guestPhone: string | null;
  source: string | null; sourceCategory: string | null;
  roomTypeCode: string; roomNumber: string | null;
  arrivalDate: string; departureDate: string; nights: number;
  adults: number; children: number;
  totalAmount: number; paidAmount: number; balanceAmount: number;
  status: string; paymentStatus: string;
}

export interface ReservationFilters {
  status?: string; q?: string; from?: string; to?: string; page?: number; pageSize?: number;
}

export async function listReservations(
  propertyId: string, filters: ReservationFilters = {}, ctx?: RequestContext,
): Promise<{ items: ReservationListItem[]; total: number }> {
  const page = Math.max(filters.page ?? 1, 1);
  const pageSize = Math.min(Math.max(filters.pageSize ?? 25, 1), 200);

  // Parameterised throughout -- no string interpolation of user input.
  const where: string[] = ['r.property_id = $1'];
  const params: unknown[] = [propertyId];

  if (filters.status) { params.push(filters.status); where.push(`r.status = $${params.length}::reservation_status`); }
  if (filters.from)   { params.push(filters.from);   where.push(`r.departure_date >= $${params.length}::date`); }
  if (filters.to)     { params.push(filters.to);     where.push(`r.arrival_date <= $${params.length}::date`); }
  if (filters.q) {
    params.push(`%${filters.q}%`);
    const i = params.length;
    where.push(`(r.reservation_number ILIKE $${i} OR g.full_name ILIKE $${i}
                 OR g.phone ILIKE $${i} OR g.email::text ILIKE $${i}
                 OR r.external_reference ILIKE $${i})`);
  }

  const whereSql = where.join(' AND ');

  const totalRow = await queryOne<{ count: string }>(
    `SELECT count(DISTINCT r.id)::int AS count
       FROM reservations r JOIN guests g ON g.id = r.guest_id
      WHERE ${whereSql}`,
    params, ctx,
  );

  params.push(pageSize, (page - 1) * pageSize);

  const rows = await query<Record<string, string>>(
    `SELECT r.id, r.reservation_number, g.full_name AS guest_name, g.phone AS guest_phone,
            bs.name AS source, bs.category AS source_category,
            rt.code AS room_type_code, rm.room_number,
            r.arrival_date, r.departure_date, r.nights, r.adults, r.children,
            r.total_amount, r.paid_amount, r.balance_amount,
            r.status::text AS status, r.payment_status::text AS payment_status
       FROM reservations r
       JOIN guests g ON g.id = r.guest_id
       LEFT JOIN booking_sources bs ON bs.id = r.booking_source_id
       LEFT JOIN LATERAL (
         SELECT rr.room_type_id, rr.current_room_id FROM reservation_rooms rr
          WHERE rr.reservation_id = r.id ORDER BY rr.line_number LIMIT 1
       ) rr ON true
       LEFT JOIN room_types rt ON rt.id = rr.room_type_id
       LEFT JOIN rooms rm ON rm.id = rr.current_room_id
      WHERE ${whereSql}
      ORDER BY r.arrival_date DESC, r.reservation_number DESC
      LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params, ctx,
  );

  return {
    total: Number(totalRow?.count ?? 0),
    items: rows.map((r) => ({
      id: r.id, reservationNumber: r.reservation_number,
      guestName: r.guest_name, guestPhone: r.guest_phone ?? null,
      source: r.source ?? null, sourceCategory: r.source_category ?? null,
      roomTypeCode: r.room_type_code ?? '—', roomNumber: r.room_number ?? null,
      arrivalDate: r.arrival_date, departureDate: r.departure_date,
      nights: Number(r.nights), adults: Number(r.adults), children: Number(r.children),
      totalAmount: Number(r.total_amount), paidAmount: Number(r.paid_amount),
      balanceAmount: Number(r.balance_amount),
      status: r.status, paymentStatus: r.payment_status,
    })),
  };
}

export async function getReservation(propertyId: string, id: string, ctx?: RequestContext) {
  const header = await queryOne<Record<string, string>>(
    `SELECT r.*, g.full_name AS guest_name, g.email AS guest_email, g.phone AS guest_phone,
            g.city AS guest_city, bs.name AS source_name, cp.name AS policy_name
       FROM reservations r
       JOIN guests g ON g.id = r.guest_id
       LEFT JOIN booking_sources bs ON bs.id = r.booking_source_id
       LEFT JOIN cancellation_policies cp ON cp.id = r.cancellation_policy_id
      WHERE r.id = $1 AND r.property_id = $2`,
    [id, propertyId], ctx,
  );
  if (!header) return null;

  const lines = await query<Record<string, string>>(
    `SELECT rr.id, rt.code AS room_type_code, rt.name AS room_type_name,
            rp.name AS rate_plan_name, rm.room_number,
            rr.arrival_date, rr.departure_date, rr.adults, rr.children,
            rr.room_charges, rr.tax_amount, rr.total_amount, rr.status::text AS status
       FROM reservation_rooms rr
       JOIN room_types rt ON rt.id = rr.room_type_id
       JOIN rate_plans rp ON rp.id = rr.rate_plan_id
       LEFT JOIN rooms rm ON rm.id = rr.current_room_id
      WHERE rr.reservation_id = $1 ORDER BY rr.line_number`,
    [id], ctx,
  );

  const nights = await query<Record<string, string>>(
    `SELECT rrr.stay_date, rrr.rate_amount, rrr.tax_amount, rrr.total_amount, rrr.is_posted
       FROM reservation_room_rates rrr
       JOIN reservation_rooms rr ON rr.id = rrr.reservation_room_id
      WHERE rr.reservation_id = $1 ORDER BY rrr.stay_date`,
    [id], ctx,
  );

  const history = await query<Record<string, string>>(
    `SELECT h.from_status::text AS from_status, h.to_status::text AS to_status,
            h.reason, h.created_at, u.full_name AS changed_by
       FROM reservation_status_history h
       LEFT JOIN users u ON u.id = h.changed_by
      WHERE h.reservation_id = $1 ORDER BY h.created_at`,
    [id], ctx,
  );

  return { header, lines, nights, history };
}
