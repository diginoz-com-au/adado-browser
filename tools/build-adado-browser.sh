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
# 2026-10-25 (Claude): 10th real failure -- gclient internally runs
# `git diff ... -G 'Subproject commit'` to check for submodule changes,
# even with managed: False. The downloads.py-unpacked tree has no .git
# at all ("Not a git repository"). Doesn't need real chromium history --
# just needs SOME git state so that internal diff is empty, not an error.
( cd "$BUILD_ROOT/src" && git init -q && git add -A && \
  git -c user.email="build@adado.local" -c user.name="adado-browser-build" commit -q -m "init for gclient" )

# 2026-10-25 (Claude): 13th real failure -- the single top-level git-init
# only satisfies gclient's check for src/ itself. Chromium's real DEPS
# lists MANY individual git-type dependencies (e.g. third_party/angle)
# that real Chromium checkouts clone as their OWN separate git repos;
# gclient recurses into each one doing the same diff check. Rather than
# discover each one individually (same shape as the last several
# rounds), git-init every existing third_party/* subdirectory in one
# pass -- virtually all of Chromium's git-type deps live there.
for d in "$BUILD_ROOT/src/third_party"/*/; do
  if [ -d "$d" ] && [ ! -e "$d/.git" ]; then
    ( cd "$d" && git init -q && git add -A -- . 2>/dev/null && \
      git -c user.email="build@adado.local" -c user.name="adado-browser-build" commit -q -m "init for gclient" --allow-empty 2>/dev/null ) || true
  fi
done

# 2026-10-25 (Claude): 14th real failure -- a handful of third_party deps
# (devtools-frontend among them) use a one-level-deeper convention:
# third_party/<name>/src is the REAL git-type DEPS entry, with <name>/
# itself just a wrapper folder (README.chromium etc). The blanket loop
# above only reaches third_party/*/ (one level), so this nested src/
# never got its own .git even though its wrapper parent did. Second,
# narrowly-targeted pass for exactly that convention -- cheap (only a
# few real matches) rather than an expensive full-depth sweep of every
# third_party subdirectory.
for d in "$BUILD_ROOT/src/third_party"/*/src/; do
  if [ -d "$d" ] && [ ! -e "$d/.git" ]; then
    ( cd "$d" && git init -q && git add -A -- . 2>/dev/null && \
      git -c user.email="build@adado.local" -c user.name="adado-browser-build" commit -q -m "init for gclient" --allow-empty 2>/dev/null ) || true
  fi
done

# 2026-10-25 (Claude): 12th real failure -- target_os=linux didn't gate
# this one out after all (an android_webview orderfile -- pure PGO
# binary-layout data, not functionally required; chrome_pgo_phase=0 is
# already set). A harmless empty placeholder is correct here, same
# pattern as the earlier marker files -- gclient just needs to read
# SOME file at this path, content is irrelevant with PGO disabled.
mkdir -p "$BUILD_ROOT/src/android_webview/tools"
touch "$BUILD_ROOT/src/android_webview/tools/android-webview-arm.orderfile.txt"
touch "$BUILD_ROOT/src/android_webview/tools/android-webview-arm64.orderfile.txt"

# 2026-10-25 (Claude): 11th real failure -- gclient tried to resolve an
# Android-only CIPD dependency (android_webview's orderfile) even though
# this is a Linux desktop build. target_os scopes DEPS's OS-conditional
# entries correctly, same as a real Linux Chromium checkout would set.
cat > "$BUILD_ROOT/.gclient" << GCLIENT_EOF
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "deps_file": "DEPS",
    "managed": False,
  },
]
target_os = ["linux"]
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
