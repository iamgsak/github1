'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useState } from 'react';

/**
 * Navigation is permission-driven: a link the user cannot use is not
 * shown. Convenience only -- the API and RLS enforce the real boundary.
 */
const NAV: Array<{ href: string; label: string; icon: string; permission?: string }> = [
  { href: '/', label: 'Dashboard', icon: '▦', permission: 'dashboard.read' },
  { href: '/reservations', label: 'Reservations', icon: '▤', permission: 'reservations.read' },
  { href: '/front-desk', label: 'Front Desk', icon: '◈', permission: 'reservations.read' },
  { href: '/rooms', label: 'Rooms', icon: '⬚', permission: 'rooms.read' },
  { href: '/guests', label: 'Guests', icon: '◍', permission: 'guests.read' },
  { href: '/housekeeping', label: 'Housekeeping', icon: '◑', permission: 'housekeeping.read' },
  { href: '/rates', label: 'Rates & Availability', icon: '◫', permission: 'rates.read' },
  { href: '/billing', label: 'Billing', icon: '₹', permission: 'invoices.read' },
  { href: '/accounting', label: 'Accounting', icon: '⊞', permission: 'accounting.read' },
  { href: '/channels', label: 'OTA / Channels', icon: '⇄', permission: 'channels.read' },
  { href: '/reports', label: 'Reports', icon: '◔', permission: 'reports.operational' },
  { href: '/settings', label: 'Settings', icon: '⚙', permission: 'settings.read' },
];

export default function Sidebar({
  permissions, isPlatformAdmin,
}: { permissions: string[]; isPlatformAdmin: boolean }) {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);

  const visible = NAV.filter(
    (n) => !n.permission || isPlatformAdmin || permissions.includes(n.permission),
  );

  return (
    <>
      {/* Mobile trigger -- front desk and housekeeping work on phones */}
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label="Open navigation"
        className="lg:hidden fixed bottom-4 right-4 z-40 h-12 w-12 rounded-full
                   bg-brand-600 text-white shadow-lg text-lg"
      >
        ☰
      </button>

      {open && (
        <div className="lg:hidden fixed inset-0 z-40 bg-black/40"
             onClick={() => setOpen(false)} aria-hidden />
      )}

      <aside
        className={[
          'z-50 w-64 shrink-0 border-r border-[var(--border)] bg-[var(--panel)]',
          'lg:sticky lg:top-0 lg:h-screen lg:translate-x-0',
          'fixed inset-y-0 left-0 transition-transform lg:transition-none',
          open ? 'translate-x-0' : '-translate-x-full',
        ].join(' ')}
      >
        <div className="flex items-center gap-3 px-4 h-16 border-b border-[var(--border)]">
          <div className="h-9 w-9 rounded-lg bg-brand-600 text-white grid place-items-center font-semibold">
            A
          </div>
          <div className="min-w-0">
            <p className="font-semibold text-sm leading-tight truncate">Hotel Amoha</p>
            <p className="muted text-xs">ERP</p>
          </div>
        </div>

        <nav className="p-3 space-y-0.5">
          {visible.map((item) => {
            const active = item.href === '/' ? pathname === '/' : pathname.startsWith(item.href);
            return (
              <Link
                key={item.href}
                href={item.href}
                onClick={() => setOpen(false)}
                aria-current={active ? 'page' : undefined}
                className={[
                  'flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors',
                  active ? 'bg-brand-600 text-white font-medium'
                         : 'hover:bg-black/5 dark:hover:bg-white/5',
                ].join(' ')}
              >
                <span aria-hidden className="w-4 text-center opacity-80">{item.icon}</span>
                {item.label}
              </Link>
            );
          })}
        </nav>
      </aside>
    </>
  );
}
