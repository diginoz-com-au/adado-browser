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

# 2026-10-25 (Claude): 5th real build failure -- moved here from after
# domain substitution. update_rust.py's own download URL points at
# Google's real CDN; domain_substitution.py (step 4) rewrites that exact
# string into a de-Googled placeholder throughout the source tree, so
# running this AFTER substitution silently broke the download. Build-time
# toolchain fetches must happen on the real, unsubstituted tree.
( cd "$BUILD_ROOT/src" && python3 tools/rust/update_rust.py ) || echo "update_rust.py exited non-zero (continuing to inspect)"
echo "[adado-browser] third_party/rust-toolchain/ contents after update_rust.py:"
ls -la "$BUILD_ROOT/src/third_party/rust-toolchain/" 2>&1 || echo "  (directory does not exist)"
find "$BUILD_ROOT/src/third_party/rust-toolchain/" -name VERSION 2>&1 || true

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

# 2026-10-25 (Claude): third real build failure -- gn itself compiled
# fine, but `gn gen` asserts on a missing Debian sysroot
# (build/linux/debian_bullseye_amd64-sysroot). The full `gclient
# runhooks` flow downloads this automatically; this manual recipe
# (following docs/building.md's own steps 1-6) never calls it, so do it
# explicitly before gn gen.
"$BUILD_ROOT/src/build/linux/sysroot_scripts/install-sysroot.py" --arch=amd64

# 5. GN + build
mkdir -p "$BUILD_ROOT/src/out/Default"
cp "$REPO_ROOT/flags.gn" "$BUILD_ROOT/src/out/Default/args.gn"
( cd "$BUILD_ROOT/src" && ./tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles -j"$JOBS" -o out/Default/ )
( cd "$BUILD_ROOT/src" && ./out/Default/gn gen out/Default --fail-on-unused-args )
( cd "$BUILD_ROOT/src" && ninja -C out/Default -j"$JOBS" chrome chromedriver chrome_sandbox )

echo "[adado-browser] Build complete: $BUILD_ROOT/src/out/Default/chrome"
