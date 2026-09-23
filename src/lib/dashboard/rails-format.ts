/**
 * The Rails view helpers the ported ERB screens relied on, so a table renders
 * the same strings it did there.
 *
 * Times are UTC because the Rails app never set `config.time_zone`.
 */

const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

const pad2 = (n: number) => String(n).padStart(2, "0");

/** `created_at.strftime("%b %d, %Y")` — "Sep 03, 2026", day zero-padded. */
export function railsDate(iso: string): string {
  const d = new Date(iso);
  return `${MONTHS[d.getUTCMonth()]} ${pad2(d.getUTCDate())}, ${d.getUTCFullYear()}`;
}

/** `created_at.strftime("%I:%M %p")` — "05:07 PM", hour zero-padded, 12-hour. */
export function railsTime(iso: string): string {
  const d = new Date(iso);
  const h24 = d.getUTCHours();
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12;
  return `${pad2(h12)}:${pad2(d.getUTCMinutes())} ${h24 < 12 ? "AM" : "PM"}`;
}

/**
 * ActiveSupport's `String#humanize`: drop a trailing `_id`, turn underscores
 * into spaces, downcase, capitalise the first letter.
 * "preferred_customer" -> "Preferred customer", "webhook" -> "Webhook".
 */
export function humanize(value: string | null | undefined): string {
  if (!value) return "";
  const text = value
    .replace(/_id$/, "")
    .replace(/^_+/, "")
    .replace(/_/g, " ")
    .toLowerCase();
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/**
 * `number_with_precision(value, precision: 2)`: round half up to two places,
 * no thousands delimiter. Done on the decimal STRING rather than through a
 * float, because the value is a Prisma Decimal and `Number("1.005").toFixed(2)`
 * is "1.00" — the float error Rails' BigDecimal never had.
 */
export function numberWithPrecision2(value: string | number): string {
  const text = String(value).trim();
  const match = /^(-?)(\d*)(?:\.(\d*))?$/.exec(text);
  if (!match) return Number(value).toFixed(2);

  const sign = match[1];
  const whole = match[2] || "0";
  const frac = (match[3] ?? "").padEnd(3, "0");

  let cents = BigInt(whole) * 100n + BigInt(frac.slice(0, 2));
  if (Number(frac[2]) >= 5) cents += 1n;

  const out = `${cents / 100n}.${String(cents % 100n).padStart(2, "0")}`;
  return sign && cents !== 0n ? `-${out}` : out;
}
