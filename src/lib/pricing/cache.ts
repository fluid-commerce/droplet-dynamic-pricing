/**
 * The preferred-status lookup cache.
 *
 * Replaces `Rails.cache` (Solid Cache, in its own Postgres database) with an
 * in-process map. See the note on `PreferredLookupCache` in ./deps.ts for why
 * that is the safe direction: the cache only ever suppresses a REPEAT lookup
 * inside a 30-second window, so a cold container pays one extra Fluid or Exigo
 * call rather than reading a stale answer.
 *
 * Entries are small (a boolean per company × identity) and expire, but a
 * container that lives for days would otherwise accumulate every shopper it has
 * ever seen — so the map is swept, and hard-capped.
 */

import { createHash } from "node:crypto";
import type { PreferredLookupCache } from "./deps";

interface Entry {
  value: boolean;
  expiresAt: number;
}

const MAX_ENTRIES = 10_000;

export class MemoryPreferredLookupCache implements PreferredLookupCache {
  private readonly entries = new Map<string, Entry>();

  constructor(private readonly now: () => number = Date.now) {}

  digest(value: string): string {
    return createHash("sha256").update(value).digest("hex");
  }

  read(key: string): boolean | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= this.now()) {
      this.entries.delete(key);
      return undefined;
    }
    return entry.value;
  }

  write(key: string, value: boolean, ttlSeconds: number): void {
    if (ttlSeconds <= 0) return;
    this.sweep();
    if (this.entries.size >= MAX_ENTRIES && !this.entries.has(key)) {
      // Oldest insertion first — Map preserves it. A crude eviction, but the
      // cap exists to bound memory, not to maximise hit rate.
      const oldest = this.entries.keys().next();
      if (!oldest.done) this.entries.delete(oldest.value);
    }
    this.entries.set(key, {
      value,
      expiresAt: this.now() + ttlSeconds * 1000,
    });
  }

  private sweep(): void {
    const now = this.now();
    for (const [key, entry] of this.entries) {
      if (entry.expiresAt <= now) this.entries.delete(key);
    }
  }

  /** Test hook. Never called in production. */
  clear(): void {
    this.entries.clear();
  }
}

/**
 * The process-wide instance.
 *
 * Module scope survives across requests in a warm Cloud Run container, which is
 * exactly the lifetime the burst of one-callback-per-cart-line needs.
 */
export const preferredLookupCache = new MemoryPreferredLookupCache();
