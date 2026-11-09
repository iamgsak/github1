/**
 * Translates PostgreSQL errors into stable application error codes.
 *
 * The database is the authority on our invariants, so its rejections are
 * expected control flow, not surprises. This is where a constraint name
 * becomes a message a receptionist can act on.
 */
export class AppError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status: number = 400,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'AppError';
  }
}

interface PgError { code?: string; constraint?: string; message?: string; detail?: string }

const CONSTRAINT_MESSAGES: Record<string, [string, string, number]> = {
  room_allocations_no_overlap: ['ROOM_ALREADY_ALLOCATED', 'That room is already occupied for those dates.', 409],
  inventory_daily_capacity_chk: ['NO_AVAILABILITY', 'There are no rooms of that type left for those dates.', 409],
  reservations_external_ref_uq: ['DUPLICATE_BOOKING', 'This booking has already been imported from the channel.', 409],
  webhook_events_uq: ['DUPLICATE_EVENT', 'This event has already been processed.', 200],
  ota_reservations_uq: ['DUPLICATE_BOOKING', 'This channel booking already exists.', 409],
  pg_txn_payment_uq: ['DUPLICATE_PAYMENT', 'This payment has already been recorded.', 409],
  invoices_number_uq: ['DUPLICATE_INVOICE_NUMBER', 'That invoice number is already used.', 409],
};

export function translateDbError(err: unknown): AppError {
  const e = err as PgError;

  if (e?.constraint && CONSTRAINT_MESSAGES[e.constraint]) {
    const [code, message, status] = CONSTRAINT_MESSAGES[e.constraint];
    return new AppError(code, message, status);
  }

  switch (e?.code) {
    case '23505': return new AppError('DUPLICATE', 'That record already exists.', 409);
    case '23503': return new AppError('INVALID_REFERENCE', 'A referenced record does not exist.', 400);
    case '23514':
      return new AppError('BUSINESS_RULE_VIOLATION',
        e.message?.includes('status transition')
          ? 'That status change is not allowed.'
          : 'That change breaks a business rule.', 422);
    case '23P01': return new AppError('CONFLICT', 'That conflicts with an existing record.', 409);
    case '2F003':
    case '38003': return new AppError('IMMUTABLE_RECORD', 'That record cannot be changed.', 422);
    case '42501': return new AppError('FORBIDDEN', 'You do not have access to that.', 403);
    default:      return new AppError('INTERNAL_ERROR', 'Something went wrong.', 500);
  }
}
