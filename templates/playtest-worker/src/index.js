const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/;
const MAX_FILE = 50 * 1024 * 1024;
const MAX_JSON = 200 * 1024;
const ENROLL_LIMIT = 10;
const ENROLL_WINDOW_MS = 60_000;
const UPLOAD_TYPES = new Set([
  "image/jpeg", "image/png", "audio/wav", "audio/x-wav",
  "application/gzip", "application/x-gzip", "application/jsonl",
  "application/x-ndjson", "application/json", "application/octet-stream",
]);
const JSON_METADATA = { httpMetadata: { contentType: "application/json" } };

let enrollReset = 0;
let enrollAttempts = 0;

function same(provided, secret) {
  if (typeof secret !== "string" || !secret || typeof provided !== "string") return false;
  let diff = provided.length ^ secret.length;
  // Compare every code unit of the configured secret; never exit on a mismatch.
  for (let i = 0; i < secret.length; i++) diff |= provided.charCodeAt(i) ^ secret.charCodeAt(i);
  return diff === 0;
}

function json(value, status = 200, headers = {}) {
  return Response.json(value, { status, headers: { "cache-control": "no-store", ...headers } });
}

const error = (message, status) => json({ error: message }, status);
const validName = value => typeof value === "string" && NAME.test(value);
const validPair = parts => parts.length === 2 && parts.every(validName);
const mediaType = req => req.headers.get("content-type")?.split(";", 1)[0].trim().toLowerCase()
  ?? "application/octet-stream";

function enroll(url, env) {
  const now = Date.now();
  if (now >= enrollReset) {
    enrollReset = now + ENROLL_WINDOW_MS;
    enrollAttempts = 0;
  }
  if (enrollAttempts >= ENROLL_LIMIT) {
    return json({ error: "rate limit" }, 429, { "retry-after": String(Math.ceil((enrollReset - now) / 1000)) });
  }
  enrollAttempts++;
  if (!env.UPLOAD_KEY || !same(url.searchParams.get("code"), env.ENROLL_CODE)) return error("forbidden", 403);
  return json({ endpoint: url.origin, uploadKey: env.UPLOAD_KEY });
}

async function readJson(req) {
  if (Number(req.headers.get("content-length")) > MAX_JSON) return { failure: error("size", 413) };
  if (!req.body) return { failure: error("json", 400) };
  const reader = req.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let size = 0;
  let text = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_JSON) return { failure: error("size", 413) };
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return { text, body: JSON.parse(text) };
  } catch {
    return { failure: error("json", 400) };
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

async function done(req, env) {
  const { text, body, failure } = await readJson(req);
  if (failure) return failure;
  if (!validName(body?.session) || !["session", "snap"].includes(body.kind)) return error("fields", 400);
  if (body.session === "tuning") return error("reserved prefix", 403);
  const id = body.id ?? crypto.randomUUID();
  if (!validName(id)) return error("id", 400);
  const filename = `done-${id}.json`;
  if (!validName(filename)) return error("id", 400);

  await env.BUCKET.put(`${body.session}/${filename}`, text, JSON_METADATA);
  if (!env.HUB_URL || !env.HUB_SECRET) return error("hub unavailable", 502);
  try {
    const result = await fetch(env.HUB_URL, {
      method: "POST",
      headers: { authorization: `Bearer ${env.HUB_SECRET}`, "content-type": "application/json", "idempotency-key": id },
      body: text,
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
    });
    if (result.body) await result.body.cancel().catch(() => {});
    return json({ ok: result.ok, hub: result.status }, result.ok ? 200 : 502);
  } catch {
    return error("hub unavailable", 502);
  }
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const [, route, ...parts] = url.pathname.split("/");
    const method = req.method;

    if (route === "ping" && method === "GET" && !parts.length) return json({ ok: true });
    if (route === "enroll" && method === "GET" && !parts.length) return enroll(url, env);

    if (route === "f" && ["GET", "DELETE", "PUT"].includes(method)) {
      if (!same(req.headers.get("x-read-key"), env.READ_KEY)) return error("forbidden", 403);
      if (!validPair(parts)) return error("bad key", 400);
      const key = parts.join("/");
      if (method === "DELETE") {
        await env.BUCKET.delete(key);
        return json({ ok: true });
      }
      if (method === "PUT") {
        if (parts[0] !== "tuning" || !parts[1].endsWith(".json") || !validName(parts[1].slice(0, -5))) {
          return error("bad tuning key", 400);
        }
        if (mediaType(req) !== "application/json") return error("content type", 415);
        const { text, failure } = await readJson(req);
        if (failure) return failure;
        await env.BUCKET.put(key, text, JSON_METADATA);
        return json({ ok: true, key });
      }
      const obj = await env.BUCKET.get(key);
      if (!obj) return error("not found", 404);
      return new Response(obj.body, { headers: {
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
        "content-type": obj.httpMetadata?.contentType || "application/octet-stream",
      } });
    }

    if (route === "t" && method === "GET") {
      if (!same(req.headers.get("x-upload-key"), env.UPLOAD_KEY)) return error("forbidden", 403);
      if (parts.length !== 1 || !validName(parts[0]) || !validName(`${parts[0]}.json`)) return error("bad key", 400);
      const obj = await env.BUCKET.get(`tuning/${parts[0]}.json`);
      if (!obj) return error("not found", 404);
      const etag = obj.httpEtag;
      const headers = { etag, "cache-control": "no-store" };
      const tags = req.headers.get("if-none-match")?.split(",").map(tag => tag.trim().replace(/^W\//, ""));
      if (tags?.includes(etag) || tags?.includes("*")) {
        await obj.body.cancel();
        return new Response(null, { status: 304, headers });
      }
      return new Response(obj.body, { headers: { ...headers, "content-type": "application/json" } });
    }

    if (route === "u" && method === "PUT") {
      if (!same(req.headers.get("x-upload-key"), env.UPLOAD_KEY)) return error("forbidden", 403);
      if (!validPair(parts)) return error("bad key", 400);
      if (parts[0] === "tuning") return error("reserved prefix", 403);
      const length = req.headers.get("content-length");
      if (!length || !/^\d+$/.test(length) || Number(length) < 1 || Number(length) > MAX_FILE || !req.body) {
        return error("size", 413);
      }
      const contentType = mediaType(req);
      if (!UPLOAD_TYPES.has(contentType)) return error("content type", 415);
      const key = parts.join("/");
      await env.BUCKET.put(key, req.body, { httpMetadata: { contentType } });
      return json({ ok: true, key });
    }

    if (route === "done" && method === "POST" && !parts.length) {
      if (!same(req.headers.get("x-upload-key"), env.UPLOAD_KEY)) return error("forbidden", 403);
      return done(req, env);
    }

    return error("not found", 404);
  },
};
