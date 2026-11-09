import { NextResponse, type NextRequest } from 'next/server';
import { randomUUID } from 'node:crypto';
import { getSessionUser, can, type SessionUser } from './auth';
import { AppError, translateDbError } from './errors';
import type { RequestContext } from './db';

export interface ApiContext {
  user: SessionUser;
  propertyId: string;
  requestId: string;
  db: RequestContext;
}

export function ok<T>(data: T, meta?: Record<string, unknown>) {
  return NextResponse.json(meta ? { data, meta } : { data });
}

export function fail(error: AppError, requestId: string) {
  return NextResponse.json(
    { error: { code: error.code, message: error.message,
               details: error.details ?? undefined, requestId } },
    { status: error.status },
  );
}

function clientIp(req: NextRequest): string | null {
  const fwd = req.headers.get('x-forwarded-for');
  if (fwd) return fwd.split(',')[0].trim();
  return req.headers.get('x-real-ip');
}

/**
 * Wraps a route handler with authentication, permission enforcement and
 * property scoping. Every handler declares what it needs; nothing is
 * implicit.
 *
 * This is the API-layer check. It is deliberately not the only one -- RLS
 * enforces the same boundary in the database, so a missed declaration here
 * still cannot leak another tenant's rows.
 */
export function withAuth(
  opts: { permission?: string; requireProperty?: boolean },
  handler: (req: NextRequest, ctx: ApiContext) => Promise<NextResponse>,
) {
  return async (req: NextRequest): Promise<NextResponse> => {
    const requestId = randomUUID();
    try {
      const user = await getSessionUser();
      if (!user) throw new AppError('UNAUTHENTICATED', 'Please sign in to continue.', 401);

      if (opts.permission && !can(user, opts.permission)) {
        throw new AppError('FORBIDDEN', 'You do not have permission to do that.', 403);
      }

      // Property scope: header wins, otherwise the user's only property.
      const headerProperty = req.headers.get('x-property-id');
      const propertyId = headerProperty ?? user.properties[0]?.id ?? '';

      if (opts.requireProperty !== false) {
        if (!propertyId) throw new AppError('NO_PROPERTY', 'No property is available to you.', 403);
        // A header may not be used to reach a property the user lacks.
        if (!user.isPlatformAdmin && !user.properties.some((p) => p.id === propertyId)) {
          throw new AppError('FORBIDDEN', 'You do not have access to that property.', 403);
        }
      }

      return await handler(req, {
        user, propertyId, requestId,
        db: { userId: user.id, userEmail: user.email, ip: clientIp(req), requestId },
      });
    } catch (err) {
      if (err instanceof AppError) return fail(err, requestId);
      const translated = translateDbError(err);
      if (translated.code === 'INTERNAL_ERROR') console.error(`[api] ${requestId}`, err);
      return fail(translated, requestId);
    }
  };
}
