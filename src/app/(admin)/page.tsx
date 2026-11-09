import { redirect } from 'next/navigation';
import Link from 'next/link';
import { getSessionUser, can } from '@/lib/auth';
import { queryOne } from '@/lib/db';
import { getDashboard, getSourceBreakdown, getMovements } from '@/modules/dashboard/service';
import { formatCurrency, formatNumber, formatDate } from '@/lib/format';
import { StatCard, Badge, PageHeader, EmptyState } from '@/components/ui';

export const dynamic = 'force-dynamic';

/**
 * The owner's "one screen". The business date defaults to the latest date
 * that actually has activity, so a demo or a quiet period still shows a
 * meaningful picture rather than an empty today.
 */
export default async function DashboardPage() {
  const user = await getSessionUser();
  if (!user) redirect('/login');
  const property = user.properties[0];
  if (!property) return <EmptyState message="Your account has no property assigned yet." />;

  const ctx = { userId: user.id, userEmail: user.email };
  const dateRow = await queryOne<{ d: string }>(
    `SELECT COALESCE(
       (SELECT max(stay_date)::text FROM reservation_room_rates
         WHERE property_id = $1 AND stay_date <= CURRENT_DATE),
       (SELECT min(stay_date)::text FROM reservation_room_rates WHERE property_id = $1),
       CURRENT_DATE::text) AS d`,
    [property.id], ctx,
  );
  const businessDate = dateRow?.d ?? new Date().toISOString().slice(0, 10);

  const [kpis, sources, arrivals, departures] = await Promise.all([
    getDashboard(property.id, businessDate, ctx),
    getSourceBreakdown(property.id, businessDate.slice(0, 8) + '01',
                       businessDate.slice(0, 4) + '-12-31', ctx),
    getMovements(property.id, businessDate, 'arrivals', ctx),
    getMovements(property.id, businessDate, 'departures', ctx),
  ]);

  const showMoney = can(user, 'dashboard.financial');
  const maxSourceRevenue = Math.max(...sources.map((s) => s.revenue), 1);

  return (
    <>
      <PageHeader title="Dashboard"
        subtitle={`Business date ${formatDate(businessDate)} · ${property.name}`} />

      <section aria-label="Today" className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard label="Occupancy" value={`${formatNumber(kpis.occupancyPct, 1)}%`}
          sub={`${kpis.occupiedRooms} of ${kpis.totalRooms - kpis.oooRooms} sellable rooms`} tone="brand" />
        <StatCard label="Rooms available" value={formatNumber(kpis.availableRooms)}
          sub={kpis.oooRooms > 0 ? `${kpis.oooRooms} out of order` : 'All rooms in service'} />
        <StatCard label="ADR" value={formatCurrency(kpis.adr)} sub="Per room sold" />
        <StatCard label="RevPAR" value={formatCurrency(kpis.revpar)} sub="Per room available" />
      </section>

      {showMoney && (
        <section aria-label="Money" className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4 mt-3">
          <StatCard label="Room revenue today" value={formatCurrency(kpis.roomRevenueToday)} sub="Incl. tax" />
          <StatCard label="Collections today" value={formatCurrency(kpis.collectionsToday)} tone="positive" />
          <StatCard label="Pending payments" value={formatCurrency(kpis.pendingPayments)}
            tone={kpis.pendingPayments > 0 ? 'negative' : 'default'}
            sub="Across in-house and upcoming stays" />
          <StatCard label="Cash + bank"
            value={formatCurrency(kpis.cashBalance + kpis.bankBalance)} sub="From the ledger" />
        </section>
      )}

      <section aria-label="Movements" className="grid gap-3 sm:grid-cols-3 mt-3">
        <StatCard label="Arrivals" value={formatNumber(kpis.arrivalsToday)} />
        <StatCard label="Departures" value={formatNumber(kpis.departuresToday)} />
        <StatCard label="In house" value={formatNumber(kpis.inHouse)} />
      </section>

      <div className="grid gap-4 lg:grid-cols-2 mt-6">
        <div className="panel p-4">
          <h2 className="font-semibold text-sm mb-3">Expected arrivals</h2>
          {arrivals.length === 0 ? <EmptyState message="No arrivals for this date." /> : (
            <ul className="divide-y divide-[var(--border)]">
              {arrivals.map((a) => (
                <li key={a.id} className="py-2.5 flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <Link href={`/reservations/${a.id}`} className="text-sm font-medium hover:underline">
                      {a.guestName}
                    </Link>
                    <p className="muted text-xs truncate">
                      {a.reservationNumber} · {a.roomTypeCode}
                      {a.roomNumber ? ` · Room ${a.roomNumber}` : ' · unassigned'}
                    </p>
                  </div>
                  <Badge value={a.status} />
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="panel p-4">
          <h2 className="font-semibold text-sm mb-3">Expected departures</h2>
          {departures.length === 0 ? <EmptyState message="No departures for this date." /> : (
            <ul className="divide-y divide-[var(--border)]">
              {departures.map((d) => (
                <li key={d.id} className="py-2.5 flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <Link href={`/reservations/${d.id}`} className="text-sm font-medium hover:underline">
                      {d.guestName}
                    </Link>
                    <p className="muted text-xs truncate">
                      {d.reservationNumber}{d.roomNumber ? ` · Room ${d.roomNumber}` : ''}
                    </p>
                  </div>
                  {showMoney && d.balance > 0
                    ? <span className="text-xs font-medium text-red-600 tabular">
                        {formatCurrency(d.balance)} due
                      </span>
                    : <Badge value="PAID" />}
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      {showMoney && sources.length > 0 && (
        <div className="panel p-4 mt-4">
          <h2 className="font-semibold text-sm mb-1">Revenue by booking source</h2>
          <p className="muted text-xs mb-4">
            Commission is tracked separately, so net channel revenue comes from the ledger.
          </p>
          <ul className="space-y-3">
            {sources.map((s) => (
              <li key={s.source}>
                <div className="flex items-baseline justify-between gap-3 text-sm">
                  <span className="font-medium truncate">{s.source}</span>
                  <span className="tabular shrink-0">
                    {formatCurrency(s.revenue)}
                    <span className="muted text-xs ml-2">
                      {s.bookings} {s.bookings === 1 ? 'booking' : 'bookings'}
                    </span>
                  </span>
                </div>
                <div className="mt-1.5 h-2 rounded-full bg-black/5 dark:bg-white/10 overflow-hidden">
                  <div className={s.category === 'OTA' ? 'h-full bg-amber-500' : 'h-full bg-brand-500'}
                       style={{ width: `${Math.max((s.revenue / maxSourceRevenue) * 100, 2)}%` }} />
                </div>
              </li>
            ))}
          </ul>
          <p className="muted text-xs mt-4">
            <span className="inline-block h-2 w-2 rounded-full bg-brand-500 align-middle mr-1.5" />
            Direct &amp; other
            <span className="inline-block h-2 w-2 rounded-full bg-amber-500 align-middle ml-4 mr-1.5" />
            OTA (commission payable)
          </p>
        </div>
      )}
    </>
  );
}
