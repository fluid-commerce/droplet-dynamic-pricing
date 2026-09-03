/**
 * Boot-time report of whether this droplet can verify callbacks at all.
 *
 * The callback routes verify every request against a stored registration
 * token. If `fluid_callback_registrations` is empty — the backfill was skipped,
 * or run against the wrong database — every live callback is refused, and the
 * refusal answers 200 with a neutral body because Fluid blocks a live checkout
 * on this response. Fluid sees success. No error rate moves. Nothing alerts.
 *
 * So the droplet says on startup which state it is in.
 *
 * The `if (...) { }` form is deliberate and NOT interchangeable with an early
 * `return`. This repo has middleware, so instrumentation is compiled for the
 * edge runtime too, and an early return leaves the dynamic import statically
 * reachable — webpack then tries to bundle the SDK's `node:crypto` for edge and
 * the build fails with UnhandledSchemeError. Wrapping the import in the branch
 * lets it constant-fold the whole thing away.
 */
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const { reportCallbackVerificationReadiness } = await import(
      "@fluid-app/droplet-sdk"
    );
    const { prisma } = await import("@/lib/db");

    // Fired detached, never awaited. Next awaits `register()` before it serves,
    // and this retries across minutes — awaiting it would put that whole span
    // in front of the first request of every cold start. The answer is a log
    // line; nothing about request handling depends on it.
    void (async () => {
      await reportCallbackVerificationReadiness({
        countRegistrations: () => prisma.fluidCallbackRegistration.count(),
        backfillCommand: "pnpm backfill:callbacks",
      });
    })();
  }
}
