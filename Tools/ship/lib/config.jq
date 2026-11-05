# Emit the first invalid/missing key, rather than a jq type error.
def nonempty: if type == "string" then length > 0 and (test("[\u0000-\u001f]") | not) else false end;
def relpath:
  if nonempty then (startswith("/") | not) and
    (split("/") | all(. != "..")) and . != "."
  else false end;
def strings: if type == "array" then all(.[]; nonempty) else false end;
def methods: if strings then length > 0 else false end;
def invalid($key): "missing or invalid key: \($key)";
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
