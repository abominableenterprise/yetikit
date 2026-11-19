#!/usr/bin/env bash
# Close the Host editor before staging. See Host/README.md for local ignore and cleanup paths.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd -- "$here/../.."
assets=Host/Assets
check_only=false
if [[ $# == 1 && $1 == --check-only ]]; then
    check_only=true
elif [[ $# != 0 ]]; then
    printf 'Usage: %s [--check-only]\n' "${0##*/}" >&2
    exit 2
fi
if ! $check_only; then
    for name in Starter StarterTests; do
        for path in "$assets/$name" "$assets/$name.meta"; do
            if [[ -e $path || -L $path ]]; then
                printf 'Refusing to overwrite %s; see Host/README.md for cleanup.\n' "$path" >&2
                exit 1
            fi
        done
    done
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fixture() {
    python3 templates/game/new-game.py --id "$1" --title "$2" --out "$tmp/$3"
}
reject_identity() {
    local option=$1 id=$2 title=$3
    if fixture "$id" "$title" invalid > "$tmp/rejected.log" 2>&1 ||
        ! grep -qF -- "error: $option" "$tmp/rejected.log" || [[ -e "$tmp/invalid" ]]; then
        printf 'Expected generator to reject %s before creating an output directory.\n' "$option" >&2
        exit 1
    fi
}
fixture org.examplechecks.sandbox 'Neutral Fixture' first
fixture org.examplechecks.sandbox 'Neutral Fixture' second
reject_identity --id 'not a valid id' 'Neutral Fixture'
reject_identity --id com.example.placeholder 'Neutral Fixture'
reject_identity --title org.examplechecks.sandbox 'Untitled Game'
mkdir -- "$tmp/occupied"
touch -- "$tmp/occupied/keep"
if fixture org.examplechecks.sandbox 'Neutral Fixture' occupied > "$tmp/rejected.log" 2>&1 ||
    [[ ! -f "$tmp/occupied/keep" || -e "$tmp/occupied/Assets" ]]; then
    printf 'Expected generator to reject an occupied output without changing it.\n' >&2
    exit 1
fi

python3 -B "$here/check-guids.py" "$tmp/first/Assets" "$tmp/second/Assets"
if $check_only; then exit 0; fi

# Preserve the generator's GUIDs and their references; do not regenerate metas here.
cp -R -- "$tmp/first/Assets/Starter" "$assets/Starter"
cp -- "$tmp/first/Assets/Starter.meta" "$assets/Starter.meta"
cp -R -- "$here/EditMode" "$assets/StarterTests"
cp -- "$here/EditMode.meta" "$assets/StarterTests.meta"
printf 'Staged generated Starter and its Host tests.\n'
