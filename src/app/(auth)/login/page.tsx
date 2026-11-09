import { redirect } from 'next/navigation';
import { getSessionUser } from '@/lib/auth';
import LoginForm from './login-form';

export default async function LoginPage() {
  // Already signed in? Skip the form.
  if (await getSessionUser()) redirect('/');

  return (
    <main className="min-h-screen grid lg:grid-cols-2">
      {/* Brand panel — hidden on small screens so the form is above the fold */}
      <section className="hidden lg:flex flex-col justify-between bg-brand-800 text-white p-12">
        <div className="flex items-center gap-3">
          <div className="h-11 w-11 rounded-xl bg-white/15 grid place-items-center text-xl font-semibold">
            A
          </div>
          <div>
            <p className="text-lg font-semibold leading-tight">Hotel Amoha</p>
            <p className="text-sm text-white/70">Bengaluru</p>
          </div>
        </div>
        <div className="max-w-md">
          <h1 className="text-3xl font-semibold leading-snug">
            One system for the whole property.
          </h1>
          <p className="mt-4 text-white/80 leading-relaxed">
            Reservations, front desk, folios, billing, GST accounting, inventory
            and channels — sharing a single source of truth.
          </p>
        </div>
        <p className="text-xs text-white/50">
          Rooms, rates and reservations are protected by database-level
          constraints. Double booking is impossible by construction.
        </p>
      </section>

      <section className="flex items-center justify-center p-6 sm:p-12">
        <div className="w-full max-w-sm">
          <div className="lg:hidden mb-8 flex items-center gap-3">
            <div className="h-10 w-10 rounded-xl bg-brand-600 text-white grid place-items-center font-semibold">
              A
            </div>
            <span className="font-semibold">Hotel Amoha ERP</span>
          </div>
          <h2 className="text-2xl font-semibold">Sign in</h2>
          <p className="muted text-sm mt-1">Use your staff account to continue.</p>
          <LoginForm />
        </div>
      </section>
    </main>
  );
}
