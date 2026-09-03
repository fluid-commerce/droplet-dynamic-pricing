/**
 * Server-side authorisation for admin pages and route handlers.
 *
 * Replaces CanCanCan's `authorize!` / `current_ability`. A page calls
 * `requirePermission("manage", "User")`; a subject the session's permission
 * sets do not cover gets a redirect (for a page) or a 403 (for a handler),
 * rather than being rendered and failing at the write.
 */

import { redirect } from "next/navigation";

import { prisma } from "@/lib/db";
import { auth } from "@/auth";
import { can, type Action, type Subject } from "@/lib/permissions";

export interface CurrentUser {
  id: string;
  email: string | null | undefined;
  permissionSets: string[];
}

export async function currentUser(): Promise<CurrentUser | null> {
  const session = await auth();
  if (!session?.user) return null;

  // Permissions are re-read from the database, NOT taken from the JWT.
  //
  // The token is issued at sign-in and carries whatever the user had then, so
  // trusting it means removing an admin's permissions — or deleting the
  // account outright — leaves their existing cookie authorising every admin
  // operation until it expires. Rails/Devise loads `current_user` per request
  // and does not have that gap; a port that reintroduces it is a regression in
  // an admin console.
  //
  // A row that has disappeared returns null, so a deleted user is signed out on
  // their next request rather than at token expiry.
  const user = await prisma.user.findUnique({
    where: { id: Number(session.user.id) },
    select: { id: true, email: true, permissionSets: true },
  });
  if (!user) return null;

  return {
    id: String(user.id),
    email: user.email,
    permissionSets: Array.isArray(user.permissionSets)
      ? (user.permissionSets as unknown[]).filter(
          (p): p is string => typeof p === "string",
        )
      : [],
  };
}

/** Redirects unless the signed-in user may perform `action` on `subject`. */
export async function requirePermission(
  action: Action,
  subject: Subject,
): Promise<CurrentUser> {
  const user = await currentUser();
  if (!user) redirect("/login");

  if (!can(user, action, subject)) {
    redirect(`/admin?alert=${encodeURIComponent("Not authorized")}`);
  }

  return user;
}

/** Route-handler equivalent: returns the user, or a 401/403 Response. */
export async function authorizeRequest(
  action: Action,
  subject: Subject,
): Promise<{ user: CurrentUser } | { response: Response }> {
  const user = await currentUser();
  if (!user) {
    return {
      response: Response.json({ error: "unauthorized" }, { status: 401 }),
    };
  }
  if (!can(user, action, subject)) {
    return {
      response: Response.json({ error: "forbidden" }, { status: 403 }),
    };
  }
  return { user };
}
