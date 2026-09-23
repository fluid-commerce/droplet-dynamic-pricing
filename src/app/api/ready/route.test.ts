/**
 * The startup probe must say "ready" only when the database answers, and must
 * answer — never hang — when it does not, so Cloud Run can retry.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const { queryRaw } = vi.hoisted(() => ({ queryRaw: vi.fn() }));
vi.mock("@/lib", () => ({ prisma: { $queryRaw: queryRaw } }));

const { GET } = await import("./route");

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
  vi.useRealTimers();
});

describe("GET /api/ready", () => {
  it("answers 200 once the database responds", async () => {
    queryRaw.mockResolvedValue([{ "?column?": 1 }]);

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ready" });
  });

  it("answers 503 while the Cloud SQL socket is not up yet", async () => {
    queryRaw.mockRejectedValue(
      new Error(
        "\nInvalid `prisma.$queryRaw()` invocation:\nCan't reach database server at `/cloudsql/x:5432`",
      ),
    );

    const response = await GET();

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ status: "database_unavailable" });
  });

  it("answers 503 instead of hanging when the query never returns", async () => {
    vi.useFakeTimers();
    queryRaw.mockReturnValue(new Promise(() => {}));

    const pending = GET();
    await vi.advanceTimersByTimeAsync(2_500);
    const response = await pending;

    expect(response.status).toBe(503);
  });
});
