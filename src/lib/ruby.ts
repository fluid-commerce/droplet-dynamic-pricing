/**
 * The handful of Ruby coercions the pricing engine depends on.
 *
 * `base_service.rb` leans on `to_f`, `to_i`, `blank?` and `present?` at points
 * where the difference between them and their JavaScript lookalikes decides
 * what a shopper is charged. They are reproduced here once, with the
 * differences stated, rather than approximated at each call site:
 *
 *  - `Number("")` is `0`, but `"".to_f` is also `0.0` — those agree. What does
 *    NOT agree is `Number("12abc")`, which is `NaN`, while `"12abc".to_f` is
 *    `12.0`. A `NaN` price silently fails every `> 0` comparison, so a line
 *    that Ruby would have repriced is dropped.
 *  - `Number(null)` is `0` but `Number(undefined)` is `NaN`; Ruby has one nil.
 *  - `blank?` is true for `""` AND for `"   "`. `!value` is not.
 */

/** Ruby's `to_f`: leading numeric prefix, `0.0` for anything unparseable. */
export function toF(value: unknown): number {
  if (typeof value === "number") return Number.isFinite(value) ? value : 0;
  if (typeof value === "boolean" || value === null || value === undefined) {
    return 0;
  }
  const match = /^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?/.exec(String(value));
  if (!match) return 0;
  const parsed = Number(match[0]);
  return Number.isFinite(parsed) ? parsed : 0;
}

/** Ruby's `to_i`: truncates toward zero, `0` for anything unparseable. */
export function toI(value: unknown): number {
  return Math.trunc(toF(value));
}

/**
 * Ruby's `blank?`, for the value shapes that reach a callback payload.
 *
 * `false.blank?` is true in Ruby, and that matters: `variant_country`'s
 * `active` flag is read with a nil-vs-false distinction elsewhere, so anything
 * asking `blank?` about a boolean has to agree with Ruby rather than with
 * JavaScript falsiness.
 */
export function isBlank(value: unknown): boolean {
  if (value === null || value === undefined || value === false) return true;
  if (typeof value === "string") return value.trim().length === 0;
  if (Array.isArray(value)) return value.length === 0;
  if (typeof value === "object") return Object.keys(value).length === 0;
  return false;
}

/** Ruby's `present?`. */
export function isPresent(value: unknown): boolean {
  return !isBlank(value);
}

/**
 * `ActiveModel::Type::Boolean`, exactly.
 *
 * Rails treats `nil` and this fixed set of values as false and EVERYTHING else
 * as true — including the string "no", and including an empty array. A bare
 * `Boolean(value)` gets the string `"false"` exactly backwards, and the two
 * settings read through this decide whether a company prices its carts at all.
 */
const FALSE_VALUES = new Set<unknown>([
  false,
  0,
  "0",
  "f",
  "F",
  "false",
  "FALSE",
  "False",
  "off",
  "OFF",
  "Off",
  "",
]);

export function castBoolean(value: unknown): boolean {
  if (value === null || value === undefined) return false;
  return !FALSE_VALUES.has(value);
}

/**
 * Ruby's `value || fallback`, which falls through on `nil` and `false` ONLY.
 *
 * An empty string is truthy in Ruby, so `"" || "price_ratio"` is `""`.
 */
export function orDefault(value: unknown, fallback: string): string {
  if (value === null || value === undefined || value === false) return fallback;
  return String(value);
}

/**
 * Reads a key from a payload object that may use either string or symbol-ish
 * keys, keeping a present `false` distinct from an absent key.
 *
 * Rails' controllers handed the services a `HashWithIndifferentAccess` in
 * production and a plain Hash in tests, which is why so many readers in
 * `base_service.rb` try both spellings. JSON.parse only ever produces string
 * keys, so this is a single lookup — but it keeps the `!== undefined` guard,
 * because `row["active"] === false` must not be read as "absent".
 */
export function field<T = unknown>(
  record: unknown,
  key: string,
): T | undefined {
  if (!record || typeof record !== "object") return undefined;
  const value = (record as Record<string, unknown>)[key];
  return value as T | undefined;
}
