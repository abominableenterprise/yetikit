# VrApi emits one sample per second. Parse comma-delimited named fields, not positions.
def number($s):
  (try ($s | capture("^(?<n>[0-9]+(?:\\.[0-9]+)?)(?:ms|C|/|$)").n | tonumber) catch null) // null;
def mean: if length > 0 then add / length else "unavailable" end;
def p95: if length > 0 then sort | .[((length * 0.95 | ceil) - 1)] else "unavailable" end;
def complete($rows; $key):
  ($rows | length) > 0 and all($rows[]; .[$key] != null);
def gate($value; $limit):
  {value: $value, limit: $limit,
   verdict: (if ($value | type) != "number" then (if $mode == "gate" then "FAIL" else "unavailable" end)
             elif $value <= $limit then "PASS" else "FAIL" end)};
[split("\n")[] | select(test("\\bVrApi\\s*:")) |
  # Validate the emitting PID even if an adb implementation ignores --pid.
  select($pid != "" and test("^\\s*[0-9]+\\.[0-9]+\\s+" + $pid + "\\s+")) |
  . as $line |
  (sub("^.*?\\bVrApi\\s*:\\s*"; "") | split(",") |
    map(try capture("^\\s*(?<key>[^=]+)=(?<value>.*?)\\s*$") catch empty) |
    map({key: (.key | gsub("^\\s+|\\s+$"; "")), value}) | from_entries) as $f |
  select($f | has("FPS") or has("Stale") or has("App")) |
  {fps: number($f.FPS), stale: number($f.Stale), app: number($f.App),
   cpu: number($f.CPU), gpu: number($f.GPU),
   time: ((try ($line | capture("^\\s*(?<t>[0-9]+\\.[0-9]+)\\s").t | tonumber) catch null) // null),
   levels: ($f | to_entries | map(select(.key | test("^CPU[0-9]*/GPU$"))) | .[0].value // "unavailable"),
   temp: ($f.Temp // "unavailable")}] as $rows |
($rows | length) as $n |
# Allow one boundary sample of jitter, never a short surviving fragment or gap.
([$rows[].time] | sort) as $times |
($n >= ([$seconds - 1, 1] | max) and complete($rows; "time") and
 ($times[-1] - $times[0]) >= ([$seconds - 2, 0] | max) and
 all(range(1; $n); ($times[.] - $times[. - 1]) > 0 and ($times[.] - $times[. - 1]) <= 2.5)) as $covered |
(if complete($rows; "fps") and complete($rows; "stale") and ([$rows[].fps] | add) > 0
 then ([$rows[].stale] | add) / ([$rows[].fps] | add) * 100 else "unavailable" end) as $stale |
(if complete($rows; "app") then [$rows[].app] | p95 else "unavailable" end) as $app |
{model: $model, mode: $mode, seconds: $seconds, warmupSeconds: $warmup,
 scene: $scene, apkSha256: $sha, versionName: $versionName, versionCode: $versionCode,
 samples: $n, levels: ($rows[0].levels // "unavailable"),
 thermalStart: (if ($rows[0].temp // "unavailable") == "unavailable" then $thermalStart else $rows[0].temp end),
 thermalEnd: (if ($rows[-1].temp // "unavailable") == "unavailable" then $thermalEnd else $rows[-1].temp end),
 averageFps: (if complete($rows; "fps") then [$rows[].fps] | mean else "unavailable" end),
 worstAppMs: (if complete($rows; "app") then [$rows[].app] | max else "unavailable" end),
 cpuMs: (if complete($rows; "cpu") then [$rows[].cpu] | mean else "unavailable" end),
 gpuMs: (if complete($rows; "gpu") then [$rows[].gpu] | mean else "unavailable" end),
 longestStaleStreak: (if complete($rows; "stale") then
   reduce $rows[] as $r ({best: 0, streak: 0, time: null};
     .streak = (if $r.stale > 0 then
       (if .time != null and $r.time != null and ($r.time - .time) > 1.5 then 1 else .streak + 1 end)
       else 0 end) | .time = $r.time | .best = ([.best, .streak] | max)) | .best
   else "unavailable" end),
 stalePercent: $stale, p95AppMs: $app,
 gates: {stale: gate($stale; $maxStale), app: gate($app; $maxApp)},
 message: (if $error != "" then $error elif $n == 0 then "no target-process VrApi samples: performance data unavailable"
           elif ($covered | not) then "incomplete VrApi capture coverage: expected once-per-second telemetry for the full window" else "" end)} |
.overall = (if .message != "" then "INFRA" elif $mode == "report" then "REPORT"
            elif .gates.stale.verdict == "PASS" and .gates.app.verdict == "PASS" then "PASS" else "FAIL" end)
