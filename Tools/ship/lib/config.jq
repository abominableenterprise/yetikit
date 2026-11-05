# Emit the first invalid/missing key, rather than a jq type error.
def nonempty: if type == "string" then length > 0 and (test("[\u0000-\u001f]") | not) else false end;
def relpath:
  if nonempty then (startswith("/") | not) and
    (split("/") | all(. != "..")) and . != "."
  else false end;
def strings: if type == "array" then all(.[]; nonempty) else false end;
def methods: if strings then length > 0 else false end;
def invalid($key): "missing or invalid key: \($key)";
def envname: if nonempty then test("^[A-Za-z_][A-Za-z0-9_]*$") else false end;
def packageid: if nonempty then test("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$") else false end;
# Backup destinations must also be distinct on default case-insensitive macOS volumes.
def basenames:
  if strings then
    all(.[]; test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$") and . != ".." and (ascii_downcase != "sha256sums")) and
    (map(ascii_downcase) | length == (unique | length))
  else false end;
if length != 1 then invalid("schema (expected one JSON object)")
else .[0] |
if type != "object" then invalid("schema")
elif .schema != 1 then invalid("schema (expected 1)")
elif (.unityVersion | nonempty | not) then invalid("unityVersion")
elif (.build | type) != "object" then invalid("build")
elif (.build | has("profile")) and (.build.profile | relpath | not) then invalid("build.profile")
elif (.build | has("profile") | not) and (.build.devMethod | nonempty | not) then invalid("build.devMethod")
elif (.build | has("profile") | not) and (.build.releaseMethod | nonempty | not) then invalid("build.releaseMethod")
elif (.build | has("cli")) and (.build.cli | nonempty | not) then invalid("build.cli")
elif (.build.apkPath | relpath | not) then invalid("build.apkPath")
elif has("knownFlakes") and (.knownFlakes | relpath | not) then invalid("knownFlakes")
elif (.build | has("releaseApkPath")) and (.build.releaseApkPath | relpath | not) then invalid("build.releaseApkPath")
elif has("quest") and (.quest | type) != "object" then invalid("quest")
elif has("quest") and (.quest | has("serial")) then invalid("quest.serial (use QUEST_SERIAL environment only)")
elif has("quest") and (.quest.package | packageid | not) then invalid("quest.package")
elif has("quest") and (.build.devMethod | nonempty | not) then invalid("build.devMethod (required for Quest builds)")
elif has("quest") and (.quest | has("worktreeRoot")) and (.quest.worktreeRoot | nonempty | not) then invalid("quest.worktreeRoot")
elif has("quest") and (.quest | has("apkKeepName")) and
  (.quest.apkKeepName | if nonempty then test("^[A-Za-z0-9_.{}-]+\\.apk$") and contains("{sha}") else false end | not) then invalid("quest.apkKeepName")
elif has("quest") and (.quest | has("perfLogTag")) and (.quest.perfLogTag | nonempty | not) then invalid("quest.perfLogTag")
elif has("quest") and (.quest | has("whatsNewEnv")) and (.quest.whatsNewEnv | envname | not) then invalid("quest.whatsNewEnv")
elif has("quest") and (.quest | has("prevShaEnv")) and (.quest.prevShaEnv | envname | not) then invalid("quest.prevShaEnv")
elif has("quest") and (.quest | has("dataFiles")) and (.quest.dataFiles | basenames | not) then invalid("quest.dataFiles")
elif has("quest") and (.quest | has("launchArgs")) and (.quest.launchArgs | strings | not) then invalid("quest.launchArgs")
elif has("quest") and (.quest | has("launcherChecks")) and (.quest.launcherChecks | type) != "object" then invalid("quest.launcherChecks")
elif has("quest") and (.quest.launcherChecks // {} | has("package")) and (.quest.launcherChecks.package != .quest.package) then invalid("quest.launcherChecks.package (must match quest.package)")
elif has("quest") and (.quest.launcherChecks // {} | has("permissions")) and (.quest.launcherChecks.permissions | strings | not) then invalid("quest.launcherChecks.permissions")
elif has("quest") and (.quest.launcherChecks // {} | has("assets")) and
  (.quest.launcherChecks.assets | if type == "array" then all(.[]; relpath) else false end | not) then invalid("quest.launcherChecks.assets")
elif has("setup") and (.setup | type) != "object" then invalid("setup")
elif has("setup") and (.setup | has("craneArchive")) and (.setup.craneArchive | nonempty | not) then invalid("setup.craneArchive")
elif has("labMethod") and (.labMethod | nonempty | not) then invalid("labMethod")
elif has("scene") and (.scene | type) != "object" then invalid("scene")
elif has("scene") and (.scene.steps | methods | not) then invalid("scene.steps")
elif has("scene") and (.scene.lightmapDir | relpath | not) then invalid("scene.lightmapDir")
elif has("scene") and (.scene | has("keepPaths")) and (.scene.keepPaths | type) != "array" then invalid("scene.keepPaths")
elif has("scene") and (.scene | has("keepPaths")) and (.scene.keepPaths | all(.[]; relpath) | not) then invalid("scene.keepPaths")
elif has("scene") and (.scene | has("areaStep")) and (.scene.areaStep | nonempty | not) then invalid("scene.areaStep")
elif has("scene") and (.scene | has("areaStep")) and (.scene.areasDir | relpath | not) then invalid("scene.areasDir")
elif has("scene") and (.scene | has("areaSteps")) and (.scene.areaSteps | methods | not) then invalid("scene.areaSteps")
elif has("scene") and (.scene | has("areasFile")) and (.scene.areasFile | relpath | not) then invalid("scene.areasFile")
elif has("scene") and (.scene | has("areasDir")) and (.scene.areasDir | relpath | not) then invalid("scene.areasDir")
elif has("noise") and (.noise | type) != "object" then invalid("noise")
elif has("noise") and ([.noise | to_entries[] | select(.value | nonempty | not) | .key] | length) > 0 then
  invalid("noise." + ([.noise | to_entries[] | select(.value | nonempty | not) | .key][0]))
elif has("noise") and (.noise | has("fixedTimestepCount")) and (.noise.fixedTimestepCount | test("^[1-9][0-9]*$") | not) then invalid("noise.fixedTimestepCount")
elif has("noise") and ([.noise | to_entries[] | select(.key == "atlasPath" or .key == "timeManagerPath" or .key == "specularMaterialPath" or .key == "propsDir") | select(.value | relpath | not) | .key] | length) > 0 then
  invalid("noise." + ([.noise | to_entries[] | select(.key == "atlasPath" or .key == "timeManagerPath" or .key == "specularMaterialPath" or .key == "propsDir") | select(.value | relpath | not) | .key][0]))
elif has("tests") and (.tests | type) != "object" then invalid("tests")
elif has("tests") and (.tests | has("builderFixtures")) and (.tests.builderFixtures | type) != "object" then invalid("tests.builderFixtures")
elif has("tests") and (.tests | has("builderFixtures")) and (.tests.builderFixtures | all(.[]; methods) | not) then invalid("tests.builderFixtures")
else empty end
end
