import { redirect } from 'next/navigation';
import { getSessionUser, can } from '@/lib/auth';
import { getProperty, listUsers, listRolesWithCounts } from '@/modules/property/service';
import { PageHeader, EmptyState, Badge } from '@/components/ui';

export const dynamic = 'force-dynamic';

export default async function SettingsPage() {
  const user = await getSessionUser();
  if (!user) redirect('/login');
  if (!can(user, 'settings.read')) {
    return <EmptyState message="You do not have permission to view settings." />;
  }

  const ctx = { userId: user.id, userEmail: user.email };
  const property = await getProperty(user.properties[0].id, ctx);
  const canSeeUsers = can(user, 'users.read');
  const [users, roles] = await Promise.all([
    canSeeUsers ? listUsers(user.organizationId!, ctx) : Promise.resolve([]),
    listRolesWithCounts(ctx),
  ]);

  return (
    <>
      <PageHeader title="Settings" subtitle="Property, users and roles" />

      <div className="grid gap-4 lg:grid-cols-2">
        <section className="panel p-4">
          <h2 className="font-semibold text-sm mb-3">Property</h2>
          <dl className="text-sm space-y-2">
            {[
              ['Name', property?.name], ['Legal name', property?.legal_name],
              ['Code', property?.code],
              ['Address', [property?.address_line1, property?.city, property?.state].filter(Boolean).join(', ')],
              ['GSTIN', property?.gstin], ['PAN', property?.pan],
              ['Currency', property?.currency_code], ['Timezone', property?.timezone],
              ['Check-in', property?.check_in_time], ['Check-out', property?.check_out_time],
            ].map(([label, value]) => (
              <div key={String(label)} className="flex justify-between gap-4">
                <dt className="muted shrink-0">{label}</dt>
                <dd className="text-right font-medium break-words">{value || '—'}</dd>
              </div>
            ))}
          </dl>
          {!can(user, 'settings.manage') && (
            <p className="muted text-xs mt-4">
              Read-only: changing settings requires the <code>settings.manage</code> permission.
            </p>
          )}
        </section>

        <section className="panel p-4">
          <h2 className="font-semibold text-sm mb-1">Built-in roles</h2>
          <p className="muted text-xs mb-3">
            Permissions are granular; each role is a bundle. Separation of duties is enforced,
            not assumed.
          </p>
          <ul className="divide-y divide-[var(--border)] text-sm">
            {roles.map((r) => (
              <li key={r.code} className="py-2 flex items-baseline justify-between gap-3">
                <div className="min-w-0">
                  <span className="font-medium">{r.name}</span>
                  <p className="muted text-xs">{r.description}</p>
                </div>
                <span className="muted text-xs tabular shrink-0">{r.permission_count} perms</span>
              </li>
            ))}
          </ul>
        </section>
      </div>

      {canSeeUsers && (
        <section className="panel p-4 mt-4">
          <h2 className="font-semibold text-sm mb-3">Users</h2>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left muted border-b border-[var(--border)]">
                <tr>
                  <th className="py-2 font-medium">Name</th>
                  <th className="py-2 font-medium">Email</th>
                  <th className="py-2 font-medium">Roles</th>
                  <th className="py-2 font-medium text-right">Permissions</th>
                  <th className="py-2 font-medium">Last login</th>
                  <th className="py-2 font-medium">Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-[var(--border)]">
                {users.map((u) => (
                  <tr key={u.id}>
                    <td className="py-2.5 font-medium">{u.full_name}</td>
                    <td className="py-2.5">{u.email}</td>
                    <td className="py-2.5">
                      {Array.isArray(u.roles) && u.roles.length > 0 ? u.roles.join(', ') : '—'}
                    </td>
                    <td className="py-2.5 text-right tabular">{u.permission_count}</td>
                    <td className="py-2.5 muted text-xs">
                      {u.last_login_at ? new Date(u.last_login_at).toLocaleString('en-IN') : 'Never'}
                    </td>
                    <td className="py-2.5">
                      <Badge value={String(u.is_active) === 'true' ? 'CONFIRMED' : 'CANCELLED'} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </>
  );
}
