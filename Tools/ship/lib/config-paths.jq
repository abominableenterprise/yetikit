# Canonical project-relative spellings for Git comparisons and path construction.
# Validation rejects '..' components; Quest also permits an absolute flakes list.
def canonical: split("/") | map(select(. != "" and . != ".")) | join("/") | if . == "" then "." else . end;
reduce (["build", "apkPath"], ["build", "releaseApkPath"], ["build", "profile"],
        ["knownFlakes"], ["scene", "lightmapDir"], ["scene", "areasDir"], ["scene", "areasFile"],
        ["tests", "root"], ["tests", "editModeRoot"], ["tests", "scriptsRoot"], ["tests", "editorRoot"],
        ["noise", "atlasPath"], ["noise", "timeManagerPath"], ["noise", "specularMaterialPath"], ["noise", "propsDir"]) as $p
  (.; if getpath($p) == null then .
       elif $p == ["knownFlakes"] and (getpath($p) | startswith("/")) then .
       else setpath($p; getpath($p) | canonical) end)
| if .scene.keepPaths? then .scene.keepPaths |= map(canonical) else . end
