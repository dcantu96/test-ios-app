import { createPool, migrate } from "./db.ts";
import { createApp } from "./server.ts";

const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? "127.0.0.1";

const pool = createPool();
await migrate(pool);

const server = createApp(pool);
server.listen(port, host, () => {
  console.log(`Time Capsule API listening on http://${host}:${port}`);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    server.close();
    void pool.end().then(() => process.exit(0));
  });
}
