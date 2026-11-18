#!/usr/bin/env bash
# Proves the package is clean for the people who depend on it: a throwaway app package depends on the package
# folder by path, uses both products, and is built in debug and in release. It then checks that
#   - no demo and no test fixture was compiled into either build, and
#   - the release binary holds no live-editing code.
# Usage: bash scripts/consumer-check.sh <package folder named dialecto-swift>
set -euo pipefail

pkg="$(cd "${1:?usage: consumer-check.sh <package folder>}" && pwd)"
name="$(basename "$pkg")"
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
app="$tmp/consumer"
mkdir -p "$app/Sources/Consumer"

printf '%s\n' \
  '// swift-tools-version: 6.0' \
  'import PackageDescription' \
  'let package = Package(' \
  '    name: "Consumer",' \
  '    platforms: [.macOS(.v14)],' \
  "    dependencies: [.package(path: \"$pkg\")]," \
  '    targets: [' \
  '        .executableTarget(name: "Consumer", dependencies: [' \
  "            .product(name: \"DialectoLive\", package: \"$name\")," \
  "            .product(name: \"DialectoLiveEditing\", package: \"$name\")," \
  '        ]),' \
  '    ]' \
  ')' > "$app/Package.swift"

printf '%s\n' \
  'import DialectoLive' \
  '#if DEBUG' \
  'import DialectoLiveEditing' \
  '#endif' \
  'import SwiftUI' \
  '' \
  '@MainActor func launch() -> Text {' \
  '    #if DEBUG' \
  '    DialectoLiveEditing.start(project: "owner/name", tokenStorage: .memory)' \
  '    #endif' \
  '    return Text(live: "export.button", default: "Export")' \
  '}' \
  'print(DialectoLive.string("export.button", default: "Export"))' > "$app/Sources/Consumer/main.swift"

# Nothing the consumer compiles may come from a demo or the fixtures.
no_extras() {
  local found
  found="$(find "$app/.build" \( -iname '*dialecto-live-demo*' -o -iname '*dialecto_live_demo*' \
    -o -iname '*dialecto-live-ios-demo*' -o -iname '*DialectoLiveFixtures*' -o -iname '*DialectoLiveDemo*' \) | head -5)"
  [[ -z "$found" ]] || fail "the $1 build compiled a demo or the fixtures: $found"
  echo "$1: no demo and no fixtures compiled"
}

step "Consumer, debug build"
(cd "$app" && swift build -c debug 2>&1 | tail -3)
no_extras debug
compiled="$(cd "$app" && swift build -c debug -v 2>&1 | grep -c 'DialectoLiveEditing' || true)"
[[ "$compiled" -gt 0 ]] || fail "the debug build does not compile DialectoLiveEditing"
echo "debug: DialectoLiveEditing compiled in"

step "Consumer, release build"
(cd "$app" && swift build -c release 2>&1 | tail -3)
no_extras release

step "Release binary holds no live editing"
bin="$(cd "$app" && swift build -c release --show-bin-path)/Consumer"
[[ -f "$bin" ]] || fail "no release binary at $bin"
for word in "api/live/native/device" "api/live/native/token" "api/live/native/drafts" \
  "eu.dialecto.live-editing" "Sign in to Dialecto" "Waiting for approval" "Sign out of Dialecto" \
  "EditingRuntime" "DraftSession" "DraftLayer" "LookupLog" "KeysPanel"; do
  ! grep -aqF "$word" "$bin" || fail "the release binary holds \"$word\""
done
echo "release: none of 12 live-editing strings in the binary"
"$bin" >/dev/null || fail "the release binary does not run"
echo "release: binary runs"
echo "Consumer check: OK"
