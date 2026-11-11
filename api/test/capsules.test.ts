import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { after, before, describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { createPool, migrate, type Pool } from "../src/db.ts";
import { createApp } from "../src/server.ts";

// Runs against a real Postgres: DATABASE_URL must point at a database the tests may write to.
let pool: Pool;
let base: string;
let close: () => Promise<void>;

before(async () => {
  process.env.LOG_REQUESTS = "0";
  pool = createPool();
  await migrate(pool);
  const server = createApp(pool);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  close = async () => {
    await new Promise((resolve) => server.close(resolve));
    await pool.end();
  };
});

after(() => close());

async function call(path: string, init?: { method?: string; body?: unknown }) {
  const res = await fetch(base + path, {
    method: init?.method ?? "GET",
    headers: init?.body ? { "content-type": "application/json" } : undefined,
    body: init?.body ? JSON.stringify(init.body) : undefined,
  });
  return { status: res.status, body: (await res.json()) as Record<string, any> };
}

describe("time capsules", () => {
  test("health reports the database is up", async () => {
    const { status, body } = await call("/health");
    assert.equal(status, 200);
    assert.equal(body.db, "up");
  });

  test("a capsule stays sealed until its unlock time, then opens exactly once", async () => {
    const secret = `hello future me ${Date.now()}`;
    const created = await call("/capsules", { method: "POST", body: { message: secret, unlockInSeconds: 1 } });
    assert.equal(created.status, 201);
    assert.equal(created.body.status, "sealed");
    assert.equal(created.body.message, null, "sealing must not echo the message back");

    const early = await call(`/capsules/${created.body.id}`);
    assert.equal(early.status, 423);
    assert.equal(early.body.message, null);
    assert.ok(early.body.secondsRemaining >= 1);

    const listedSealed = (await call("/capsules")).body as unknown as any[];
    const mine = listedSealed.find((c) => c.id === created.body.id);
    assert.equal(mine.status, "sealed");
    assert.equal(mine.message, null);

    await sleep(1_300);

    const listedReady = ((await call("/capsules")).body as unknown as any[]).find((c) => c.id === created.body.id);
    assert.equal(listedReady.status, "ready");
    assert.equal(listedReady.message, null, "the list does not spoil a capsule nobody has opened");

    const opened = await call(`/capsules/${created.body.id}`);
    assert.equal(opened.status, 200);
    assert.equal(opened.body.status, "opened");
    assert.equal(opened.body.message, secret);

    const reopened = await call(`/capsules/${created.body.id}`);
    assert.equal(reopened.body.openedAt, opened.body.openedAt, "first opening time is kept");
  });

  test("every early knock is counted, and the count is revealed with the message", async () => {
    const secret = `knock knock ${Date.now()}`;
    const created = await call("/capsules", { method: "POST", body: { message: secret, unlockInSeconds: 1 } });
    assert.equal(created.body.knocks, 0);

    const first = await call(`/capsules/${created.body.id}`);
    assert.equal(first.status, 423);
    assert.equal(first.body.knocks, 1, "the refusal says which knock this was");
    const second = await call(`/capsules/${created.body.id}`);
    assert.equal(second.body.knocks, 2);
    assert.equal(second.body.message, null);

    const listed = ((await call("/capsules")).body as unknown as any[]).find((c) => c.id === created.body.id);
    assert.equal(listed.knocks, 2, "the list shows the knocks on a sealed capsule");

    await sleep(1_300);
    const opened = await call(`/capsules/${created.body.id}`);
    assert.equal(opened.status, 200);
    assert.equal(opened.body.message, secret);
    assert.equal(opened.body.knocks, 2, "opening on time isn't a knock");

    const again = await call(`/capsules/${created.body.id}`);
    assert.equal(again.body.knocks, 2, "reading an opened capsule isn't a knock either");
  });

  test("a capsule opened without knocking reports zero knocks", async () => {
    const created = await call("/capsules", { method: "POST", body: { message: "patient", unlockInSeconds: 1 } });
    await sleep(1_300);
    const opened = await call(`/capsules/${created.body.id}`);
    assert.equal(opened.status, 200);
    assert.equal(opened.body.knocks, 0);
  });

  test("an opened capsule can be answered, and the reply is sealed for as long as the original waited", async () => {
    const original = await call("/capsules", { method: "POST", body: { message: `first ${Date.now()}`, unlockInSeconds: 1 } });
    assert.equal(original.body.replyTo, null);

    const tooSoon = await call("/capsules", { method: "POST", body: { message: "too soon", replyTo: original.body.id } });
    assert.equal(tooSoon.status, 409, "you can only answer a capsule you've opened");

    await sleep(1_300);
    const opened = await call(`/capsules/${original.body.id}`);
    assert.equal(opened.status, 200);

    const reply = await call("/capsules", {
      method: "POST",
      body: { message: "got it, see you later", replyTo: original.body.id, unlockInSeconds: 999_999 },
    });
    assert.equal(reply.status, 201);
    assert.equal(reply.body.status, "sealed");
    assert.equal(reply.body.message, null, "a reply is sealed like any capsule");
    const span = (Date.parse(reply.body.unlocksAt) - Date.parse(reply.body.sealedAt)) / 1000;
    assert.ok(Math.abs(span - 1) < 0.01, `the server sets the span from the original (got ${span}s), ignoring the client's`);
    assert.deepEqual(reply.body.replyTo, { id: original.body.id, message: opened.body.message });

    const listed = ((await call("/capsules")).body as unknown as any[]).find((c) => c.id === reply.body.id);
    assert.deepEqual(listed.replyTo, { id: original.body.id, message: opened.body.message }, "the list shows what it answers");
    assert.equal(listed.message, null);
  });

  test("replying to a capsule that doesn't exist is a 404", async () => {
    const res = await call("/capsules", {
      method: "POST",
      body: { message: "hello?", replyTo: "00000000-0000-4000-8000-000000000000" },
    });
    assert.equal(res.status, 404);
    assert.equal((await call("/capsules", { method: "POST", body: { message: "x", replyTo: "nope" } })).status, 404);
  });

  test("rejects bad input", async () => {
    assert.equal((await call("/capsules", { method: "POST", body: { message: "", unlockInSeconds: 10 } })).status, 400);
    assert.equal((await call("/capsules", { method: "POST", body: { message: "x".repeat(501), unlockInSeconds: 10 } })).status, 400);
    assert.equal((await call("/capsules", { method: "POST", body: { message: "hi", unlockInSeconds: 0 } })).status, 400);
    assert.equal((await call("/capsules", { method: "POST", body: { message: "hi", unlockInSeconds: 1.5 } })).status, 400);
    assert.equal((await call("/capsules/not-a-uuid")).status, 404);
    assert.equal((await call("/capsules/00000000-0000-4000-8000-000000000000")).status, 404);
  });
});
