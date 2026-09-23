/**
 * ActionView's `time_ago_in_words`, for the one place the show page uses it.
 *
 * Reimplemented rather than pulled from a date library because the thresholds
 * are the output: "about 1 hour", "3 months", "less than a minute" are the
 * strings a merchant already reads on this screen, and a generic relative
 * formatter renders them differently.
 */
export function timeAgoInWords(from: Date, now: Date = new Date()): string {
  const seconds = Math.round((now.getTime() - from.getTime()) / 1000);
  const minutes = Math.round(seconds / 60);

  if (minutes < 1) return "less than a minute";
  if (minutes < 45) return minutes === 1 ? "1 minute" : `${minutes} minutes`;

  const hours = Math.round(minutes / 60);
  if (minutes < 1440)
    return hours === 1 ? "about 1 hour" : `about ${hours} hours`;

  const days = Math.round(minutes / 1440);
  if (minutes < 43200) return days === 1 ? "1 day" : `${days} days`;

  // 30 to 60 days is a bucket of its own in ActionView, not a rounding of
  // months — 45 days is "about 1 month", where rounding would say "2 months".
  if (minutes < 86400) return "about 1 month";

  const months = Math.round(minutes / 43200);
  if (minutes < 525600) return `${months} months`;

  const years = Math.round(minutes / 525600);
  return years === 1 ? "about 1 year" : `about ${years} years`;
}
