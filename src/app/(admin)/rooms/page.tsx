import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getSessionUser, can } from '@/lib/auth';
import { getRoomBoard } from '@/modules/rooms/service';
import { queryOne } from '@/lib/db';
import { formatDate } from '@/lib/format';
import { Badge, PageHeader, EmptyState, StatCard } from '@/components/ui';

export const dynamic = 'force-dynamic';

export default async function RoomsPage() {
  const user = await getSessionUser();
  if (!user) redirect('/login');
  if (!can(user, 'rooms.read')) {
    return <EmptyState message="You do not have permission to view rooms." />;
  }

  const property = user.properties[0];
  const ctx = { userId: user.id, userEmail: user.email };

  const dateRow = await queryOne<{ d: string }>(
    `SELECT COALESCE(
       (SELECT max(stay_date)::text FROM reservation_room_rates
         WHERE property_id = $1 AND stay_date <= CURRENT_DATE),
       (SELECT min(stay_date)::text FROM reservation_room_rates WHERE property_id = $1),
       CURRENT_DATE::text) AS d`,
    [property.id], ctx,
  );
  const businessDate = dateRow?.d ?? new Date().toISOString().slice(0, 10);

  const rooms = await getRoomBoard(property.id, businessDate, ctx);
  const occupied = rooms.filter((r) => r.guestName).length;
  const dirty = rooms.filter((r) => r.housekeepingStatus === 'DIRTY').length;

  // Group by floor so the board matches how staff walk the building.
  const byFloor = rooms.reduce<Record<string, typeof rooms>>((acc, r) => {
    const key = r.floor ?? 'Unassigned';
    (acc[key] ??= []).push(r);
    return acc;
  }, {});

  return (
    <>
      <PageHeader title="Rooms"
        subtitle={`Status on ${formatDate(businessDate)} · occupancy read from the room-night ledger`} />

      <section className="grid gap-3 sm:grid-cols-4 mb-6">
        <StatCard label="Total rooms" value={String(rooms.length)} />
        <StatCard label="Occupied" value={String(occupied)} tone="brand" />
        <StatCard label="Vacant" value={String(rooms.length - occupied)} tone="positive" />
        <StatCard label="Needs cleaning" value={String(dirty)} tone={dirty > 0 ? 'negative' : 'default'} />
      </section>

      <div className="space-y-6">
        {Object.entries(byFloor).sort(([a], [b]) => a.localeCompare(b)).map(([floor, list]) => (
          <section key={floor}>
            <h2 className="font-semibold text-sm mb-3">
              Floor {floor}<span className="muted font-normal ml-2">{list.length} rooms</span>
            </h2>
            <div className="grid gap-3 grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6">
              {list.map((r) => (
                <div key={r.id}
                     className={['panel p-3', r.guestName ? 'border-brand-400 dark:border-brand-700' : ''].join(' ')}>
                  <div className="flex items-start justify-between gap-2">
                    <span className="text-lg font-semibold tabular">{r.roomNumber}</span>
                    <span className="muted text-xs">{r.roomTypeCode}</span>
                  </div>
                  <div className="mt-2 flex flex-wrap gap-1">
                    <Badge value={r.guestName ? 'OCCUPIED' : 'AVAILABLE'} />
                    <Badge value={r.housekeepingStatus} />
                  </div>
                  {r.guestName ? (
                    <div className="mt-2 min-w-0">
                      {r.reservationId ? (
                        <Link href={`/reservations/${r.reservationId}`}
                              className="text-xs font-medium text-brand-600 hover:underline block truncate">
                          {r.guestName}
                        </Link>
                      ) : <p className="text-xs font-medium truncate">{r.guestName}</p>}
                      <p className="muted text-xs">out {formatDate(r.departureDate)}</p>
                    </div>
                  ) : <p className="muted text-xs mt-2">Vacant</p>}
                </div>
              ))}
            </div>
          </section>
        ))}
      </div>
    </>
  );
}
