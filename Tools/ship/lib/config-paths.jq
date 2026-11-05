# Canonical project-relative spellings for Git comparisons and path construction.
# Validation already rejects absolute paths and '..' components.
def canonical: split("/") | map(select(. != "" and . != ".")) | join("/") | if . == "" then "." else . end;
reduce (["build", "apkPath"], ["build", "releaseApkPath"], ["build", "profile"],
        ["knownFlakes"], ["scene", "lightmapDir"], ["scene", "areasDir"], ["scene", "areasFile"],
        ["noise", "atlasPath"], ["noise", "timeManagerPath"], ["noise", "specularMaterialPath"], ["noise", "propsDir"]) as $p
  (.; if getpath($p) == null then . else setpath($p; getpath($p) | canonical) end)
| if .scene.keepPaths? then .scene.keepPaths |= map(canonical) else . end
