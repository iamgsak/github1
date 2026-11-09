import { redirect } from 'next/navigation';
import { getSessionUser } from '@/lib/auth';
import Sidebar from '@/components/sidebar';
import Topbar from '@/components/topbar';

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await getSessionUser();
  if (!user) redirect('/login');

  const property = user.properties[0] ?? null;

  return (
    <div className="min-h-screen lg:grid lg:grid-cols-[16rem_1fr]">
      <Sidebar permissions={user.permissions} isPlatformAdmin={user.isPlatformAdmin} />
      <div className="flex min-h-screen flex-col">
        <Topbar user={user} propertyName={property?.name ?? 'No property'} />
        <main className="flex-1 p-4 sm:p-6 lg:p-8">{children}</main>
      </div>
    </div>
  );
}
