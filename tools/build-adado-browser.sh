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

# 2026-10-25 (Claude): 15th real failure -- generate_location_tags.py (a
# hook that tags tests for Chromium's own CI dashboards, unrelated to
# compiling chrome/chromedriver/chrome_sandbox) reads chrome/android/
# COMMON_METADATA unconditionally, regardless of target_os. Same class
# as the orderfile placeholders above: harmless empty marker file, pure
# CI test-metadata, not functional build output.
mkdir -p "$BUILD_ROOT/src/chrome/android"
touch "$BUILD_ROOT/src/chrome/android/COMMON_METADATA"

# 2026-10-25 (Claude): 11th real failure -- gclient tried to resolve an
# Android-only CIPD dependency (android_webview's orderfile) even though
# this is a Linux desktop build. target_os scopes DEPS's OS-conditional
# entries correctly, same as a real Linux Chromium checkout would set.
# 2026-10-27 (Claude, Dan live: "remember you were gonna install some
# chromium sdk type stuff that had all that apps so you dont have to keep
# failing and installing at every tool call" -- the real gap in the
# gclient-runhooks approach from the 2026-10-25 "theres probably an sdk
# that has them" fix: DEPS has conditional CIPD hooks (mold's fetch is
# `condition: host_os == "linux" and non_git_source`) that silently never
# fire because our synthetic "already synced" checkout (managed: False +
# git-init tricks, to avoid a full multi-GB re-clone) doesn't set the
# checkout-state vars those conditions check. DEPS itself defaults
# non_git_source to True for a REAL checkout; setting it explicitly here
# makes gclient runhooks evaluate conditional hooks the same way a normal
# checkout would, fetching mold (and anything else gated the same way)
# through the real mechanism instead of each one being individually
# discovered by a failed build. The manual mold fetch below stays as a
# safety net in case this alone isn't sufficient for some hook.
cat > "$BUILD_ROOT/.gclient" << GCLIENT_EOF
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {"non_git_source": True},
  },
]
target_os = ["linux"]
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

# 2026-10-25 (Claude): 17th real failure -- gn gen asserts the Debian
# sysroot (build/linux/debian_bullseye_amd64-sysroot) must exist. This
# was fetched by an explicit install-sysroot.py call in an earlier round
# of this script, then removed during the "there's probably an SDK...
# run first for dependencies" cleanup under the assumption gclient's own
# hooks would fetch it -- they don't; it's a genuinely separate step
# real Chromium contributors run themselves. Same window as the earlier
# rust-toolchain fix: after prune (which would otherwise sweep this
# freshly-fetched sysroot away as an unrecognized prebuilt-binary dir),
# before patches/domain-substitution.
python3 "$BUILD_ROOT/src/build/linux/sysroot_scripts/install-sysroot.py" --arch=amd64

# 2026-10-25 (Claude): 18th real failure -- gn gen also asserts
# third_party/rust-toolchain/VERSION must exist. Same root cause as the
# sysroot above: this was fetched by an explicit update_rust.py call in
# an earlier round, removed during the gclient-as-authoritative-
# mechanism cleanup on the wrong assumption gclient's own hooks fetch
# it too -- they fetch neither. Same safe window: after prune (which
# would otherwise sweep the freshly-fetched toolchain away), before
# patches/domain-substitution (which must not rewrite its download URL
# into a de-Googled placeholder before it's used).
python3 "$BUILD_ROOT/src/tools/rust/update_rust.py"

# 2026-10-25 (Claude): 19th real failure -- gn gen's own build helper
# (get_concurrent_links.py, called via exec_script) needs a pinned
# third_party/cpython3/host/bin/python3 binary. Same root cause as the
# sysroot/rust fixes above (fetched explicitly in an earlier round,
# removed in the gclient cleanup on the same wrong assumption). Symlink
# to the system python3 is sufficient here specifically because this
# helper only does CPU/memory introspection for link-job parallelism,
# not anything version-sensitive.
mkdir -p "$BUILD_ROOT/src/third_party/cpython3/host/bin"
ln -sf "$(command -v python3)" "$BUILD_ROOT/src/third_party/cpython3/host/bin/python3"

# 2026-10-26 (Claude): 20th real failure -- BUILD.gn reads
# third_party/llvm-build/Release+Asserts/cr_build_revision for AFDO/PGO
# profile matching. Same root cause as sysroot/rust/cpython3 above (all
# four were fixed individually in the ORIGINAL debugging pass, then all
# four got wiped out together in the gclient-cleanup round) -- this is
# the fourth and last of that original batch. Harmless placeholder:
# chrome_pgo_phase=0 is already set, so nothing reads this file's
# content for real PGO use, only its existence.
# 2026-10-26 (Claude): 21st real failure -- the "0" placeholder above was
# wrong. cr_build_revision isn't just a PGO marker; BUILD.gn asserts its
# content matches the clang toolchain update.py actually expects
# ("clang_revision=\"0\" but update.py expected ... Did you forget to
# gclient sync?"). Run the REAL Chromium-provided toolchain fetcher
# instead of guessing the string -- it downloads the correct prebuilt
# clang/LLVM AND writes the matching cr_build_revision itself, so this
# can never drift out of sync the way a hardcoded string would.
python3 "$BUILD_ROOT/src/tools/clang/scripts/update.py"

# 2026-10-26 (Claude): 24th real failure -- ninja: '../../buildtools/
# third_party/mold/cipd/mold', needed by 'phony/chrome/chrome_initial.
# inputs', missing and no known rule to make it. Chromium's own DEPS has
# this exact CIPD package (chromium/buildtools/third_party/mold/mold),
# but it's gated `condition: host_os == "linux" and non_git_source` --
# our checkout is a real git checkout (the whole point of the marker-file
# trick a few rounds back was avoiding gclient's full non-git sync), so
# non_git_source is false here and gclient runhooks silently never fetches
# it, while GN's build graph requires the file to exist regardless of how
# it got there. Fetching the real upstream mold release binary directly
# (same class of fix as the clang step above) sidesteps the gclient
# condition entirely instead of fighting it.
MOLD_DIR="$BUILD_ROOT/src/buildtools/third_party/mold/cipd"
mkdir -p "$MOLD_DIR"
curl -fL -o /tmp/mold.tar.gz \
  https://github.com/rui314/mold/releases/download/v3.0.0/mold-3.0.0-x86_64-linux.tar.gz
tar -xzf /tmp/mold.tar.gz -C /tmp
cp /tmp/mold-3.0.0-x86_64-linux/bin/mold "$MOLD_DIR/mold"
chmod +x "$MOLD_DIR/mold"
rm -rf /tmp/mold.tar.gz /tmp/mold-3.0.0-x86_64-linux

# 2026-10-27 (Claude): 26th real failure -- the custom_vars=non_git_source
# fix got mold working (that condition path IS satisfied now) but node
# still came up missing -- confirms gclient runhooks with managed:False
# just doesn't reliably execute condition-gated CIPD hooks at all, custom
# var or not. Same direct-fetch pattern as mold, real upstream Node.js
# release binary instead of guessing at why the hook didn't fire.
NODE_DIR="$BUILD_ROOT/src/third_party/node/linux/node-linux-x64"
mkdir -p "$NODE_DIR"
curl -fL -o /tmp/node.tar.gz \
  https://nodejs.org/dist/v20.18.1/node-v20.18.1-linux-x64.tar.gz
tar -xzf /tmp/node.tar.gz -C /tmp
cp -r /tmp/node-v20.18.1-linux-x64/. "$NODE_DIR/"
chmod +x "$NODE_DIR/bin/node"
rm -rf /tmp/node.tar.gz /tmp/node-v20.18.1-linux-x64

# 2026-10-27 (Claude): 27th real failure -- same class again, one layer
# deeper: devtools-frontend/src/third_party/esbuild/esbuild missing (its
# own nested DEPS, not chromium's top-level one -- same gclient-runhooks
# gap). Real upstream esbuild binary via its official npm package
# (platform-specific binary packages, same artifact `npm install esbuild`
# would fetch) rather than guessing at devtools-frontend's exact pinned
# CIPD version -- esbuild's CLI is stable enough across versions for a
# build-time bundling step like this.
ESBUILD_DIR="$BUILD_ROOT/src/third_party/devtools-frontend/src/third_party/esbuild"
mkdir -p "$ESBUILD_DIR"
curl -fL -o /tmp/esbuild.tgz \
  https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.28.2.tgz
tar -xzf /tmp/esbuild.tgz -C /tmp
cp /tmp/package/bin/esbuild "$ESBUILD_DIR/esbuild"
chmod +x "$ESBUILD_DIR/esbuild"
rm -rf /tmp/esbuild.tgz /tmp/package

# 2026-10-27 (Claude): 28th real failure -- buildtools/linux64-format/
# clang-format missing, same gclient-runhooks gap. This one's a GCS (not
# CIPD) dependency with a real pinned SHA256 in DEPS -- unlike mold/node/
# esbuild (where a "close enough" recent upstream release was fine), this
# fetches the EXACT pinned binary Chromium's own DEPS references, since
# the real URL and checksum are known and verifiable.
CLANG_FORMAT_DIR="$BUILD_ROOT/src/buildtools/linux64-format"
mkdir -p "$CLANG_FORMAT_DIR"
curl -fL -o "$CLANG_FORMAT_DIR/clang-format" \
  https://chromium-clang-format.storage.googleapis.com/5d384f2a3e72f01c5c61dd07e3a2577723cfa20c8c019131467f00fb6da8a75c
chmod +x "$CLANG_FORMAT_DIR/clang-format"

# 2026-10-27 (Claude): 29th real failure -- third_party/typescript/
# linux-amd64/src/lib/tsc missing. Real npm `typescript` package's lib/
# directory (tsc.js + its siblings, all required -- tsc.js isn't
# self-contained) placed at the exact expected path, with a thin shell
# wrapper named exactly `tsc` (no .js) that execs it via the real node
# binary already fetched above (third_party/node/linux/...) -- same
# pattern real npm-installed `tsc` uses (a shebang shim calling node).
TSC_DIR="$BUILD_ROOT/src/third_party/typescript/linux-amd64/src/lib"
mkdir -p "$TSC_DIR"
# 2026-10-27 (Claude): 30th real failure -- TypeScript 7.x turned out
# to be a totally different package (the new Go-based "tsgo" compiler
# line) with almost no lib/*.d.ts files at all -- real npm tarball
# check confirmed only 1 .d.ts in the whole package vs the ~93 a
# classic 5.x release ships (lib.decorators.d.ts included). Chromium's
# build expects the classic lib set; pinned to a known-good 5.x.
# 2026-10-27 (Claude): 31st real failure -- the comment block above was
# ACCIDENTALLY INSERTED BETWEEN the backslash line-continuation and the
# real URL below in the previous patch. In bash, a `#` on a continued
# line starts a comment that swallows the rest of that logical line --
# curl never received the URL at all ("curl: no URL specified"). Moved
# the comment above the whole curl statement instead of inside it.
# 2026-10-27 (Claude): 32nd real failure -- 5.6.3 is also missing some
# newer lib/*.d.ts files (lib.es2017.arraybuffer.d.ts, added in TS 5.7).
# Using the latest real 5.x (5.9.2, 102 lib .d.ts files -- the most
# complete classic-lib-format release) to minimize the odds of hitting
# yet another missing-lib-file round.
# 2026-10-27 (Claude): 33rd real failure -- made the EXACT SAME bug AGAIN
# (comment block landed between the backslash continuation and the real
# URL -- same root cause as the 31st fix, just reintroduced by not
# checking this specific pattern before pushing). Verified EVERY curl
# block in this file has its URL on the very next line after fixing this
# one -- see the grep check in the commit this change ships with.
curl -fL -o /tmp/typescript.tgz \
  https://registry.npmjs.org/typescript/-/typescript-5.9.2.tgz
tar -xzf /tmp/typescript.tgz -C /tmp
cp -r /tmp/package/lib/. "$TSC_DIR/"
cat > "$TSC_DIR/tsc" << TSC_EOF
#!/bin/sh
exec "$NODE_DIR/bin/node" "$TSC_DIR/tsc.js" "\$@"
TSC_EOF
chmod +x "$TSC_DIR/tsc"
rm -rf /tmp/typescript.tgz /tmp/package

# 2026-10-27 (Claude, Dan live: "we had a dependancies list...."): instead
# of continuing to discover one missing non_git_source-gated dependency per
# ~25min CI round-trip, pulled chromium's REAL full DEPS file and parsed it
# as actual Python (not regex-guessing) to extract every entry gated the
# same way our mold/node/esbuild/clang-format/tsc fixes were, filtered to
# what a plain Linux chrome+chromedriver+chrome_sandbox build (no
# checkout_android/win/src_internal) could plausibly need. These are the
# real, exact pinned GCS objects/CIPD packages from that file, fetched
# proactively in one batch rather than one-at-a-time.

# node_modules bundle chromium's own node toolchain depends on.
mkdir -p "$BUILD_ROOT/src/third_party/node"
curl -fL -o /tmp/node_modules.tar.gz \
  https://storage.googleapis.com/chromium-nodejs/8b170cc9b6a9725b4082b7b2255ca797bc80ea5f
tar -xzf /tmp/node_modules.tar.gz -C "$BUILD_ROOT/src/third_party/node"
rm -f /tmp/node_modules.tar.gz

# chromium-bidi's own node_modules -- used by chromedriver's WebDriver BiDi
# support, real production target of this build (chrome_sandbox/chromedriver).
mkdir -p "$BUILD_ROOT/src/third_party/chromium-bidi"
curl -fL -o /tmp/bidi_node_modules.tar.gz \
  https://storage.googleapis.com/chromium-nodejs/chromium-bidi/7da310bf46956828c164237a912a201d21f51220dfbe60df454188dbad75889c
tar -xzf /tmp/bidi_node_modules.tar.gz -C "$BUILD_ROOT/src/third_party/chromium-bidi"
rm -f /tmp/bidi_node_modules.tar.gz

# gperf: real compile-time perfect-hash codegen tool Chromium's build uses.
# Simple, standard Unix tool already packaged for Ubuntu -- real system
# apt package instead of guessing at the CIPD platform-templated URL.
sudo apt-get install -y gperf
mkdir -p "$BUILD_ROOT/src/third_party/gperf/cipd"
ln -sf "$(command -v gperf)" "$BUILD_ROOT/src/third_party/gperf/cipd/gperf"

# cpython3 linux-amd64 variant -- same real system-python symlink trick
# that already fixed the separate third_party/cpython3/host path (19th
# real failure fix) -- a different DEPS entry, same real fix.
mkdir -p "$BUILD_ROOT/src/third_party/cpython3/linux-amd64/bin"
ln -sf "$(command -v python3)" "$BUILD_ROOT/src/third_party/cpython3/linux-amd64/bin/python3"

# Subresource Filter's real ad-detection ruleset -- small (158KB), real
# production resource likely bundled into chrome's .pak resources at build
# time, not test-only data.
mkdir -p "$BUILD_ROOT/src/third_party/subresource-filter-ruleset/data"
curl -fL -o "$BUILD_ROOT/src/third_party/subresource-filter-ruleset/data/UnindexedRules" \
  https://storage.googleapis.com/chromium-ads-detection/22a0a5fc9e38d0de4e68eaf7e961dbbd2bebf234bebffbcd21bd496c0813fcde

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
