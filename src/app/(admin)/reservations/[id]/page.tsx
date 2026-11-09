import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { getSessionUser, can } from '@/lib/auth';
import { getReservation } from '@/modules/reservations/service';
import { formatCurrency, formatDate } from '@/lib/format';
import { Badge, PageHeader, EmptyState } from '@/components/ui';

export const dynamic = 'force-dynamic';

export default async function ReservationDetail({
  params,
}: { params: Promise<{ id: string }> }) {
  const user = await getSessionUser();
  if (!user) redirect('/login');
  if (!can(user, 'reservations.read')) {
    return <EmptyState message="You do not have permission to view reservations." />;
  }

  const { id } = await params;
  const data = await getReservation(user.properties[0].id, id,
    { userId: user.id, userEmail: user.email });
  if (!data) notFound();

  const { header: h, lines, nights, history } = data;
  const showMoney = can(user, 'payments.read') || can(user, 'invoices.read');

  return (
    <>
      <PageHeader
        title={h.reservation_number}
        subtitle={`${h.guest_name} · ${formatDate(h.arrival_date)} → ${formatDate(h.departure_date)}`}
        action={<Link href="/reservations"
                      className="text-sm rounded-lg border border-[var(--border)] px-3 py-1.5">
                  ← All reservations
                </Link>} />

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2 space-y-4">
          <div className="panel p-4">
            <h2 className="font-semibold text-sm mb-3">Stay</h2>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-left muted border-b border-[var(--border)]">
                  <tr>
                    <th className="py-2 font-medium">Room type</th>
                    <th className="py-2 font-medium">Rate plan</th>
                    <th className="py-2 font-medium">Room</th>
                    <th className="py-2 font-medium">Guests</th>
                    {showMoney && <th className="py-2 font-medium text-right">Total</th>}
                    <th className="py-2 font-medium">Status</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-[var(--border)]">
                  {lines.map((l) => (
                    <tr key={l.id}>
                      <td className="py-2.5">
                        <div className="font-medium">{l.room_type_name}</div>
                        <div className="muted text-xs">{l.room_type_code}</div>
                      </td>
                      <td className="py-2.5">{l.rate_plan_name}</td>
                      <td className="py-2.5">{l.room_number ?? <span className="muted text-xs">unassigned</span>}</td>
                      <td className="py-2.5 tabular">
                        {l.adults}A{Number(l.children) > 0 ? ` ${l.children}C` : ''}
                      </td>
                      {showMoney && <td className="py-2.5 text-right tabular">{formatCurrency(l.total_amount)}</td>}
                      <td className="py-2.5"><Badge value={l.status} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          {showMoney && nights.length > 0 && (
            <div className="panel p-4">
              <h2 className="font-semibold text-sm mb-1">Nightly breakdown</h2>
              <p className="muted text-xs mb-3">
                Room revenue is stored per night, so a partial stay bills exactly rather than
                dividing a total.
              </p>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="text-left muted border-b border-[var(--border)]">
                    <tr>
                      <th className="py-2 font-medium">Night</th>
                      <th className="py-2 font-medium text-right">Rate</th>
                      <th className="py-2 font-medium text-right">Tax</th>
                      <th className="py-2 font-medium text-right">Total</th>
                      <th className="py-2 font-medium">Posted</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-[var(--border)]">
                    {nights.map((n) => (
                      <tr key={n.stay_date}>
                        <td className="py-2">{formatDate(n.stay_date)}</td>
                        <td className="py-2 text-right tabular">{formatCurrency(n.rate_amount)}</td>
                        <td className="py-2 text-right tabular">{formatCurrency(n.tax_amount)}</td>
                        <td className="py-2 text-right tabular font-medium">{formatCurrency(n.total_amount)}</td>
                        <td className="py-2 muted text-xs">
                          {String(n.is_posted) === 'true' ? 'Posted' : 'Pending night audit'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          <div className="panel p-4">
            <h2 className="font-semibold text-sm mb-3">Status history</h2>
            <ol className="space-y-2.5">
              {history.map((e, i) => (
                <li key={i} className="flex items-start gap-3 text-sm">
                  <span className="mt-1 h-2 w-2 rounded-full bg-brand-500 shrink-0" aria-hidden />
                  <div>
                    <span className="font-medium">
                      {e.from_status ? `${e.from_status} → ${e.to_status}` : `Created as ${e.to_status}`}
                    </span>
                    <p className="muted text-xs">
                      {new Date(e.created_at).toLocaleString('en-IN')}
                      {e.changed_by ? ` · ${e.changed_by}` : ''}
                      {e.reason ? ` · ${e.reason}` : ''}
                    </p>
                  </div>
                </li>
              ))}
            </ol>
          </div>
        </div>

        <div className="space-y-4">
          <div className="panel p-4">
            <h2 className="font-semibold text-sm mb-3">Guest</h2>
            <dl className="text-sm space-y-2">
              {[['Name', h.guest_name], ['Phone', h.guest_phone],
                ['Email', h.guest_email], ['City', h.guest_city]].map(([k, v]) => (
                <div key={String(k)} className="flex justify-between gap-3">
                  <dt className="muted">{k}</dt>
                  <dd className="text-right truncate">{v ?? '—'}</dd>
                </div>
              ))}
            </dl>
          </div>

          <div className="panel p-4">
            <h2 className="font-semibold text-sm mb-3">Booking</h2>
            <dl className="text-sm space-y-2">
              <div className="flex justify-between gap-3">
                <dt className="muted">Status</dt><dd><Badge value={h.status} /></dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="muted">Source</dt><dd className="text-right">{h.source_name ?? '—'}</dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="muted">Nights</dt><dd className="text-right tabular">{h.nights}</dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="muted">Policy</dt><dd className="text-right">{h.policy_name ?? '—'}</dd>
              </div>
              {h.external_reference && (
                <div className="flex justify-between gap-3">
                  <dt className="muted">OTA ref</dt>
                  <dd className="text-right font-mono text-xs">{h.external_reference}</dd>
                </div>
              )}
            </dl>
          </div>

          {showMoney && (
            <div className="panel p-4">
              <h2 className="font-semibold text-sm mb-3">Charges</h2>
              <dl className="text-sm space-y-2">
                <div className="flex justify-between gap-3">
                  <dt className="muted">Room charges</dt>
                  <dd className="tabular">{formatCurrency(h.room_charges)}</dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="muted">Tax</dt><dd className="tabular">{formatCurrency(h.tax_amount)}</dd>
                </div>
                <div className="flex justify-between gap-3 border-t border-[var(--border)] pt-2 font-semibold">
                  <dt>Total</dt><dd className="tabular">{formatCurrency(h.total_amount)}</dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="muted">Paid</dt><dd className="tabular">{formatCurrency(h.paid_amount)}</dd>
                </div>
                <div className="flex justify-between gap-3 font-semibold">
                  <dt>Balance</dt>
                  <dd className={`tabular ${Number(h.balance_amount) > 0 ? 'text-red-600' : 'text-emerald-600'}`}>
                    {formatCurrency(h.balance_amount)}
                  </dd>
                </div>
              </dl>
              <div className="mt-3"><Badge value={h.payment_status} /></div>
            </div>
          )}
        </div>
      </div>
    </>
  );
}
