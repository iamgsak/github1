import { NextResponse, type NextRequest } from 'next/server';
import { cookies } from 'next/headers';
import { logout, SESSION_COOKIE } from '@/lib/auth';

export async function POST(_req: NextRequest) {
  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  if (token) await logout(token);
  const res = NextResponse.json({ data: { ok: true } });
  res.cookies.set(SESSION_COOKIE, '', { path: '/', maxAge: 0 });
  return res;
}
