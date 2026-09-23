/**
 * `effectivePayload`, lifted out of the vendored SDK.
 *
 * The standalone repo carried a patched copy of @fluid-app/droplet-sdk under
 * `vendor/`, and this function lives only there — the monorepo's
 * `packages/droplet-sdk` does not export it. It is kept here rather than
 * upstreamed so this migration changes no shared code, and so
 * droplet-exigo-widgets and droplet-yoli-plus-membership are untouched by it.
 *
 * It matters because three consumers have to agree on WHICH object the event
 * was derived from — `eventOf`, the tenant-hint reader and the handler. When
 * the route kept its own unwrap rule, every shape where the two disagreed
 * produced either a 500 from the handler or a 401 from the resolver, because
 * hints were read from an outer envelope that has no `company`.
 *
 * Precedence mirrors the SDK's `eventOf` exactly, in the same order.
 */

export const effectivePayload = (body: unknown): unknown => {
  if (!body || typeof body !== "object" || Array.isArray(body)) return body;
  const record = body as Record<string, unknown>;

  const nested = record["payload"];
  const nestedIsObject =
    typeof nested === "object" && nested !== null && !Array.isArray(nested);

  // `name` wins in eventOf, so it wins here — even when root resource/event are
  // also present.
  const name = record["name"];
  if (typeof name === "string" && name.length > 0) {
    return nestedIsObject ? nested : record;
  }

  // Root pair next.
  if (
    typeof record["resource"] === "string" &&
    typeof record["event"] === "string"
  ) {
    return record;
  }

  // Then anything eventOf would have taken from the nested object, including
  // its `event`-only fallback.
  if (nestedIsObject) {
    const inner = nested as Record<string, unknown>;
    if (
      typeof inner["resource"] === "string" ||
      typeof inner["event"] === "string"
    ) {
      return nested;
    }
  }

  return record;
};

/**
 * The SDK's `eventOf`, copied because `packages/droplet-sdk` defines it but
 * does not re-export it from the `/next` entrypoint.
 *
 * The route needs it in `resolve`, to tell a lifecycle event from a company
 * one BEFORE offering a candidate secret — and it has to be the same rule the
 * SDK applies afterwards, or the two disagree about what the event is.
 */
export const eventOf = (payload: unknown): string => {
  if (!payload || typeof payload !== "object") return "unknown";
  const record = payload as Record<string, unknown>;

  const name = record["name"];
  if (typeof name === "string" && name.length > 0) {
    // "droplet_installed" -> "droplet.installed"; leave already-dotted alone.
    return name.includes(".") ? name : name.replace("_", ".");
  }

  const nested = (record["payload"] ?? {}) as Record<string, unknown>;
  const resource = record["resource"] ?? nested["resource"];
  const event = record["event"] ?? nested["event"];

  if (typeof resource === "string" && typeof event === "string") {
    return `${resource}.${event}`;
  }
  if (typeof event === "string") return event;

  return "unknown";
};
