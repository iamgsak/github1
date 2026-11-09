import Link from 'next/link';

export function StatCard({
  label, value, sub, tone = 'default',
}: {
  label: string; value: string; sub?: string;
  tone?: 'default' | 'positive' | 'negative' | 'brand';
}) {
  const toneClass = {
    default: '',
    positive: 'text-emerald-600 dark:text-emerald-400',
    negative: 'text-red-600 dark:text-red-400',
    brand: 'text-brand-600 dark:text-brand-400',
  }[tone];

  return (
    <div className="panel p-4">
      <p className="muted text-xs uppercase tracking-wide">{label}</p>
      <p className={`mt-1.5 text-2xl font-semibold tabular ${toneClass}`}>{value}</p>
      {sub && <p className="muted text-xs mt-1">{sub}</p>}
    </div>
  );
}

const STATUS_STYLES: Record<string, string> = {
  CONFIRMED: 'bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300',
  GUARANTEED: 'bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300',
  CHECKED_IN: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300',
  CHECKED_OUT: 'bg-slate-200 text-slate-700 dark:bg-slate-800 dark:text-slate-300',
  CANCELLED: 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300',
  NO_SHOW: 'bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300',
  PENDING: 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300',
  PAID: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300',
  UNPAID: 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300',
  PARTIALLY_PAID: 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300',
  AVAILABLE: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300',
  OCCUPIED: 'bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300',
  CLEAN: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300',
  DIRTY: 'bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300',
  INSPECTED: 'bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300',
  OUT_OF_ORDER: 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300',
};

export function Badge({ value }: { value: string }) {
  const cls = STATUS_STYLES[value] ?? 'bg-slate-200 text-slate-700 dark:bg-slate-800 dark:text-slate-300';
  return (
    <span className={`inline-block rounded-full px-2 py-0.5 text-xs font-medium ${cls}`}>
      {value.replaceAll('_', ' ').toLowerCase()}
    </span>
  );
}

export function PageHeader({
  title, subtitle, action,
}: { title: string; subtitle?: string; action?: React.ReactNode }) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-3 mb-6">
      <div>
        <h1 className="text-xl sm:text-2xl font-semibold">{title}</h1>
        {subtitle && <p className="muted text-sm mt-1">{subtitle}</p>}
      </div>
      {action}
    </div>
  );
}

export function EmptyState({ message }: { message: string }) {
  return <p className="muted text-sm py-8 text-center">{message}</p>;
}

export function NavCard({ href, title, description }: { href: string; title: string; description: string }) {
  return (
    <Link href={href} className="panel p-4 hover:border-brand-400 transition-colors block">
      <p className="font-medium text-sm">{title}</p>
      <p className="muted text-xs mt-1">{description}</p>
    </Link>
  );
}
