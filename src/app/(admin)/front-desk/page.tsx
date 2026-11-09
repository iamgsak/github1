import { PageHeader } from '@/components/ui';
import Link from 'next/link';

export default function Page() {
  return (
    <>
      <PageHeader title="Front Desk" subtitle="Planned for a later phase" />
      <div className="panel p-8 text-center">
        <p className="text-sm">
          The database, permissions and API contract for this module are designed and tested.
        </p>
        <p className="muted text-sm mt-2">
          The screens are scheduled in the delivery roadmap — see <code>docs/10-roadmap.md</code>.
        </p>
        <Link href="/" className="inline-block mt-5 text-sm rounded-lg bg-brand-600 hover:bg-brand-700 text-white px-4 py-2">
          Back to dashboard
        </Link>
      </div>
    </>
  );
}
