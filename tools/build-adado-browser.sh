#!/usr/bin/env bash
# AdaDo Browser — repeatable build pipeline (ADADO-671)
#
# This is the REAL ungoogled-chromium build recipe from docs/building.md,
# run against OUR fork (this repo) with the adado-branding patch layer
# (patches/extra/adado-branding/*) applied on top of upstream's own series.
#
# WHY THIS SCRIPT EXISTS (ADADO-671's own framing): "Chromium builds need
# ~16GB+ RAM, tens of GB disk, hours per build -- decide the build host...
# and set up a repeatable build pipeline (this is the bulk of the work)."
# This script IS that pipeline. It has NOT been run to completion on adabox
# in this build pass -- see README-ADADO-671.md "Honest gap" section for why
# (disk: adabox has 56GB free where the sandboxed build dirs live; a full
# checkout+build needs ~150-200GB).
#
# Usage: BUILD_ROOT=/path/with/200GB/free ./tools/build-adado-browser.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build/work}"
JOBS="${JOBS:-$(nproc)}"

echo "[adado-browser] repo:       $REPO_ROOT"
echo "[adado-browser] build root: $BUILD_ROOT"
echo "[adado-browser] chromium:   $(cat "$REPO_ROOT/chromium_version.txt")"

need_gb() {
  echo "[adado-browser] NOTE: full chromium checkout + build needs ~30GB"
  echo "  source + ~100-150GB build output. Verify \$BUILD_ROOT's filesystem"
  echo "  has that much free before continuing (df -h \"\$BUILD_ROOT\")."
}
need_gb

mkdir -p "$BUILD_ROOT/download_cache"

# 1. Fetch pinned chromium source (per downloads.ini / revision.txt)
"$REPO_ROOT/utils/downloads.py" retrieve -c "$BUILD_ROOT/download_cache" -i "$REPO_ROOT/downloads.ini"
"$REPO_ROOT/utils/downloads.py" unpack -c "$BUILD_ROOT/download_cache" -i "$REPO_ROOT/downloads.ini" -- "$BUILD_ROOT/src"

# 2026-10-25 (Claude, Dan live: "theres probably an sdk that has them...
# to have run first for dependencies?" -- correct call, after 3
# individually-discovered missing build-time deps in a row (rust
# toolchain, pinned cpython3, llvm-build revision marker). Chromium's
# real DEPS file lists every one of these with the exact fetch command,
# which is exactly what `gclient runhooks` processes -- using the real,
# authoritative mechanism instead of guessing at gaps one at a time.
# depot_tools is just scripts (not a large download); this doesn't need
# a full `gclient sync` (which would re-clone all of chromium/src's git
# history) -- `managed: False` lets it operate on the already-unpacked
# tree from downloads.py above.
cat > "$BUILD_ROOT/.gclient" << GCLIENT_EOF
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "deps_file": "DEPS",
    "managed": False,
  },
]
GCLIENT_EOF
( cd "$BUILD_ROOT" && gclient runhooks )

# 2. Prune binaries ungoogled-chromium doesn't ship prebuilt
"$REPO_ROOT/utils/prune_binaries.py" "$BUILD_ROOT/src" "$REPO_ROOT/pruning.list"

# 3. Apply the FULL patch series -- upstream ungoogled-chromium patches
#    PLUS our patches/extra/adado-branding/* (appended to patches/series,
#    applies last, on top of upstream's own search-engine-replacement patch)
"$REPO_ROOT/utils/patches.py" apply "$BUILD_ROOT/src" "$REPO_ROOT/patches"

# 4. Domain substitution (ungoogled's de-Googling of literal domain strings)
"$REPO_ROOT/utils/domain_substitution.py" apply \
  -r "$REPO_ROOT/domain_regex.list" \
  -f "$REPO_ROOT/domain_substitution.list" \
  -c "$BUILD_ROOT/domsubcache.tar.gz" \
  "$BUILD_ROOT/src"

# 5. GN + build
mkdir -p "$BUILD_ROOT/src/out/Default"
cp "$REPO_ROOT/flags.gn" "$BUILD_ROOT/src/out/Default/args.gn"
( cd "$BUILD_ROOT/src" && ./tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles -j"$JOBS" -o out/Default/ )
( cd "$BUILD_ROOT/src" && ./out/Default/gn gen out/Default --fail-on-unused-args )
( cd "$BUILD_ROOT/src" && ninja -C out/Default -j"$JOBS" chrome chromedriver chrome_sandbox )

echo "[adado-browser] Build complete: $BUILD_ROOT/src/out/Default/chrome"
