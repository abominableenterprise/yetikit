import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import worker from "../src/index.js";

class MemoryBucket {
  objects = new Map();

  async put(key, value, { httpMetadata } = {}) {
    const bytes = await new Response(value).arrayBuffer();
    const httpEtag = `"${createHash("sha256").update(Buffer.from(bytes)).digest("hex")}"`;
    this.objects.set(key, { bytes, httpMetadata, httpEtag });
  }

  async get(key) {
    const entry = this.objects.get(key);
    return entry ? { ...entry, body: new Response(entry.bytes).body } : null;
  }

  async delete(key) {
    this.objects.delete(key);
  }
}

const upload = { "X-Upload-Key": "fixture-upload" };
const read = { "X-Read-Key": "fixture-read" };
const origin = "https://inbox.example.invalid";

function fixture(t) {
  const env = {
    BUCKET: new MemoryBucket(),
    UPLOAD_KEY: upload["X-Upload-Key"],
    READ_KEY: read["X-Read-Key"],
    ENROLL_CODE: "fixture-code",
    HUB_URL: "https://hub.example.invalid/notify",
    HUB_SECRET: "fixture-bearer",
  };
  const hub = t.mock.method(globalThis, "fetch", async () => {
    assert.fail("unexpected hub request");
  });
  const request = (path, init) => worker.fetch(new Request(origin + path, init), env);
  return { env, hub, request };
}

function put(body = "bytes", headers = upload, contentType) {
  return {
    method: "PUT", body: Buffer.from(body), headers: {
      ...headers,
      "Content-Length": String(Buffer.byteLength(body)),
      ...(contentType ? { "Content-Type": contentType } : {}),
    },
  };
}

const notice = JSON.stringify({ kind: "snap", session: "session-1", id: "event-01", files: ["snap-01.jpg"] });
const post = (body = notice, headers = upload) => ({ method: "POST", headers, body });

test("ping is an exact public GET route", async t => {
  const { request } = fixture(t);
  assert.deepEqual(await (await request("/ping")).json(), { ok: true });
  for (const path of ["/ping/", "/ping/extra", "//ping", "/enroll/extra"]) {
    assert.equal((await request(path)).status, 404, path);
  }
  assert.equal((await request("/ping", { method: "POST" })).status, 404);
});

test("enrolment is disabled without a code and withholds the key on wrong codes", async t => {
  t.mock.method(Date, "now", () => 100_000);
  const { env, request } = fixture(t);
  for (const code of ["", "fixture-cod", "fixture-codf", "fixture-codex"]) {
    assert.equal((await request(`/enroll?code=${code}`)).status, 403);
  }
  const response = await request(`/enroll?code=${env.ENROLL_CODE}`);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), { endpoint: origin, uploadKey: env.UPLOAD_KEY });
  delete env.ENROLL_CODE;
  assert.equal((await request("/enroll?code=fixture-code")).status, 403);
});

test("enrolment counts failed attempts and resets after its isolate window", async t => {
  let now = 200_000;
  t.mock.method(Date, "now", () => now);
  const { env, request } = fixture(t);
  for (let i = 0; i < 10; i++) assert.equal((await request("/enroll?code=bad")).status, 403);
  now += 59_000;
  const limited = await request(`/enroll?code=${env.ENROLL_CODE}`);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("retry-after"), "1");
  now += 1000;
  assert.equal((await request(`/enroll?code=${env.ENROLL_CODE}`)).status, 200);
});

test("file read and delete require the read key and retain the media type", async t => {
  const { request } = fixture(t);
  const path = "/f/session-1/snap.jpg";
  assert.equal((await request(path, { headers: read })).status, 404);
  assert.equal((await request("/u/session-1/snap.jpg", put("fixture", upload, "image/jpeg"))).status, 200);
  for (const method of ["GET", "DELETE"]) {
    assert.equal((await request(path, { method, headers: upload })).status, 403);
  }
  const response = await request(path, { headers: read });
  assert.equal(response.headers.get("content-type"), "image/jpeg");
  assert.equal(await response.text(), "fixture");
  assert.equal((await request(path, { method: "DELETE", headers: read })).status, 200);
  assert.equal((await request(path, { headers: read })).status, 404);
});

test("upload checks auth and requires a positive, bounded Content-Length", async t => {
  const { env, request } = fixture(t);
  const path = "/u/session-1/chunk.gz";
  assert.equal((await request(path, put("bytes", read))).status, 403);
  for (const length of [undefined, "0", "-1", "1.5", "1e3", "NaN", "52428801"]) {
    const headers = { ...upload };
    if (length !== undefined) headers["Content-Length"] = length;
    assert.equal((await request(path, { method: "PUT", headers, body: Uint8Array.of(0) })).status, 413, length);
  }
  assert.equal(env.BUCKET.objects.size, 0);
  const max = 50 * 1024 * 1024;
  const response = await request(path, { method: "PUT", headers: { ...upload, "Content-Length": String(max) }, body: new Uint8Array(max) });
  assert.equal(response.status, 200);
  assert.equal(env.BUCKET.objects.get("session-1/chunk.gz").bytes.byteLength, max);
});

test("upload accepts the media type allowlist and rejects everything else", async t => {
  const { env, request } = fixture(t);
  const path = "/u/session-1/chunk";
  for (const type of ["image/jpeg", "image/png", "audio/wav", "audio/x-wav", "application/gzip",
    "application/x-gzip", "application/jsonl", "application/x-ndjson", "application/json",
    "application/octet-stream", "Application/JSON; charset=utf-8"]) {
    assert.equal((await request(path, put("bytes", upload, type))).status, 200, type);
  }
  assert.equal((await request(path, { method: "PUT", headers: { ...upload, "Content-Length": "1" }, body: Uint8Array.of(0) })).status, 200);
  for (const type of ["text/html", "text/plain", "image/svg+xml", "application/xml"]) {
    assert.equal((await request(path, put("bad", upload, type))).status, 415, type);
  }
  const entry = env.BUCKET.objects.get("session-1/chunk");
  assert.equal(entry.httpMetadata.contentType, "application/octet-stream");
  assert.deepEqual(new Uint8Array(entry.bytes), Uint8Array.of(0));
});

test("object routes require exactly two unescaped name segments", async t => {
  const { request } = fixture(t);
  for (const key of ["session", "session//file", "/session/file", "session/file/", "session/f/ile",
    ".session/file", "session/%2F", "session/file%0A", "session/" + "x".repeat(122)]) {
    assert.equal((await request(`/u/${key}`, put())).status, 400, key);
    assert.equal((await request(`/f/${key}`, { headers: read })).status, 400, key);
    assert.equal((await request(`/f/${key}`, { method: "DELETE", headers: read })).status, 400, key);
  }
  assert.equal((await request(`/u/A_1-2.3/${"x".repeat(121)}`, put())).status, 200);
});

test("only read-key PUT can write tuning; the reservation also covers /done", async t => {
  const { env, hub, request } = fixture(t);
  const path = "/f/tuning/player-1.json";
  const tuning = '{"strength":2}';
  assert.equal((await request("/u/tuning/player-1.json", put(tuning, upload, "application/json"))).status, 403);
  assert.equal((await request("/done", post(notice.replace("session-1", "tuning")))).status, 403);
  assert.equal((await request(path, put(tuning, upload, "application/json"))).status, 403);
  assert.equal((await request("/f/session-1/player-1.json", put(tuning, read, "application/json"))).status, 400);
  assert.equal((await request("/f/tuning/player-1.txt", put(tuning, read, "application/json"))).status, 400);
  assert.equal((await request(path, put(tuning, read, "text/plain"))).status, 415);
  assert.equal((await request(path, put("{", read, "application/json"))).status, 400);
  assert.equal((await request(path, put(JSON.stringify("x".repeat(200 * 1024)), read, "application/json"))).status, 413);
  assert.equal(env.BUCKET.objects.size, 0);
  assert.equal(hub.mock.callCount(), 0);
  assert.equal((await request(path, put(tuning, read, "application/json"))).status, 200);
  assert.equal(await (await request(path, { headers: read })).text(), tuning);
});

test("tuning needs upload auth, reports missing files and supports conditional reads", async t => {
  const { request } = fixture(t);
  const path = "/t/player-1";
  const writePath = "/f/tuning/player-1.json";
  assert.equal((await request(path, { headers: read })).status, 403);
  assert.equal((await request(`${path}/extra`, { headers: upload })).status, 400);
  assert.equal((await request(path, { headers: upload })).status, 404);
  const write = body => request(writePath, put(body, read, "application/json"));
  await write('{"value":1}');
  const first = await request(path, { headers: upload });
  assert.equal(first.status, 200);
  assert.equal(first.headers.get("content-type"), "application/json");
  assert.deepEqual(await first.json(), { value: 1 });
  const etag = first.headers.get("etag");
  assert.match(etag, /^"[a-f0-9]+"$/);
  for (const tag of [etag, `"old", W/${etag}`, "*"]) {
    const same = await request(path, { headers: { ...upload, "If-None-Match": tag } });
    assert.equal(same.status, 304);
    assert.equal(same.headers.get("etag"), etag);
    assert.equal(await same.text(), "");
  }
  await write('{"value":2}');
  const changed = await request(path, { headers: { ...upload, "If-None-Match": etag } });
  assert.notEqual(changed.headers.get("etag"), etag);
  assert.deepEqual(await changed.json(), { value: 2 });
});

test("done stores the exact JSON before forwarding and reuses a supplied id", async t => {
  const { env, hub, request } = fixture(t);
  hub.mock.mockImplementation(async (url, init) => {
    assert.equal(url, env.HUB_URL);
    assert.equal(init.method, "POST");
    assert.equal(init.redirect, "manual");
    assert.equal(init.headers.authorization, `Bearer ${env.HUB_SECRET}`);
    assert.equal(init.headers["idempotency-key"], "event-01");
    assert.equal(init.body, notice);
    const saved = await env.BUCKET.get("session-1/done-event-01.json");
    assert.equal(saved.httpMetadata.contentType, "application/json");
    assert.equal(await new Response(saved.body).text(), notice);
    return new Response(null, { status: 204 });
  });
  for (let i = 0; i < 2; i++) {
    const response = await request("/done", post());
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true, hub: 204 });
  }
  assert.equal(env.BUCKET.objects.size, 1);
  assert.equal(hub.mock.callCount(), 2);
});

test("done generates an id when omitted and accepts a 200 KiB JSON body", async t => {
  const { env, hub, request } = fixture(t);
  const base = '{"kind":"session","session":"session-1","context":""}';
  const limit = 200 * 1024;
  const body = base.slice(0, -2) + "z".repeat(limit - base.length) + base.slice(-2);
  assert.equal(Buffer.byteLength(body), limit);
  hub.mock.mockImplementation(async (_url, init) => {
    const id = init.headers["idempotency-key"];
    assert.match(id, /^[a-f0-9-]{36}$/);
    assert.ok(env.BUCKET.objects.has(`session-1/done-${id}.json`));
    return new Response("ok");
  });
  assert.equal((await request("/done", post(body))).status, 200);
});

test("done keeps the stored copy on redirect, HTTP error or transport failure", async t => {
  const { env, hub, request } = fixture(t);
  hub.mock.mockImplementation(async (_url, init) => {
    assert.equal(init.redirect, "manual");
    return Response.redirect("https://redirect.example.invalid", 307);
  });
  const redirected = await request("/done", post());
  assert.equal(redirected.status, 502);
  assert.deepEqual(await redirected.json(), { ok: false, hub: 307 });
  hub.mock.mockImplementation(async () => new Response("failure", { status: 503 }));
  assert.equal((await request("/done", post())).status, 502);
  hub.mock.mockImplementation(async () => { throw new TypeError("network failure"); });
  assert.equal((await request("/done", post())).status, 502);
  assert.equal(hub.mock.callCount(), 3);
  delete env.HUB_SECRET;
  assert.equal((await request("/done", post())).status, 502);
  assert.equal(hub.mock.callCount(), 3);
  const saved = await env.BUCKET.get("session-1/done-event-01.json");
  assert.equal(await new Response(saved.body).text(), notice);
});

test("done rejects unauthorized, malformed and oversized requests without side effects", async t => {
  const { env, hub, request } = fixture(t);
  assert.equal((await request("/done", post(notice, read))).status, 403);
  for (const body of ["{", "null", '{"kind":"snap","session":"bad/key"}',
    '{"kind":"other","session":"valid"}', '{"kind":"snap","session":"valid","id":"bad/id"}']) {
    assert.equal((await request("/done", post(body))).status, 400, body);
  }
  const large = JSON.stringify({ kind: "snap", session: "session-1", context: "é".repeat(110 * 1024) });
  assert.equal((await request("/done", post(large))).status, 413);
  assert.equal((await request("/done", post(large, { ...upload, "Content-Length": "1" }))).status, 413);
  assert.equal((await request("/done", post(notice, { ...upload, "Content-Length": String(200 * 1024 + 1) }))).status, 413);
  assert.equal(env.BUCKET.objects.size, 0);
  assert.equal(hub.mock.callCount(), 0);
});
