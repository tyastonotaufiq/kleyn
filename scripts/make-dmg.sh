#!/bin/zsh
# Builds Kleyn's installer DMG with the custom window layout.
#
#   scripts/make-dmg.sh path/to/Kleyn.app [output.dmg]
#
# The output defaults to Kleyn-<version>.dmg next to the app, using the app's
# CFBundleShortVersionString. The DMG is not signed; sign and notarize it afterwards.
#
# One-time setup, from the repository root:
#   python3 -m venv .venv && .venv/bin/pip install dmgbuild

set -euo pipefail

repo=${0:A:h:h}
dmgbuild=$repo/.venv/bin/dmgbuild

if (( $# < 1 || $# > 2 )); then
    print -u2 "usage: $0 path/to/Kleyn.app [output.dmg]"
    exit 64
fi

app=${1:A}
if [[ ! -d $app/Contents ]]; then
    print -u2 "error: $1 is not an app bundle"
    exit 66
fi

if [[ ! -x $dmgbuild ]]; then
    print -u2 "error: dmgbuild isn't installed. From $repo, run:"
    print -u2 "  python3 -m venv .venv && .venv/bin/pip install dmgbuild"
    exit 69
fi

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
output=${2:-${app:h}/Kleyn-$version.dmg}

"$dmgbuild" \
    -s "$repo/scripts/dmg-settings.py" \
    -D app="$app" \
    -D background="$repo/Design/DMG/background.tiff" \
    "Kleyn" "$output"

print "Built $output"
