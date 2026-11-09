import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getSessionUser, can } from '@/lib/auth';
import { listReservations } from '@/modules/reservations/service';
import { formatCurrency, formatDate } from '@/lib/format';
import { Badge, PageHeader, EmptyState } from '@/components/ui';

export const dynamic = 'force-dynamic';

const STATUSES = ['CONFIRMED','GUARANTEED','CHECKED_IN','CHECKED_OUT','CANCELLED','NO_SHOW'];

export default async function ReservationsPage({
  searchParams,
}: { searchParams: Promise<{ status?: string; q?: string; page?: string }> }) {
  const user = await getSessionUser();
  if (!user) redirect('/login');
  if (!can(user, 'reservations.read')) {
    return <EmptyState message="You do not have permission to view reservations." />;
  }

  const sp = await searchParams;
  const property = user.properties[0];
  const page = Number(sp.page ?? '1') || 1;

  const { items, total } = await listReservations(
    property.id, { status: sp.status, q: sp.q, page, pageSize: 25 },
    { userId: user.id, userEmail: user.email },
  );

  const showMoney = can(user, 'payments.read') || can(user, 'invoices.read');
  const pages = Math.max(Math.ceil(total / 25), 1);
  const qs = (patch: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    const merged = { status: sp.status, q: sp.q, page: String(page), ...patch };
    for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
    return `/reservations?${p.toString()}`;
  };

  return (
    <>
      <PageHeader title="Reservations"
        subtitle={`${total} matching ${total === 1 ? 'booking' : 'bookings'}`} />

      <form action="/reservations" className="panel p-3 mb-4 flex flex-wrap gap-2 items-center">
        <input type="search" name="q" defaultValue={sp.q ?? ''}
          placeholder="Search guest, number, phone, OTA reference…"
          className="flex-1 min-w-[14rem] rounded-lg border border-[var(--border)] bg-transparent px-3 py-2 text-sm outline-none focus:border-brand-500" />
        <select name="status" defaultValue={sp.status ?? ''}
          className="rounded-lg border border-[var(--border)] bg-transparent px-3 py-2 text-sm outline-none focus:border-brand-500">
          <option value="">All statuses</option>
          {STATUSES.map((s) => (
            <option key={s} value={s}>{s.replaceAll('_', ' ').toLowerCase()}</option>
          ))}
        </select>
        <button className="rounded-lg bg-brand-600 hover:bg-brand-700 text-white px-4 py-2 text-sm font-medium">
          Filter
        </button>
      </form>

      {items.length === 0 ? (
        <div className="panel"><EmptyState message="No reservations match those filters." /></div>
      ) : (
        <>
          {/* Table for wide screens */}
          <div className="panel overflow-x-auto hidden md:block">
            <table className="w-full text-sm">
              <thead className="text-left muted border-b border-[var(--border)]">
                <tr>
                  <th className="p-3 font-medium">Reservation</th>
                  <th className="p-3 font-medium">Guest</th>
                  <th className="p-3 font-medium">Source</th>
                  <th className="p-3 font-medium">Stay</th>
                  <th className="p-3 font-medium">Room</th>
                  {showMoney && <th className="p-3 font-medium text-right">Total</th>}
                  {showMoney && <th className="p-3 font-medium text-right">Balance</th>}
                  <th className="p-3 font-medium">Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-[var(--border)]">
                {items.map((r) => (
                  <tr key={r.id} className="hover:bg-black/[0.02] dark:hover:bg-white/[0.03]">
                    <td className="p-3">
                      <Link href={`/reservations/${r.id}`} className="font-medium text-brand-600 hover:underline">
                        {r.reservationNumber}
                      </Link>
                    </td>
                    <td className="p-3">
                      <div className="font-medium">{r.guestName}</div>
                      <div className="muted text-xs">{r.guestPhone ?? '—'}</div>
                    </td>
                    <td className="p-3">
                      <span className={r.sourceCategory === 'OTA' ? 'text-amber-600 dark:text-amber-400' : ''}>
                        {r.source ?? '—'}
                      </span>
                    </td>
                    <td className="p-3 whitespace-nowrap">
                      {formatDate(r.arrivalDate)} → {formatDate(r.departureDate)}
                      <div className="muted text-xs">
                        {r.nights} {r.nights === 1 ? 'night' : 'nights'} · {r.adults}A
                        {r.children > 0 ? ` ${r.children}C` : ''}
                      </div>
                    </td>
                    <td className="p-3">
                      {r.roomNumber ? <span className="font-medium">{r.roomNumber}</span>
                                    : <span className="muted text-xs">unassigned</span>}
                      <div className="muted text-xs">{r.roomTypeCode}</div>
                    </td>
                    {showMoney && <td className="p-3 text-right tabular">{formatCurrency(r.totalAmount)}</td>}
                    {showMoney && (
                      <td className="p-3 text-right tabular">
                        {r.balanceAmount > 0
                          ? <span className="text-red-600 font-medium">{formatCurrency(r.balanceAmount)}</span>
                          : <span className="muted">—</span>}
                      </td>
                    )}
                    <td className="p-3"><Badge value={r.status} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Cards for phones — front desk works on mobile */}
          <ul className="md:hidden space-y-3">
            {items.map((r) => (
              <li key={r.id} className="panel p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <Link href={`/reservations/${r.id}`} className="font-medium text-brand-600 hover:underline">
                      {r.guestName}
                    </Link>
                    <p className="muted text-xs">{r.reservationNumber}</p>
                  </div>
                  <Badge value={r.status} />
                </div>
                <div className="mt-3 grid grid-cols-2 gap-y-1.5 text-xs">
                  <span className="muted">Stay</span>
                  <span className="text-right">{formatDate(r.arrivalDate)} → {formatDate(r.departureDate)}</span>
                  <span className="muted">Room</span>
                  <span className="text-right">{r.roomNumber ?? 'unassigned'} ({r.roomTypeCode})</span>
                  <span className="muted">Source</span>
                  <span className="text-right">{r.source ?? '—'}</span>
                  {showMoney && (
                    <>
                      <span className="muted">Balance</span>
                      <span className={`text-right tabular ${r.balanceAmount > 0 ? 'text-red-600 font-medium' : ''}`}>
                        {r.balanceAmount > 0 ? formatCurrency(r.balanceAmount) : 'Settled'}
                      </span>
                    </>
                  )}
                </div>
              </li>
            ))}
          </ul>

          {pages > 1 && (
            <div className="flex items-center justify-between mt-4 text-sm">
              <span className="muted">Page {page} of {pages}</span>
              <div className="flex gap-2">
                {page > 1 && (
                  <Link href={qs({ page: String(page - 1) })}
                        className="rounded-lg border border-[var(--border)] px-3 py-1.5">Previous</Link>
                )}
                {page < pages && (
                  <Link href={qs({ page: String(page + 1) })}
                        className="rounded-lg border border-[var(--border)] px-3 py-1.5">Next</Link>
                )}
              </div>
            </div>
          )}
        </>
      )}
    </>
  );
}
