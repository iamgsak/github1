import { query, type RequestContext } from '@/lib/db';

export interface RoomBoardRow {
  id: string; roomNumber: string; floor: string | null;
  roomTypeCode: string; roomTypeName: string;
  status: string; housekeepingStatus: string; isActive: boolean;
  guestName: string | null; departureDate: string | null; reservationId: string | null;
}

/**
 * Room status board. Occupancy is read from room_allocations -- the
 * authoritative room-night ledger -- rather than from rooms.status, so
 * the board cannot disagree with what is actually booked.
 */
export async function getRoomBoard(
  propertyId: string, businessDate: string, ctx?: RequestContext,
): Promise<RoomBoardRow[]> {
  const rows = await query<Record<string, string>>(
    `SELECT rm.id, rm.room_number, rm.floor, rt.code AS room_type_code,
            rt.name AS room_type_name, rm.status::text AS status,
            rm.housekeeping_status::text AS housekeeping_status, rm.is_active,
            g.full_name AS guest_name, rr.departure_date, r.id AS reservation_id
       FROM rooms rm
       JOIN room_types rt ON rt.id = rm.room_type_id
       LEFT JOIN LATERAL (
         SELECT ra.reservation_room_id FROM room_allocations ra
          WHERE ra.room_id = rm.id AND ra.is_active
            AND ra.stay_range @> $2::date AND ra.allocation_type = 'RESERVATION'
          LIMIT 1
       ) alloc ON true
       LEFT JOIN reservation_rooms rr ON rr.id = alloc.reservation_room_id
       LEFT JOIN reservations r ON r.id = rr.reservation_id
       LEFT JOIN guests g ON g.id = COALESCE(rr.guest_id, r.guest_id)
      WHERE rm.property_id = $1
      ORDER BY rm.floor NULLS LAST, rm.room_number`,
    [propertyId, businessDate], ctx,
  );

  return rows.map((r) => ({
    id: r.id, roomNumber: r.room_number, floor: r.floor ?? null,
    roomTypeCode: r.room_type_code, roomTypeName: r.room_type_name,
    status: r.status, housekeepingStatus: r.housekeeping_status,
    isActive: String(r.is_active) === 'true',
    guestName: r.guest_name ?? null, departureDate: r.departure_date ?? null,
    reservationId: r.reservation_id ?? null,
  }));
}
