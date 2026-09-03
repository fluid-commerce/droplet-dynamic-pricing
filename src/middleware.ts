/**
 * Route guards.
 *
 * Replaces `before_action :authenticate_user!` on AdminController: everything
 * under /admin requires a session, and a signed-out visitor is redirected to
 * /login with a callback back to where they were going.
 *
 * The finer-grained CanCanCan checks stay where they were — in the pages and
 * route handlers, via `can()` — because middleware runs on the edge and cannot
 * read the database to find out what a subject is.
 *
 * API routes are excluded outright. /api/webhooks and /api/callbacks
 * authenticate with an HMAC signature, and a session redirect in front of them
 * would answer Fluid with a 307 to an HTML login page.
 */

import NextAuth from "next-auth";
import { NextResponse } from "next/server";

import { authConfig } from "./auth.config";

const { auth } = NextAuth(authConfig);

export default auth((request) => {
  const { pathname } = request.nextUrl;

  if (pathname.startsWith("/api/")) return NextResponse.next();

  if (pathname.startsWith("/admin")) {
    if (!request.auth?.user) {
      const login = new URL("/login", request.nextUrl.origin);
      login.searchParams.set("callbackUrl", pathname);
      return NextResponse.redirect(login);
    }
  }

  return NextResponse.next();
});

export const config = {
  matcher: [
    // Everything except Next's own assets and static files.
    "/((?!_next/static|_next/image|favicon.ico|icon.png|icon.svg|robots.txt|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
