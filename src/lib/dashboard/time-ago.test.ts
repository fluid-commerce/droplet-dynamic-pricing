/**
 * `time_ago_in_words` — the show page prints "3 months ago".
 *
 * ActionView's thresholds, not a generic relative formatter: the original's
 * output is what a merchant recognises on that screen.
 */

import { describe, it, expect } from "vitest";

import { timeAgoInWords } from "./time-ago";

const now = new Date("2026-09-17T12:00:00Z");
const ago = (ms: number) => new Date(now.getTime() - ms);

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

describe("timeAgoInWords", () => {
  it.each([
    [ago(20_000), "less than a minute"],
    [ago(1 * MIN), "1 minute"],
    [ago(30 * MIN), "30 minutes"],
    [ago(1 * HOUR), "about 1 hour"],
    [ago(5 * HOUR), "about 5 hours"],
    [ago(1 * DAY), "1 day"],
    [ago(20 * DAY), "20 days"],
    [ago(45 * DAY), "about 1 month"],
    [ago(90 * DAY), "3 months"],
    [ago(400 * DAY), "about 1 year"],
  ])("%s → %s", (date, expected) => {
    expect(timeAgoInWords(date, now)).toBe(expected);
  });
});
