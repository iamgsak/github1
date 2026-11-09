import { NextResponse, type NextRequest } from 'next/server';
import { z } from 'zod';
import { login, SESSION_COOKIE } from '@/lib/auth';

const schema = z.object({
  email: z.string().email('Enter a valid email address.'),
  password: z.string().min(1, 'Enter your password.'),
});

const MESSAGES: Record<string, string> = {
  INVALID_CREDENTIALS: 'Email or password is incorrect.',
  ACCOUNT_INACTIVE: 'This account has been deactivated. Contact your administrator.',
  ACCOUNT_LOCKED: 'Too many failed attempts. Try again later.',
};

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => null);
  const parsed = schema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: { code: 'VALIDATION_ERROR', message: 'Please check the details you entered.',
                 details: parsed.error.issues.map((i) => ({ field: i.path.join('.'), issue: i.message })) } },
      { status: 400 },
    );
  }

  const ip = req.headers.get('x-forwarded-for')?.split(',')[0].trim() ?? null;
  const result = await login(parsed.data.email, parsed.data.password, {
    ip, userAgent: req.headers.get('user-agent'),
  });

  if (!result.ok || !result.token) {
    const message = MESSAGES[result.error ?? 'INVALID_CREDENTIALS'];
    return NextResponse.json(
      { error: { code: result.error,
                 message: result.error === 'ACCOUNT_LOCKED' && result.retryAfterMinutes
                   ? `Too many failed attempts. Try again in ${result.retryAfterMinutes} minutes.`
                   : message } },
      { status: result.error === 'ACCOUNT_LOCKED' ? 429 : 401 },
    );
  }

  const res = NextResponse.json({ data: { ok: true } });
  res.cookies.set(SESSION_COOKIE, result.token, {
    httpOnly: true,                                 // unreadable from JS
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'lax',
    path: '/',
    maxAge: 12 * 60 * 60,
  });
  return res;
}
