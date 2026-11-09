'use client';

import { useRouter } from 'next/navigation';
import { useState } from 'react';
import type { SessionUser } from '@/lib/auth';

export default function Topbar({
  user, propertyName,
}: { user: SessionUser; propertyName: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);

  async function signOut() {
    setBusy(true);
    await fetch('/api/v1/auth/logout', { method: 'POST' });
    router.replace('/login');
    router.refresh();
  }

  const initials = user.fullName.split(' ').map((p) => p[0]).slice(0, 2).join('').toUpperCase();

  return (
    <header
      className="sticky top-0 z-30 h-16 flex items-center justify-between gap-4 px-4 sm:px-6
                 border-b border-[var(--border)] bg-[var(--panel)]/85 backdrop-blur"
    >
      <div className="min-w-0">
        <p className="font-medium text-sm truncate">{propertyName}</p>
        <p className="muted text-xs truncate">
          {user.roles.length > 0 ? user.roles.join(', ') : 'No role assigned'}
        </p>
      </div>

      <div className="flex items-center gap-3">
        <div className="hidden sm:block text-right min-w-0">
          <p className="text-sm font-medium truncate">{user.fullName}</p>
          <p className="muted text-xs truncate">{user.email}</p>
        </div>
        <div className="h-9 w-9 rounded-full bg-brand-100 text-brand-800 grid place-items-center
                        text-xs font-semibold shrink-0" aria-hidden>
          {initials}
        </div>
        <button
          type="button" onClick={signOut} disabled={busy}
          className="text-sm rounded-lg border border-[var(--border)] px-3 py-1.5
                     hover:bg-black/5 dark:hover:bg-white/5 disabled:opacity-60"
        >
          {busy ? '…' : 'Sign out'}
        </button>
      </div>
    </header>
  );
}
