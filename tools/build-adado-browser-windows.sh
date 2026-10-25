#!/usr/bin/env bash
# AdaDo Browser — Windows build pipeline (ADADO-671)
#
# 2026-10-25 (Claude, Dan live: "we should make a windows and linux
# version at same time"): mirrors build-adado-browser.sh's real recipe,
# adapted for a Windows runner (MSVC via ilammy/msvc-dev-cmd, no Linux
# sysroot/clang-18/libc++ steps -- Chromium's own Windows toolchain
# (clang-cl) is fetched by gclient runhooks, same mechanism already
# proven for Linux). This is a FIRST attempt, not yet verified end to
# end -- expect to find real Windows-specific gaps the same way Linux
# needed several rounds to find its own.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build/work}"
JOBS="${JOBS:-2}"

echo "[adado-browser-windows] repo:       $REPO_ROOT"
echo "[adado-browser-windows] build root: $BUILD_ROOT"
echo "[adado-browser-windows] chromium:   $(cat "$REPO_ROOT/chromium_version.txt")"

mkdir -p "$BUILD_ROOT/download_cache"

# 1. Fetch pinned chromium source (per downloads.ini / revision.txt)
"$REPO_ROOT/utils/downloads.py" retrieve -c "$BUILD_ROOT/download_cache" -i "$REPO_ROOT/downloads.ini"
"$REPO_ROOT/utils/downloads.py" unpack -c "$BUILD_ROOT/download_cache" -i "$REPO_ROOT/downloads.ini" -- "$BUILD_ROOT/src"

# gclient needs the tree to be a real git repo internally (same real
# finding as the Linux pipeline) -- no real chromium history needed.
( cd "$BUILD_ROOT/src" && git init -q && git add -A && \
  git -c user.email="build@adado.local" -c user.name="adado-browser-build" commit -q -m "init for gclient" )

# 2026-10-25 (Claude): ported from the Linux pipeline's 13th/14th real
# failures -- gclient recurses the same "Subproject commit" diff check
# into every individual git-type DEPS entry, not just src/ itself.
# Blanket git-init every third_party/* wrapper dir, then the handful
# that use a one-level-deeper third_party/<name>/src convention.
for d in "$BUILD_ROOT/src/third_party"/*/; do
  if [ -d "$d" ] && [ ! -e "$d/.git" ]; then
    ( cd "$d" && git init -q && git add -A -- . 2>/dev/null && \
      git -c user.email="build@adado.local" -c user.name="adado-browser-build" commit -q -m "init for gclient" --allow-empty 2>/dev/null ) || true
  fi
done
for d in "$BUILD_ROOT/src/third_party"/*/src/; do
  if [ -d "$d" ] && [ ! -e "$d/.git" ]; then
    ( cd "$d" && git init -q && git add -A -- . 2>/dev/null && \
      git -c user.email="build@adado.local" -c user.name="adado-browser-build" commit -q -m "init for gclient" --allow-empty 2>/dev/null ) || true
  fi
done

# 2026-10-25 (Claude): ported from the Linux pipeline's 12th/15th real
# failures -- a couple of hooks read android-only/PGO-only files
# unconditionally regardless of target_os. Harmless empty placeholders;
# chrome_pgo_phase=0 already disables real PGO use, and COMMON_METADATA
# is pure CI test-tagging, not functional build output.
mkdir -p "$BUILD_ROOT/src/android_webview/tools"
touch "$BUILD_ROOT/src/android_webview/tools/android-webview-arm.orderfile.txt"
touch "$BUILD_ROOT/src/android_webview/tools/android-webview-arm64.orderfile.txt"
mkdir -p "$BUILD_ROOT/src/chrome/android"
touch "$BUILD_ROOT/src/chrome/android/COMMON_METADATA"

cat > "$BUILD_ROOT/.gclient" << GCLIENT_EOF
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "deps_file": "DEPS",
    "managed": False,
  },
]
target_os = ["win"]
GCLIENT_EOF
# 2026-10-25 (Claude): 16th real failure -- see comment in the stub
# content below. Overwrite BEFORE gclient runhooks runs it.
mkdir -p "$BUILD_ROOT/src/testing"
cat > "$BUILD_ROOT/src/testing/generate_location_tags.py" << 'STUB_EOF'
#!/usr/bin/env python3
# 2026-10-25 (Claude): 16th real failure -- the real generate_location_tags.py
# recursively looks for a COMMON_METADATA file in arbitrarily many
# directories across chrome/android's whole tree (two different missing
# paths found in two consecutive runs; whack-a-moling each one is an
# unbounded tail). This script only feeds Chromium's own CI test-sharding/
# flakiness dashboards (resultdb) -- irrelevant to compiling
# chrome/chromedriver/chrome_sandbox. Stub it to a no-op that satisfies
# the hook's own contract (write valid JSON to --out) without walking
# any directory tree.
import argparse
import json

parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True)
args = parser.parse_args()
with open(args.out, "w") as f:
    json.dump({}, f)
STUB_EOF

( cd "$BUILD_ROOT" && gclient runhooks )

# 2. Prune binaries ungoogled-chromium doesn't ship prebuilt
"$REPO_ROOT/utils/prune_binaries.py" "$BUILD_ROOT/src" "$REPO_ROOT/pruning.list"

# 3. Apply the FULL patch series
"$REPO_ROOT/utils/patches.py" apply "$BUILD_ROOT/src" "$REPO_ROOT/patches"

# 4. Domain substitution
"$REPO_ROOT/utils/domain_substitution.py" apply \
  -r "$REPO_ROOT/domain_regex.list" \
  -f "$REPO_ROOT/domain_substitution.list" \
  -c "$BUILD_ROOT/domsubcache.tar.gz" \
  "$BUILD_ROOT/src"

# 5. GN + build (MSVC env already sourced by ilammy/msvc-dev-cmd in the
# workflow step before this script runs)
mkdir -p "$BUILD_ROOT/src/out/Default"
cp "$REPO_ROOT/flags.gn" "$BUILD_ROOT/src/out/Default/args.gn"
( cd "$BUILD_ROOT/src" && python3 tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles -j"$JOBS" -o out/Default/ )
( cd "$BUILD_ROOT/src" && ./out/Default/gn.exe gen out/Default --fail-on-unused-args )
( cd "$BUILD_ROOT/src" && ninja -C out/Default -j"$JOBS" chrome )

echo "[adado-browser-windows] Build complete: $BUILD_ROOT/src/out/Default/chrome.exe"
