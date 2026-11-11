import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Pool } from "./db.ts";

const MAX_SEAL_SECONDS = 60 * 60 * 24 * 365 * 25; // 25 years
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Row = {
  id: string;
  message: string;
  sealed_at: Date;
  unlocks_at: Date;
  opened_at: Date | null;
  server_now: Date;
};

/**
 * The server clock is the only authority on whether a capsule is open.
 * A sealed capsule never includes its message in any response.
 */
function present(row: Row, { reveal }: { reveal: boolean }) {
  const remainingMs = row.unlocks_at.getTime() - row.server_now.getTime();
  const status = remainingMs > 0 ? "sealed" : row.opened_at ? "opened" : "ready";
  return {
    id: row.id,
    status,
    sealedAt: row.sealed_at.toISOString(),
    unlocksAt: row.unlocks_at.toISOString(),
    openedAt: row.opened_at?.toISOString() ?? null,
    secondsRemaining: Math.max(0, Math.ceil(remainingMs / 1000)),
    serverNow: row.server_now.toISOString(),
    message: reveal && status !== "sealed" ? row.message : null,
  };
}

function send(res: ServerResponse, status: number, body: unknown) {
  const json = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(json) });
  res.end(json);
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 10_000) throw new HttpError(413, "Body too large");
  }
  try {
    return raw ? JSON.parse(raw) : {};
  } catch {
    throw new HttpError(400, "Body must be JSON");
  }
}

class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

const COLUMNS = "id, message, sealed_at, unlocks_at, opened_at, now() as server_now";

export function createApp(pool: Pool): Server {
  async function route(req: IncomingMessage, res: ServerResponse) {
    const url = new URL(req.url ?? "/", "http://localhost");
    const parts = url.pathname.split("/").filter(Boolean);

    if (req.method === "GET" && url.pathname === "/health") {
      const { rows } = await pool.query("select now() as now, count(*)::int as capsules from capsules");
      return send(res, 200, { ok: true, db: "up", ...rows[0] });
    }

    if (parts[0] !== "capsules" || parts.length > 2) throw new HttpError(404, "Not found");

    // POST /capsules  { message, unlockInSeconds }
    if (req.method === "POST" && parts.length === 1) {
      const body = (await readJson(req)) as { message?: unknown; unlockInSeconds?: unknown };
      const message = typeof body.message === "string" ? body.message.trim() : "";
      const seconds = body.unlockInSeconds;
      if (!message || message.length > 500) throw new HttpError(400, "message must be 1-500 characters");
      if (typeof seconds !== "number" || !Number.isInteger(seconds) || seconds < 1 || seconds > MAX_SEAL_SECONDS) {
        throw new HttpError(400, `unlockInSeconds must be an integer from 1 to ${MAX_SEAL_SECONDS}`);
      }
      const { rows } = await pool.query<Row>(
        `insert into capsules (message, unlocks_at) values ($1, now() + make_interval(secs => $2))
         returning ${COLUMNS}`,
        [message, seconds],
      );
      return send(res, 201, present(rows[0], { reveal: false }));
    }

    // GET /capsules  (newest first; only opened capsules show their message)
    if (req.method === "GET" && parts.length === 1) {
      const { rows } = await pool.query<Row>(`select ${COLUMNS} from capsules order by sealed_at desc limit 50`);
      return send(res, 200, rows.map((r) => present(r, { reveal: r.opened_at !== null })));
    }

    // GET /capsules/:id  -> 423 while sealed, otherwise opens it and reveals the message
    if (req.method === "GET" && parts.length === 2) {
      const id = parts[1];
      if (!UUID.test(id)) throw new HttpError(404, "Capsule not found");
      const { rows } = await pool.query<Row>(
        `update capsules set opened_at = coalesce(opened_at, now())
         where id = $1 and unlocks_at <= now()
         returning ${COLUMNS}`,
        [id],
      );
      if (rows[0]) return send(res, 200, present(rows[0], { reveal: true }));

      const sealed = await pool.query<Row>(`select ${COLUMNS} from capsules where id = $1`, [id]);
      if (!sealed.rows[0]) throw new HttpError(404, "Capsule not found");
      const capsule = present(sealed.rows[0], { reveal: false });
      return send(res, 423, { error: "Still sealed", ...capsule });
    }

    throw new HttpError(405, "Method not allowed");
  }

  return createServer((req, res) => {
    const started = Date.now();
    route(req, res)
      .catch((err: unknown) => {
        if (err instanceof HttpError) return send(res, err.status, { error: err.message });
        console.error(err);
        send(res, 500, { error: "Internal error" });
      })
      .finally(() => {
        if (process.env.LOG_REQUESTS !== "0") {
          console.log(`${req.method} ${req.url} -> ${res.statusCode} (${Date.now() - started}ms)`);
        }
      });
  });
}
