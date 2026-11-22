# Playtest inbox Worker

A dependency-free Worker that stores development playtest files in a private R2
bucket and notifies a bot's webhook when a session or snapshot is ready. Copy
this directory, replace the worker name, bucket name and HTTPS `HUB_URL` in
`wrangler.toml`, and bind the private bucket as `BUCKET`. Use a separate bucket
per deployment. Configure these as Worker secrets, not as configuration values:

- `UPLOAD_KEY`: shared by enrolled development clients.
- `READ_KEY`: separate bot-only key; can read and delete files and write tuning.
- `HUB_SECRET`: bearer token for the configured webhook.
- `ENROLL_CODE`: temporary random code; leave unset except during enrolment.

## Routes

| Request | Auth | Behaviour |
| --- | --- | --- |
| `GET /ping` | None | Health check. |
| `GET /enroll?code=…` | `ENROLL_CODE` | Returns `{endpoint, uploadKey}` with `Cache-Control: no-store`. A missing or wrong code returns 403. After 10 attempts (successful or not) per isolate per 60-second window, returns 429 with `Retry-After`. |
| `PUT /u/<a>/<b>` | `X-Upload-Key` | Stores `<a>/<b>`. Requires a positive `Content-Length` up to 50 MiB. The `tuning` prefix is reserved. |
| `POST /done` | `X-Upload-Key` | Accepts JSON up to 200 KiB. Stores `<session>/done-<id>.json` before notifying the webhook. |
| `GET /t/<player>` | `X-Upload-Key` | Reads `tuning/<player>.json`. Returns an `ETag`, 304 if `If-None-Match` matches, or 404 if missing. |
| `GET /f/<a>/<b>` | `X-Read-Key` | Reads an object with its recorded media type, or returns 404. |
| `DELETE /f/<a>/<b>` | `X-Read-Key` | Deletes an object; succeeds even if already absent. |
| `PUT /f/tuning/<player>.json` | `X-Read-Key` | Writes tuning JSON (up to 200 KiB, `Content-Type: application/json`). This is the only write route for `tuning/`. |

Object paths have exactly two name segments, no nesting. Names match
`^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$`. For tuning, include the `.json` suffix
when counting the stored filename's length.

Allowed upload media types: `image/jpeg`, `image/png`, `audio/wav`,
`audio/x-wav`, `application/gzip`, `application/x-gzip`, `application/jsonl`,
`application/x-ndjson`, `application/json`, and `application/octet-stream`
(the default if omitted). Media types are normalized, ignoring parameters.
The allowlist checks the declared type, not the file contents.

For `/done`, send `kind` (`session` or `snap`), `session` (a valid name other
than `tuning`), and any metadata the bot consumes, such as `player`, `build`,
`files`, or `context`. Supply a stable `id` for retryable requests: it must be
valid as a name and fit within the 121-character limit after adding
`done-` and `.json`. Otherwise, the Worker generates an ID per request. It
forwards the JSON with `Authorization: Bearer` using `HUB_SECRET` and an
`Idempotency-Key` set to that ID. Use globally unique IDs for distinct events
and have the webhook deduplicate by ID. On a non-success response or a
forwarding error, the Worker returns 502 and keeps the copy in R2.

## Bucket layout

```text
<session>/
  meta.json                 session metadata
  chunk-0001.jsonl.gz       compressed event stream
  snap-01.jpg               snapshot image
  snap-01.wav               optional audio note
  snap-01.json              snapshot context
  done-<id>.json            stored notification payload
tuning/<player>.json       live tuning (top-level prefix)
```

For example, use `session-` as the prefix of every session name. To expire old
sessions, configure this example R2 lifecycle rule in the bucket settings:

| Rule name | Object key prefix | Action |
| --- | --- | --- |
| `expire-old-sessions` | `session-` | Delete objects 30 days after upload |

This expires session files and `/done` copies without expiring `tuning/`.
Choose the retention period to suit your playtest data policy. Bucket lifecycle
rules are configured on the bucket, not in the Worker configuration.

## Enrol a device

1. Set a high-entropy temporary code using `wrangler secret put ENROLL_CODE`.
2. Save the same code in a private file outside the checkout on the host
   attached to the headset (`chmod 600`). Set `quest.package` in the consumer's
   `yetikit.json` to the installed development app's Android application ID.
3. From the consumer project, run the [Ship enrolment helper](../../Tools/ship/README.md#enroll-a-headset-for-playtesting):

   ```sh
   Tools/yetikit/playtest-enroll.sh --endpoint https://worker.example.invalid --code "$HOME/private/enroll-code" --player test-headset
   ```

   The helper exchanges the code over HTTPS and pushes the returned settings
   to `/sdcard/Android/data/<applicationId>/files/playtest/playtest.json`.
   Add `--launch` to verify the development app's recorder startup in logcat.
4. Run `wrangler secret delete ENROLL_CODE` manually and remove the private code
   file, even if enrolment failed. The code is reusable until removed, not single-use.

Never put an upload key in an APK or repository. Do not print the key or code;
keep the enrolment URL and response out of shell history and request logs.

## Hardening

- The enrolment counter is in memory and shared by callers to one Worker
  isolate. Restarts reset it, different isolates do not share it, and anyone
  can use up that isolate's allowance. For stronger protection, add a durable
  or edge rate limit and restrict access during the enrolment window.
- Consider per-device upload keys so one device can be revoked without
  re-enrolling the rest. Alternatively, use short-lived HMAC-scoped keys and
  bind the scope to a player and the permitted session prefixes and routes.

## Offline tests

Run `node --test` from this directory with Node 22 or later. The tests use an
in-memory bucket and stubbed webhook; no account, dependencies, network, or
deployment is needed.
