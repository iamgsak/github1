/** Indian-locale formatting helpers shared by every screen. */

export function formatCurrency(value: number | string | null | undefined): string {
  const n = typeof value === 'string' ? Number(value) : (value ?? 0);
  return new Intl.NumberFormat('en-IN', {
    style: 'currency', currency: 'INR', maximumFractionDigits: 0,
  }).format(Number.isFinite(n) ? n : 0);
}

export function formatNumber(value: number | string | null | undefined, digits = 0): string {
  const n = typeof value === 'string' ? Number(value) : (value ?? 0);
  return new Intl.NumberFormat('en-IN', {
    minimumFractionDigits: digits, maximumFractionDigits: digits,
  }).format(Number.isFinite(n) ? n : 0);
}

/**
 * Stay dates are calendar dates, not instants. They arrive from pg as a
 * Date pinned to UTC midnight, so they must be read in UTC -- reading them
 * in local time is the classic off-by-one that shifts a whole night.
 */
export function formatDate(value: Date | string | null | undefined): string {
  if (!value) return '—';
  const d = typeof value === 'string' ? new Date(value) : value;
  if (Number.isNaN(d.getTime())) return '—';
  return new Intl.DateTimeFormat('en-IN', {
    day: '2-digit', month: 'short', year: 'numeric', timeZone: 'UTC',
  }).format(d);
}

export function toISODate(value: Date | string): string {
  const d = typeof value === 'string' ? new Date(value) : value;
  return d.toISOString().slice(0, 10);
}
