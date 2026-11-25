#!/bin/bash
# Build the public FLOW project. Installation is optional and preserves the old bundle.
set -euo pipefail

case "${1:-}" in
    "") install=false ;;
    --install) install=true ;;
    *) printf 'Usage: %s [--install]\n' "$0" >&2; exit 2 ;;
esac
if (( $# > 1 )); then
    printf 'Usage: %s [--install]\n' "$0" >&2
    exit 2
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if ! command -v xcodegen >/dev/null; then
    printf 'Install XcodeGen before building the FLOW app bundle. See README.md.\n' >&2
    exit 1
fi

derived="$project_dir/.build/xcode"
xcodegen generate
xcodebuild -project Flow.xcodeproj -scheme Voice -configuration Release \
    -derivedDataPath "$derived" build

products="$derived/Build/Products/Release"
app=""
for candidate in "$products"/*.app; do
    if [ -d "$candidate" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null)" = com.example.flow ]; then
        if [ -n "$app" ]; then printf 'More than one FLOW app bundle was found.\n' >&2; exit 1; fi
        app="$candidate"
    fi
done
if [ -z "$app" ]; then printf 'FLOW app bundle not found.\n' >&2; exit 1; fi
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
if ! "$install"; then exit 0; fi

install_dir="$HOME/Applications"
target="$install_dir/Flow.app"
if [ -f "$target/Contents/Info.plist" ]; then
    bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target/Contents/Info.plist")
    if ps -axo comm= | grep -Fxq "$target/Contents/MacOS/$bundle_executable"; then
        printf 'Quit the installed FLOW app before replacing it.\n' >&2
        exit 1
    fi
fi
mkdir -p "$install_dir"
staging="$(mktemp -d "$install_dir/.flow-install.XXXXXX")"
ditto "$app" "$staging/Flow.app"
codesign --verify --strict "$staging/Flow.app"

if [ -e "$target" ]; then
    mv "$target" "$staging/Previous.app"
fi
if ! mv "$staging/Flow.app" "$target"; then
    if [ -e "$staging/Previous.app" ]; then mv "$staging/Previous.app" "$target"; fi
    exit 1
fi
if [ -e "$staging/Previous.app" ]; then
    printf 'Previous bundle saved at %s\n' "$staging/Previous.app"
else
    rmdir "$staging"
fi
printf 'Installed %s\n' "$target"
