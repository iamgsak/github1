import { queryOne, query, type RequestContext } from '@/lib/db';

export interface DashboardKpis {
  businessDate: string;
  totalRooms: number; occupiedRooms: number; availableRooms: number; oooRooms: number;
  occupancyPct: number; adr: number; revpar: number;
  arrivalsToday: number; departuresToday: number; inHouse: number;
  roomRevenueToday: number; collectionsToday: number; pendingPayments: number;
  cashBalance: number; bankBalance: number;
  monthRevenue: number; monthExpenses: number; bookingsToday: number;
}

/**
 * Owner "one screen" KPIs.
 *
 * Room revenue comes from reservation_room_rates (the per-night
 * breakdown), never from dividing a stay total by nights. Cash and bank
 * balances come from the ledger, not from summing payments -- consistent
 * with the rule that financial figures derive from accounting entries.
 */
export async function getDashboard(
  propertyId: string, businessDate: string, ctx?: RequestContext,
): Promise<DashboardKpis> {
  const row = await queryOne<Record<string, string>>(
    `
    WITH params AS (SELECT $1::uuid AS property_id, $2::date AS d),
    rooms_total AS (
      SELECT count(*)::int AS total FROM rooms r, params p
       WHERE r.property_id = p.property_id AND r.is_active),
    occupancy AS (
      SELECT count(*) FILTER (WHERE ra.allocation_type = 'RESERVATION')::int AS occupied,
             count(*) FILTER (WHERE ra.allocation_type <> 'RESERVATION')::int AS ooo
        FROM room_allocations ra, params p
       WHERE ra.property_id = p.property_id AND ra.is_active AND ra.stay_range @> p.d),
    movements AS (
      SELECT
        (SELECT count(*) FROM reservations r, params p
          WHERE r.property_id = p.property_id AND r.arrival_date = p.d
            AND r.status IN ('CONFIRMED','GUARANTEED','CHECKED_IN','CHECKED_OUT'))::int AS arrivals,
        (SELECT count(*) FROM reservations r, params p
          WHERE r.property_id = p.property_id AND r.departure_date = p.d
            AND r.status IN ('CHECKED_IN','CHECKED_OUT'))::int AS departures,
        (SELECT count(*) FROM reservations r, params p
          WHERE r.property_id = p.property_id AND r.status = 'CHECKED_IN')::int AS in_house,
        (SELECT count(*) FROM reservations r, params p
          WHERE r.property_id = p.property_id AND r.booked_at::date = p.d)::int AS bookings_today),
    revenue AS (
      SELECT COALESCE(sum(rrr.total_amount), 0) AS room_revenue,
             COALESCE(sum(rrr.rate_amount), 0)  AS room_net,
             count(*)::int                      AS sold_nights
        FROM reservation_room_rates rrr, params p
       WHERE rrr.property_id = p.property_id AND rrr.stay_date = p.d),
    collections AS (
      SELECT COALESCE(sum(CASE WHEN pay.payment_direction = 'RECEIPT'
                               THEN pay.amount ELSE -pay.amount END), 0) AS collected
        FROM payments pay, params p
       WHERE pay.property_id = p.property_id AND pay.payment_date = p.d
         AND NOT pay.is_void AND pay.status IN ('CAPTURED','AUTHORIZED')),
    pending AS (
      SELECT COALESCE(sum(r.total_amount - r.paid_amount), 0) AS pending
        FROM reservations r, params p
       WHERE r.property_id = p.property_id
         AND r.status IN ('CONFIRMED','GUARANTEED','CHECKED_IN')
         AND r.total_amount > r.paid_amount),
    balances AS (
      SELECT COALESCE(sum(jl.debit - jl.credit) FILTER (WHERE a.is_cash), 0) AS cash,
             COALESCE(sum(jl.debit - jl.credit) FILTER (WHERE a.is_bank), 0) AS bank
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id AND je.is_posted
        JOIN accounts a ON a.id = jl.account_id, params p
       WHERE jl.property_id = p.property_id),
    month AS (
      SELECT COALESCE(sum(jl.credit - jl.debit) FILTER (WHERE a.account_type = 'REVENUE'), 0) AS revenue,
             COALESCE(sum(jl.debit - jl.credit) FILTER (WHERE a.account_type = 'EXPENSE'), 0) AS expenses
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id AND je.is_posted
        JOIN accounts a ON a.id = jl.account_id, params p
       WHERE jl.property_id = p.property_id
         AND je.entry_date >= date_trunc('month', p.d)::date
         AND je.entry_date <  (date_trunc('month', p.d) + interval '1 month')::date)
    SELECT rt.total, o.occupied, o.ooo, m.arrivals, m.departures, m.in_house,
           m.bookings_today, rev.room_revenue, rev.room_net, rev.sold_nights,
           c.collected, pg.pending, b.cash, b.bank,
           mo.revenue AS month_revenue, mo.expenses AS month_expenses
      FROM rooms_total rt, occupancy o, movements m, revenue rev,
           collections c, pending pg, balances b, month mo
    `,
    [propertyId, businessDate], ctx,
  );

  const total = Number(row?.total ?? 0);
  const occupied = Number(row?.occupied ?? 0);
  const ooo = Number(row?.ooo ?? 0);
  const soldNights = Number(row?.sold_nights ?? 0);
  const roomNet = Number(row?.room_net ?? 0);
  const sellable = Math.max(total - ooo, 0);

  return {
    businessDate,
    totalRooms: total,
    occupiedRooms: occupied,
    availableRooms: Math.max(sellable - occupied, 0),
    oooRooms: ooo,
    occupancyPct: sellable > 0 ? (occupied / sellable) * 100 : 0,
    // ADR is revenue per room SOLD; RevPAR is revenue per room AVAILABLE.
    adr: soldNights > 0 ? roomNet / soldNights : 0,
    revpar: sellable > 0 ? roomNet / sellable : 0,
    arrivalsToday: Number(row?.arrivals ?? 0),
    departuresToday: Number(row?.departures ?? 0),
    inHouse: Number(row?.in_house ?? 0),
    roomRevenueToday: Number(row?.room_revenue ?? 0),
    collectionsToday: Number(row?.collected ?? 0),
    pendingPayments: Number(row?.pending ?? 0),
    cashBalance: Number(row?.cash ?? 0),
    bankBalance: Number(row?.bank ?? 0),
    monthRevenue: Number(row?.month_revenue ?? 0),
    monthExpenses: Number(row?.month_expenses ?? 0),
    bookingsToday: Number(row?.bookings_today ?? 0),
  };
}

export interface SourceBreakdown {
  source: string; category: string; bookings: number; revenue: number; commission: number;
}

export async function getSourceBreakdown(
  propertyId: string, from: string, to: string, ctx?: RequestContext,
): Promise<SourceBreakdown[]> {
  const rows = await query<Record<string, string>>(
    `SELECT COALESCE(bs.name, 'Unattributed') AS source,
            COALESCE(bs.category, 'OTHER')    AS category,
            count(*)::int                     AS bookings,
            COALESCE(sum(r.total_amount), 0)  AS revenue,
            COALESCE(sum(r.commission_amount), 0) AS commission
       FROM reservations r
       LEFT JOIN booking_sources bs ON bs.id = r.booking_source_id
      WHERE r.property_id = $1
        AND r.arrival_date >= $2::date AND r.arrival_date < $3::date
        AND r.status <> 'CANCELLED'
      GROUP BY 1, 2 ORDER BY 4 DESC`,
    [propertyId, from, to], ctx,
  );
  return rows.map((r) => ({
    source: r.source, category: r.category,
    bookings: Number(r.bookings), revenue: Number(r.revenue), commission: Number(r.commission),
  }));
}

export interface MovementRow {
  id: string; reservationNumber: string; guestName: string;
  roomTypeCode: string; roomNumber: string | null;
  arrivalDate: string; departureDate: string; status: string; balance: number;
}

export async function getMovements(
  propertyId: string, businessDate: string,
  kind: 'arrivals' | 'departures' | 'in-house', ctx?: RequestContext,
): Promise<MovementRow[]> {
  // These must use exactly the same definition as the KPI counters,
  // otherwise the tile and the list disagree and staff stop trusting
  // both. "Arrivals" means every booking due to arrive on the date,
  // whether or not it has been checked in yet.
  const filter =
    kind === 'arrivals'
      ? `r.arrival_date = $2::date
         AND r.status IN ('CONFIRMED','GUARANTEED','CHECKED_IN','CHECKED_OUT')`
      : kind === 'departures'
        ? `r.departure_date = $2::date AND r.status IN ('CHECKED_IN','CHECKED_OUT')`
        : `r.status = 'CHECKED_IN' AND $2::date >= r.arrival_date`;

  const rows = await query<Record<string, string>>(
    `SELECT r.id, r.reservation_number, g.full_name AS guest_name,
            rt.code AS room_type_code, rm.room_number,
            r.arrival_date, r.departure_date, r.status::text AS status,
            (r.total_amount - r.paid_amount) AS balance
       FROM reservations r
       JOIN guests g ON g.id = r.guest_id
       JOIN reservation_rooms rr ON rr.reservation_id = r.id
       JOIN room_types rt ON rt.id = rr.room_type_id
       LEFT JOIN rooms rm ON rm.id = rr.current_room_id
      WHERE r.property_id = $1 AND ${filter}
      ORDER BY r.arrival_date, g.full_name`,
    [propertyId, businessDate], ctx,
  );
  return rows.map((r) => ({
    id: r.id, reservationNumber: r.reservation_number, guestName: r.guest_name,
    roomTypeCode: r.room_type_code, roomNumber: r.room_number ?? null,
    arrivalDate: r.arrival_date, departureDate: r.departure_date,
    status: r.status, balance: Number(r.balance),
  }));
}
