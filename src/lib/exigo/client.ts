/**
 * Exigo SQL Server reader.
 *
 * Port of app/clients/exigo_client.rb. Exigo is a SQL Server dependency, not an
 * HTTP one — Azure SQL over TDS — so this is the one place in the migration
 * where the Node ecosystem is not a drop-in. `tiny_tds` becomes `mssql`
 * (tedious), which is pure JavaScript and needs no FreeTDS in the image.
 *
 * ## Bind parameters, not interpolation
 *
 * The Ruby built `DECLARE @paramN <type> = <quoted literal>` by string
 * interpolation and prepended it to the query; the only defence was
 * `quote_value`'s `gsub("'", "''")`. One of the inputs is a customer email
 * taken straight from a cart callback payload, which — before callback
 * signature verification existed — was attacker-controlled. This uses real
 * parameter binding, so the value never becomes part of the statement text.
 *
 * The declared SQL types are the Ruby's, kept deliberately:
 *  - customer/type ids bind as INT after a `to_i`, because
 *    `preferred_customer_type_id` arrives as the STRING "2" and binding it as
 *    NVARCHAR would lean on SQL Server implicitly converting to compare against
 *    an int column.
 *  - emails bind as NVARCHAR(MAX), matching `N'...'`.
 *
 * ## The write path is dead, and stays dead
 *
 * `updateCustomerType` is ported but never called: both Rails call sites are
 * commented out and log `[EXIGO UPDATE DISABLED]`. Turning it on is a product
 * decision, not a side effect of a migration.
 *
 * ## Timeouts
 *
 * 5s connect / 15s query, matching the Ruby. That is the whole 20s budget Fluid
 * gives a callback, on a fresh connection each time — see the note in
 * src/lib/pricing/context.ts on why the callback path treats an Exigo failure
 * as "unknown" rather than "retail".
 */

import type { ExigoCredentials } from "@/lib/integration-settings";

export class ExigoError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ExigoError";
  }
}

export class ExigoConnectionError extends ExigoError {
  constructor(message: string) {
    super(message);
    this.name = "ExigoConnectionError";
  }
}

export class ExigoApiError extends ExigoError {
  constructor(message: string) {
    super(message);
    this.name = "ExigoApiError";
  }
}

const LOGIN_TIMEOUT_MS = 5_000;
const QUERY_TIMEOUT_MS = 15_000;

type BindType = "int" | "nvarchar";
interface Binding {
  name: string;
  type: BindType;
  value: number | string;
}

export interface ExigoReader {
  customerHasActiveAutoshipByEmail(email: string): Promise<boolean>;
  customerTypeByEmail(email: string): Promise<number | string | null>;
  customerHasActiveAutoship(customerId: string | number): Promise<boolean>;
  customersWithActiveAutoships(): Promise<Array<string | number>>;
  customersByTypeId(typeId: string | number): Promise<Array<string | number>>;
  getCustomerType(customerId: string | number): Promise<number | string | null>;
  findCustomerIdByEmail(email: string): Promise<string | number | null>;
}

export class ExigoClient implements ExigoReader {
  constructor(
    private readonly credentials: ExigoCredentials,
    private readonly companyName: string,
  ) {}

  /**
   * Opens a connection, runs one statement, closes it.
   *
   * One connection per query, exactly as the Ruby did (`execute_query` opened
   * and closed its own TinyTds client). A pool would be an improvement, and it
   * is deliberately NOT made here: it changes the failure and latency profile
   * of a path that sits on the shopper's request thread, and this migration's
   * job is to move the code, not to retune it.
   */
  private async query<Row = Record<string, unknown>>(
    sql: string,
    bindings: Binding[] = [],
  ): Promise<Row[]> {
    // Imported lazily so the module graph of a route that never touches Exigo
    // does not pull tedious in, and so the edge compilation of instrumentation
    // never sees it.
    const mssql = (await import("mssql")).default;

    let pool: import("mssql").ConnectionPool | undefined;
    try {
      pool = new mssql.ConnectionPool({
        server: this.credentials.dbHost,
        user: this.credentials.dbUsername,
        password: this.credentials.dbPassword,
        database: this.credentials.dbName,
        connectionTimeout: LOGIN_TIMEOUT_MS,
        requestTimeout: QUERY_TIMEOUT_MS,
        options: {
          // Azure SQL requires TLS. `azure: true` in tiny_tds meant the same.
          encrypt: true,
          trustServerCertificate: false,
        },
      });
      await pool.connect();
    } catch (error) {
      await pool?.close().catch(() => {});
      throw new ExigoConnectionError(
        `Failed to connect to Exigo SQL Server database: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }

    try {
      const request = pool.request();
      for (const binding of bindings) {
        request.input(
          binding.name,
          binding.type === "int" ? mssql.Int : mssql.NVarChar(mssql.MAX),
          binding.value,
        );
      }
      const result = await request.query(sql);
      return (result.recordset ?? []) as Row[];
    } finally {
      await pool.close().catch(() => {});
    }
  }

  async customerTypes(): Promise<Array<Record<string, unknown>>> {
    return this.query("SELECT * FROM dbo.CustomerTypes");
  }

  async customersByTypeId(
    customerTypeId: string | number,
  ): Promise<Array<string | number>> {
    const rows = await this.query<{ CustomerID: string | number }>(
      "SELECT CustomerID FROM dbo.Customers WHERE CustomerTypeID = @param0",
      [{ name: "param0", type: "int", value: toInt(customerTypeId) }],
    );
    return rows.map((row) => row.CustomerID);
  }

  async customersWithActiveAutoships(): Promise<Array<string | number>> {
    const rows = await this.query<{ CustomerID: string | number }>(
      "SELECT * FROM dbo.AutoOrders WHERE AutoOrderStatusID = 0 AND NextRunDate >= GETDATE()",
    );
    return Array.from(new Set(rows.map((row) => row.CustomerID)));
  }

  async customerHasActiveAutoship(
    customerId: string | number,
  ): Promise<boolean> {
    const rows = await this.query<{ count: number }>(
      "SELECT COUNT(*) AS count FROM dbo.AutoOrders " +
        "WHERE CustomerID = @param0 AND AutoOrderStatusID = 0 AND NextRunDate >= GETDATE()",
      [{ name: "param0", type: "int", value: toInt(customerId) }],
    );
    return Number(rows[0]?.count ?? 0) > 0;
  }

  /**
   * The callback path's autoship question, by email.
   *
   * The email binds VERBATIM. Normalising it (strip/downcase) would ask a
   * different question than the one the caller asked: `WHERE c.Email = @p`
   * treats leading whitespace as significant, and the column collation may be
   * case-sensitive.
   */
  async customerHasActiveAutoshipByEmail(email: string): Promise<boolean> {
    const rows = await this.query<{ count: number }>(
      "SELECT COUNT(*) AS count FROM dbo.AutoOrders ao " +
        "INNER JOIN dbo.Customers c ON ao.CustomerID = c.CustomerID " +
        "WHERE c.Email = @param0 AND ao.AutoOrderStatusID = 0 AND ao.NextRunDate >= GETDATE()",
      [{ name: "param0", type: "nvarchar", value: String(email) }],
    );
    return Number(rows[0]?.count ?? 0) > 0;
  }

  async findCustomerIdByEmail(email: string): Promise<string | number | null> {
    const rows = await this.query<{ CustomerID: string | number }>(
      "SELECT CustomerID FROM dbo.Customers WHERE Email = @param0",
      [{ name: "param0", type: "nvarchar", value: String(email) }],
    );
    return rows[0]?.CustomerID ?? null;
  }

  /**
   * The by-email counterpart of `getCustomerType`, for the callback path, which
   * holds an email and not an id. ONE query rather than
   * findCustomerIdByEmail-then-getCustomerType: each query opens its own
   * connection, so the pair would spend two connects inside a callback budget.
   */
  async customerTypeByEmail(email: string): Promise<number | string | null> {
    const rows = await this.query<{ CustomerTypeID: number | string }>(
      "SELECT CustomerTypeID FROM dbo.Customers WHERE Email = @param0",
      [{ name: "param0", type: "nvarchar", value: String(email) }],
    );
    return rows[0]?.CustomerTypeID ?? null;
  }

  async getCustomerType(
    customerId: string | number,
  ): Promise<number | string | null> {
    const rows = await this.query<{ CustomerTypeID: number | string }>(
      "SELECT CustomerTypeID FROM dbo.Customers WHERE CustomerID = @param0",
      [{ name: "param0", type: "int", value: toInt(customerId) }],
    );
    return rows[0]?.CustomerTypeID ?? null;
  }

  /**
   * PATCH {api_base_url}/customers — the ONLY write.
   *
   * Ported dead: both Rails call sites are commented out. Enabling it is a
   * separate decision.
   */
  async updateCustomerType(
    customerId: string | number,
    customerTypeId: string | number,
  ): Promise<unknown> {
    const { apiBaseUrl, apiUsername, apiPassword } = this.credentials;
    if (!apiBaseUrl || !apiUsername || !apiPassword) {
      throw new ExigoApiError(
        `Exigo API credentials not configured for ${this.companyName}`,
      );
    }

    const url = new URL("customers", ensureTrailingSlash(apiBaseUrl));
    const auth = Buffer.from(`${apiUsername}:${apiPassword}`).toString("base64");

    let response: Response;
    try {
      response = await fetch(url, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Basic ${auth}`,
        },
        body: JSON.stringify({
          customerID: toInt(customerId),
          customerType: toInt(customerTypeId),
        }),
        signal: AbortSignal.timeout(30_000),
      });
    } catch (error) {
      throw new ExigoApiError(
        `Exigo API request failed: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }

    if (response.status === 401) {
      throw new ExigoApiError("Exigo API authentication failed");
    }
    if (response.status === 404) {
      throw new ExigoApiError(`Exigo customer not found: ${customerId}`);
    }
    const body = await response.text();
    if (!response.ok) {
      throw new ExigoApiError(`Exigo API error (${response.status}): ${body}`);
    }
    if (!body) return undefined;
    try {
      return JSON.parse(body);
    } catch (error) {
      throw new ExigoApiError(
        `Invalid JSON response from Exigo API: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }
}

function ensureTrailingSlash(url: string): string {
  return url.endsWith("/") ? url : `${url}/`;
}

/** Ruby `to_i` for the ids that reach a bind. */
function toInt(value: string | number): number {
  const parsed = Math.trunc(Number(value));
  return Number.isFinite(parsed) ? parsed : 0;
}
