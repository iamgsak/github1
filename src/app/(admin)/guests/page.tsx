import { redirect } from 'next/navigation';
import { getSessionUser, can } from '@/lib/auth';
import { listGuests } from '@/modules/guests/service';
import { formatCurrency, formatDate } from '@/lib/format';
import { PageHeader, EmptyState } from '@/components/ui';

export const dynamic = 'force-dynamic';

export default async function GuestsPage({
  searchParams,
}: { searchParams: Promise<{ q?: string }> }) {
  const user = await getSessionUser();
  if (!user) redirect('/login');
  if (!can(user, 'guests.read')) {
    return <EmptyState message="You do not have permission to view guests." />;
  }

  const sp = await searchParams;
  const { items, total } = await listGuests(user.organizationId!, { q: sp.q },
    { userId: user.id, userEmail: user.email });

  return (
    <>
      <PageHeader title="Guests" subtitle={`${total} profiles across the group`} />

      <form action="/guests" className="panel p-3 mb-4 flex gap-2">
        <input type="search" name="q" defaultValue={sp.q ?? ''}
          placeholder="Search name, email, phone or guest code…"
          className="flex-1 rounded-lg border border-[var(--border)] bg-transparent px-3 py-2 text-sm outline-none focus:border-brand-500" />
        <button className="rounded-lg bg-brand-600 hover:bg-brand-700 text-white px-4 py-2 text-sm font-medium">
          Search
        </button>
      </form>

      {items.length === 0 ? (
        <div className="panel"><EmptyState message="No guests found." /></div>
      ) : (
        <div className="panel overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-left muted border-b border-[var(--border)]">
              <tr>
                <th className="p-3 font-medium">Guest</th>
                <th className="p-3 font-medium">Contact</th>
                <th className="p-3 font-medium">City</th>
                <th className="p-3 font-medium text-right">Stays</th>
                <th className="p-3 font-medium text-right">Revenue</th>
                <th className="p-3 font-medium">Last stay</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[var(--border)]">
              {items.map((g) => (
                <tr key={g.id} className="hover:bg-black/[0.02] dark:hover:bg-white/[0.03]">
                  <td className="p-3">
                    <div className="font-medium">{g.fullName}</div>
                    <div className="muted text-xs">{g.guestCode ?? '—'}</div>
                  </td>
                  <td className="p-3">
                    <div>{g.phone ?? '—'}</div>
                    <div className="muted text-xs truncate max-w-[16rem]">{g.email ?? '—'}</div>
                  </td>
                  <td className="p-3">{g.city ?? '—'}</td>
                  <td className="p-3 text-right tabular">{g.totalStays}</td>
                  <td className="p-3 text-right tabular">{formatCurrency(g.totalRevenue)}</td>
                  <td className="p-3">{g.lastStay ? formatDate(g.lastStay) : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
