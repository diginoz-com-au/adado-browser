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
