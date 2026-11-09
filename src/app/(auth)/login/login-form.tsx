'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';

export default function LoginForm() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setPending(true);
    setError(null);
    try {
      const res = await fetch('/api/v1/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
      });
      const json = await res.json();
      if (!res.ok) { setError(json?.error?.message ?? 'Sign in failed.'); return; }
      router.replace('/');
      router.refresh();
    } catch {
      setError('Could not reach the server. Check your connection.');
    } finally {
      setPending(false);
    }
  }

  const field = 'w-full rounded-lg border px-3 py-2.5 text-sm bg-transparent ' +
                'border-[var(--border)] focus:border-brand-500 outline-none';

  return (
    <form onSubmit={onSubmit} className="mt-8 space-y-4" noValidate>
      <div>
        <label htmlFor="email" className="block text-sm font-medium mb-1.5">Email</label>
        <input id="email" name="email" type="email" autoComplete="username" required autoFocus
               value={email} onChange={(e) => setEmail(e.target.value)}
               className={field} placeholder="you@hotelamoha.com" />
      </div>

      <div>
        <label htmlFor="password" className="block text-sm font-medium mb-1.5">Password</label>
        <input id="password" name="password" type="password" autoComplete="current-password" required
               value={password} onChange={(e) => setPassword(e.target.value)}
               className={field} placeholder="••••••••" />
      </div>

      {error && (
        <p role="alert" className="text-sm text-red-600 bg-red-50 dark:bg-red-950/40 rounded-lg px-3 py-2">
          {error}
        </p>
      )}

      <button type="submit" disabled={pending}
        className="w-full rounded-lg bg-brand-600 hover:bg-brand-700 disabled:opacity-60
                   text-white font-medium py-2.5 text-sm transition-colors">
        {pending ? 'Signing in…' : 'Sign in'}
      </button>
    </form>
  );
}
