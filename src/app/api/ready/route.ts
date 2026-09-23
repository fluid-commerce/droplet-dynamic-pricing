/**
 * GET /api/ready — the Cloud Run STARTUP probe. Answers 200 only once the
 * database is reachable.
 *
 * Why this exists: Cloud Run's default startup probe is a TCP check on the
 * port, which Next passes about 1.5s after the container starts. The Cloud SQL
 * socket (`/cloudsql/...`, mounted by Cloud Run's connector) takes several
 * seconds longer to appear. In that window the instance was already receiving
 * pricing callbacks it could not serve: the first Prisma query waited, failed
 * with "Can't reach database server", and the callback ran past the ~5s Fluid
 * allows it — a timeout on Fluid's side, and a cart left at the price it came
 * with. Seen on 2026-09-23, on the first request of every new instance.
 *
 * With cloudbuild-next.yml pointing the startup probe here, Cloud Run holds
 * traffic until this answers 200, so the first callback lands on an instance
 * whose pool already has a live connection.
 *
 * /api/health stays database-free on purpose. It is what ci-next's boot check
 * and liveness mean — "the process serves" — and it must not fail because the
 * database is slow.
 *
 * Unauthenticated, like /api/health: it returns a status and nothing else.
 */

import { prisma } from "@/lib";

export const dynamic = "force-dynamic";

/**
 * Well under the probe's own timeoutSeconds (3s), so a stuck query answers 503
 * and the probe retries instead of the request hanging until Cloud Run cuts it.
 */
const QUERY_TIMEOUT_MS = 2_500;

export async function GET() {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      prisma.$queryRaw`SELECT 1`,
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`timed out after ${QUERY_TIMEOUT_MS}ms`)),
          QUERY_TIMEOUT_MS,
        );
      }),
    ]);
    return Response.json({ status: "ready" });
  } catch (error) {
    // Logged, because a probe that keeps failing keeps a deploy from going
    // live, and this is the only place that says why.
    console.warn(
      "[ready] database not reachable yet:",
      error instanceof Error ? error.message.split("\n").filter(Boolean)[0] : error,
    );
    return Response.json({ status: "database_unavailable" }, { status: 503 });
  } finally {
    if (timer) clearTimeout(timer);
  }
}
