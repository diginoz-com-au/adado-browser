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
# 2026-10-28 (Claude): 46th real failure, and the real root cause behind
# the whole import.meta.main saga (39th-45th fixes): this fetch was
# hardcoded to Node v20.18.1 at the time of the 26th fix, but Chromium's
# OWN dependency metadata (third_party/node/update_node_binaries) -- read
# directly by the build's own check_version.js step, which only now got
# far enough to actually run and say so -- expects v24.12.0. v20 simply
# doesn't have import.meta.main (added much later), which is exactly why
# that guard kept silently no-oping. Fetching the version this exact
# pinned checkout actually expects, instead of patching around scripts
# written for the Node version chromium's own DEPS already declares.
NODE_DIR="$BUILD_ROOT/src/third_party/node/linux/node-linux-x64"
mkdir -p "$NODE_DIR"
curl -fL -o /tmp/node.tar.gz \
  https://nodejs.org/dist/v24.12.0/node-v24.12.0-linux-x64.tar.gz
tar -xzf /tmp/node.tar.gz -C /tmp
cp -r /tmp/node-v24.12.0-linux-x64/. "$NODE_DIR/"
chmod +x "$NODE_DIR/bin/node"
rm -rf /tmp/node.tar.gz /tmp/node-v24.12.0-linux-x64

# 2026-10-27 (Claude): 27th real failure -- same class again, one layer
# deeper: devtools-frontend/src/third_party/esbuild/esbuild missing (its
# own nested DEPS, not chromium's top-level one -- same gclient-runhooks
# gap). Real upstream esbuild binary via its official npm package
# (platform-specific binary packages, same artifact `npm install esbuild`
# would fetch).
#
# 2026-10-27 (Claude): 38th real failure -- the "CLI is stable enough
# across versions" assumption above was wrong. devtools-frontend's own
# vendored node_modules (the separately-fetched chromium-bidi/chromium
# node_modules tarballs) ship esbuild's JS host wrapper pinned to 0.25.1,
# which refuses to drive a mismatched native binary: "Cannot start
# service: Host version 0.25.1 does not match binary version 0.28.2".
# The JS wrapper version isn't something this script controls (it comes
# from the vendored node_modules tarball), so the real fix is fetching
# the native binary at the SAME version the wrapper expects, not latest.
ESBUILD_DIR="$BUILD_ROOT/src/third_party/devtools-frontend/src/third_party/esbuild"
mkdir -p "$ESBUILD_DIR"
curl -fL -o /tmp/esbuild.tgz \
  https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.1.tgz
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
# 2026-10-27 (Claude): 34th real failure -- 5.9.2 is STILL missing some
# files (lib.es2025.collection.d.ts, from TS 6.0). Using real stable
# 6.0.3 -- confirmed classic lib format (110 lib/*.d.ts files, not the
# broken 7.x tsgo line), has both lib.decorators.d.ts AND the es2025
# files. This is the newest real classic-format release; if a future
# round still finds a missing lib file, there is no newer classic
# version to fall back to -- would need a different real fix.
curl -fL -o /tmp/typescript.tgz \
  https://registry.npmjs.org/typescript/-/typescript-6.0.3.tgz
tar -xzf /tmp/typescript.tgz -C /tmp
cp -r /tmp/package/lib/. "$TSC_DIR/"
# 2026-10-28 (Claude): 47th real failure, surfaced only now that the
# 46th fix got Node to the real pinned v24.12.0 -- tsc.js (CommonJS,
# "module.exports = require(...)") was being loaded as an ES module
# because node resolves "type" from the NEAREST package.json up the
# tree, and the Chromium checkout's own root package.json declares
# "type": "module". A local package.json right here overrides that for
# this one vendored directory -- the standard, surgical Node fix for
# shipping a CommonJS package inside an ESM-typed project, and it
# doesn't require touching tsc.js itself or the wrapper below.
echo '{"type": "commonjs"}' > "$TSC_DIR/package.json"
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
# 2026-10-27 (Claude): 35th real failure -- ninja actually wants the
# binary at cipd/bin/gperf (a bin/ subdir), not cipd/gperf directly.
mkdir -p "$BUILD_ROOT/src/third_party/gperf/cipd/bin"
ln -sf "$(command -v gperf)" "$BUILD_ROOT/src/third_party/gperf/cipd/bin/gperf"

# 2026-10-27 (Claude): 36th real failure -- devtools-frontend's own real
# generator scripts (e.g. front_end/core/i18n/generate-locales-js.js) use
# ES-module `import` syntax, which Node only honours if the nearest
# package.json up the tree says "type": "module". The real upstream repo
# (chromium.googlesource.com/devtools/devtools-frontend) ships exactly that
# at its root -- confirmed by fetching it directly -- but it's missing from
# our synced tree (same non_git_source DEPS-hook-skipping class as every
# other gap fixed this session, just narrower: one file, not a whole
# dependency). Write it only if actually missing, so a real future gclient
# fix won't get silently clobbered.
DTF_PKG="$BUILD_ROOT/src/third_party/devtools-frontend/src/package.json"
mkdir -p "$(dirname "$DTF_PKG")"
if [ -f "$DTF_PKG" ]; then
  # 2026-10-27 (Claude): 37th real failure -- the file already existed
  # (DEPS pins an older devtools-frontend commit than the one I checked
  # upstream, predating "type": "module" being added there), so the
  # earlier if-missing-only fix silently skipped writing. Patch the
  # existing file in place instead of assuming it is missing.
  python3 - "$DTF_PKG" <<'PYEOF'
import json, sys
p = sys.argv[1]
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d["type"] = "module"
with open(p, "w") as f:
    json.dump(d, f)
PYEOF
else
  echo '{"type": "module"}' > "$DTF_PKG"
fi

# 2026-10-28 (Claude): 42nd real failure, finally ROOT-CAUSED with hard
# evidence instead of guessing (3 diagnostic rounds: confirmed the
# generate_skills action exits 0 and writes nothing, ruled out ninja
# races/caching, then dumped the REAL pinned build_ai_skills.mjs source
# straight from this checkout). Its entry-point guard is
# `if (import.meta.main) { runMain(); }` -- import.meta.main is a VERY
# recent Node.js addition. The Node binary this build fetches
# (third_party/node) predates it, so `import.meta.main` is simply
# undefined, the guard is false, runMain() NEVER RUNS, and the script
# exits 0 having silently done nothing -- exactly matching every
# symptom observed (success exit code, zero bytes written, identical
# whether invoked via ninja, directly, or with any args). Same class of
# bug as the esbuild-version mismatch (38th fix): a tool/runtime version
# gap between what this pinned devtools-frontend commit's source expects
# and what's actually available. This script is only ever invoked as a
# CLI entry point by the GN action (never imported elsewhere), so the
# guard is dead weight here -- patch it to call runMain()
# unconditionally instead of upgrading the pinned Node (which every
# other build tool in this tree also depends on; narrower is safer).
# 2026-10-28 (Claude): 43rd real failure -- a DIFFERENT devtools-frontend
# generator (scripts/build/generate_css_js_files.js, for ui/kit's
# CSS-to-JS inlining) hit the exact same shape: exits 0, writes nothing.
# Confirmed via direct evidence (ran its real command outside ninja --
# exit 0, target directory never even created). Given the SAME team
# likely added this entry-point convention to multiple build scripts
# around the same time, generalized the 42nd fix into a sweep of every
# scripts/build/*.js and *.mjs file instead of patching one script per
# failed build attempt as each one is discovered the hard way.
DTF_BUILD_SCRIPTS="$BUILD_ROOT/src/third_party/devtools-frontend/src/scripts/build"
if [ -d "$DTF_BUILD_SCRIPTS" ]; then
  python3 - "$DTF_BUILD_SCRIPTS" <<'PYEOF'
import sys, glob, os
d = sys.argv[1]
OLD = "if (import.meta.main) {\n  runMain();\n}"
patched = []
for p in glob.glob(os.path.join(d, "*.js")) + glob.glob(os.path.join(d, "*.mjs")):
    try:
        with open(p) as f:
            c = f.read()
    except Exception:
        continue
    if OLD in c:
        c = c.replace(OLD, "runMain();")
        with open(p, "w") as f:
            f.write(c)
        patched.append(os.path.basename(p))
if patched:
    print("OK patched import.meta.main guard in:", ", ".join(patched))
else:
    print("WARN no scripts matched the known guard pattern -- nothing patched")
PYEOF
fi

# 2026-10-28 (Claude): 45th real failure, same night -- with the 44th
# fix's sweep confirmed working (runMain() now genuinely executes, per
# the real stack trace: "at runMain (generate_css_js_files.js:62:5)"),
# a real NEW bug surfaced underneath it: fs.writeFileSync failed with
# ENOENT because the parent directory (gen/.../ui/kit/cards/) doesn't
# exist yet. The real stack trace pinned this to the SHARED helper both
# generator scripts call -- "at writeIfChanged
# (scripts/build/ninja/write-if-changed.js:29:6)" -- which writes
# directly with no mkdir first. Same lesson as the 44th fix: patch the
# ONE shared helper instead of each generator script that happens to
# call it, since more probably exist beyond just these two.
WRITE_IF_CHANGED="$BUILD_ROOT/src/third_party/devtools-frontend/src/scripts/build/ninja/write-if-changed.js"
if [ -f "$WRITE_IF_CHANGED" ]; then
  python3 - "$WRITE_IF_CHANGED" <<'PYEOF'
import sys, re
p = sys.argv[1]
with open(p) as f:
    c = f.read()

if "mkdirSync" in c or "mkdir(" in c:
    print("INFO write-if-changed.js already creates its directory -- left untouched")
    raise SystemExit

# Adaptive, not a guessed literal match: upstream main uses a DIFFERENT
# (async, fs/promises) variant than this pinned revision's real sync
# version per its own stack trace (Module.writeFileSync) -- same
# main-vs-pin mismatch class as every other fix tonight. Extract the
# real function signature and first parameter name structurally instead
# of assuming exact content, so this works whichever variant this pin
# actually has.
m = re.search(r'(export\s+(?:async\s+)?function\s+writeIfChanged\s*\(\s*(\w+)[^)]*\)\s*\{)', c)
if not m:
    print("WARN could not locate writeIfChanged's signature -- left untouched")
    raise SystemExit

first_param = m.group(2)
insert_point = m.end()

if "from 'node:path'" not in c and 'from "node:path"' not in c:
    first_import_end = c.index('\n', c.index('import ')) + 1
    c = c[:first_import_end] + "import * as path from 'node:path';\n" + c[first_import_end:]
    m = re.search(r'(export\s+(?:async\s+)?function\s+writeIfChanged\s*\(\s*(\w+)[^)]*\)\s*\{)', c)
    insert_point = m.end()
    first_param = m.group(2)

if "import * as fs from 'node:fs'" in c:
    fs_mkdir_stmt = "\n  fs.mkdirSync(path.dirname(" + first_param + "), {recursive: true});"
elif "from 'node:fs/promises'" in c or 'from "node:fs/promises"' in c:
    first_import_end = c.index('\n', c.index('import ')) + 1
    c = c[:first_import_end] + "import {mkdirSync} from 'node:fs';\n" + c[first_import_end:]
    m = re.search(r'(export\s+(?:async\s+)?function\s+writeIfChanged\s*\(\s*(\w+)[^)]*\)\s*\{)', c)
    insert_point = m.end()
    first_param = m.group(2)
    fs_mkdir_stmt = "\n  mkdirSync(path.dirname(" + first_param + "), {recursive: true});"
else:
    print("WARN unrecognized fs import style -- left untouched")
    raise SystemExit

c = c[:insert_point] + fs_mkdir_stmt + c[insert_point:]
with open(p, "w") as f:
    f.write(c)
print("OK patched write-if-changed.js to mkdir -p before writing (param: " + first_param + ")")
PYEOF
fi

# 2026-10-28 (Claude): 49th real failure -- surfaced only now that tsc
# genuinely runs (the 47th fix's ESM/CJS patch worked): a REAL TypeScript
# type error in Chromium's own ui/webui/resources/js/custom_element.ts,
# not a build-tooling bug. Confirmed via the real upstream source
# (template.innerHTML = (this.constructor as typeof CustomElement).template
# || emptyHTML();) -- TypeScript 6.0.3's DOM lib types Element.innerHTML's
# accepted value as `string | TrustedHTML`, and whatever `.template` /
# emptyHTML() resolve to here is apparently typed as that same union,
# which 6.0.3's checker now correctly flags as not narrowable to a bare
# `string` in this assignment context. Rather than gamble on yet another
# TypeScript version (already went through 4 rounds, 5.6.3->5.9.2->6.0.3,
# to get the classic lib .d.ts files chromium's build actually needs --
# there's no newer classic-format release to fall back to if this picks a
# new problem), cast at the one real call site instead -- safe: the
# runtime behavior is unchanged (Element.innerHTML's setter has always
# accepted a TrustedHTML value; this only affects compile-time type
# checking), and it's the same file-patch pattern already used
# successfully all night for pinned-vs-main source mismatches.
CUSTOM_ELEMENT_TS="$BUILD_ROOT/src/ui/webui/resources/js/custom_element.ts"
if [ -f "$CUSTOM_ELEMENT_TS" ]; then
  python3 - "$CUSTOM_ELEMENT_TS" <<'PYEOF'
import sys
p = sys.argv[1]
with open(p) as f:
    c = f.read()
OLD = "template.innerHTML =
        (this.constructor as typeof CustomElement).template || emptyHTML();"
NEW = "template.innerHTML =
        ((this.constructor as typeof CustomElement).template || emptyHTML()) as string;"
if OLD in c:
    c = c.replace(OLD, NEW)
    with open(p, "w") as f:
        f.write(c)
    print("OK patched custom_element.ts's innerHTML assignment with an explicit cast")
else:
    print("WARN anchor not found -- custom_element.ts content differs from expected, leaving untouched")
PYEOF
fi

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

# 2026-10-28 (Claude, Dan live: "theres gotta be more you can do to stop
# v2 having any more retrys... seems like its still all just missing
# dependencies that should have been predicted and pre-installed"). Fast
# preflight check (seconds, not the 45-90 minutes a real ninja build takes
# to reach and reveal a missing dependency) -- verifies every dependency
# this script itself is responsible for fetching actually landed where
# expected, and fails immediately with a clear table if not. This can
# only catch dependencies THIS SCRIPT knows about (every one found so far
# across 38 real fix rounds) -- it cannot predict a brand-new, not-yet-
# discovered gap, but it turns "wait an hour to find out" into "find out
# in seconds" for every known category.
echo "[preflight] verifying all known dependencies landed..."
PREFLIGHT_FAIL=0
check() {
  if [ -e "$1" ]; then
    echo "  OK   $1"
  else
    echo "  MISS $1"
    PREFLIGHT_FAIL=1
  fi
}
check "$BUILD_ROOT/src/buildtools/third_party/mold/cipd/mold"
check "$BUILD_ROOT/src/third_party/node/linux/node-linux-x64/bin/node"
check "$BUILD_ROOT/src/third_party/devtools-frontend/src/third_party/esbuild/esbuild"
check "$BUILD_ROOT/src/buildtools/linux64-format/clang-format"
check "$BUILD_ROOT/src/third_party/typescript/linux-amd64/src/lib/tsc"
check "$BUILD_ROOT/src/third_party/node/node_modules"
check "$BUILD_ROOT/src/third_party/chromium-bidi/node_modules"
check "$BUILD_ROOT/src/third_party/gperf/cipd/bin/gperf"
check "$BUILD_ROOT/src/third_party/cpython3/linux-amd64/bin/python3"
check "$BUILD_ROOT/src/third_party/subresource-filter-ruleset/data/UnindexedRules"
check "$BUILD_ROOT/src/third_party/devtools-frontend/src/package.json"
if [ "$PREFLIGHT_FAIL" -eq 1 ]; then
  echo "[preflight] FAILED -- one or more known dependencies missing before the real build even started."
  exit 1
fi
echo "[preflight] all known dependencies present, proceeding to the real build."

# 5. GN + build
mkdir -p "$BUILD_ROOT/src/out/Default"
cp "$REPO_ROOT/flags.gn" "$BUILD_ROOT/src/out/Default/args.gn"
( cd "$BUILD_ROOT/src" && ./tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles -j"$JOBS" -o out/Default/ )
( cd "$BUILD_ROOT/src" && ./out/Default/gn gen out/Default --fail-on-unused-args )

# 2026-10-28 (Claude): 39th-41st real failures were all symptoms of the
# SAME root cause, finally fixed at the source above (see the
# build_ai_skills.mjs patch near the DTF_PKG fix): that generator's
# import.meta.main entry-point guard silently no-oped under this build's
# older pinned Node, so it always exited 0 having written nothing,
# regardless of ninja ordering, parallelism, or preflight tricks -- none
# of which could have fixed a script that does nothing when run. No
# preflight workaround needed now that the real script actually runs.

# 2026-10-28 (Claude): 43rd real failure -- a DIFFERENT devtools-frontend
# generator (ui/kit's CSS-to-JS inlining for card/icon/link components)
# hit the same symptom shape (esbuild "Cannot read file" on its outputs).
# Get direct evidence of its real command + real pinned source + a
# direct run, same proven method as the 39th-42nd investigation, instead
# of assuming it's the same import.meta.main bug without checking.
# 2026-10-28 (Claude): removed the kit-CSS diagnostic block that lived
# here -- found (same night, during the 45th fix) that it could never
# have worked under this script's own `set -euo pipefail`: a failing
# command inside a `;`-separated list still aborts the whole script
# immediately under `-e`, same as `&&` would, so it died at the same
# point either way. Real evidence for the 45th fix came from the main
# build's own failure trace instead, which was sufficient -- no
# diagnostic needed here now that the actual bug (write-if-changed.js
# never creating its output directory) is already patched above.
( cd "$BUILD_ROOT/src" && ninja -C out/Default -j"$JOBS" chrome chromedriver chrome_sandbox )

echo "[adado-browser] Build complete: $BUILD_ROOT/src/out/Default/chrome"
