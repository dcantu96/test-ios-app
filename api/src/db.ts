import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import pg from "pg";

export type Pool = pg.Pool;

export function createPool(connectionString = process.env.DATABASE_URL): pg.Pool {
  if (!connectionString) throw new Error("DATABASE_URL is not set");
  return new pg.Pool({ connectionString, max: 5 });
}

/** Apply every .sql file in api/migrations in name order. Files are written to be idempotent. */
export async function migrate(pool: pg.Pool): Promise<void> {
  const dir = join(import.meta.dirname, "..", "migrations");
  const files = (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort();
  for (const file of files) {
    await pool.query(await readFile(join(dir, file), "utf8"));
  }
}
