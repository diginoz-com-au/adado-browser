# AdaDo Browser v2 — manually-fetched build dependencies

Real root cause (full explanation in tools/build-adado-browser.sh's own comments):
our checkout uses `managed: False` + synthetic git-init tricks to avoid a full
`gclient sync` (which would re-clone chromium/src's entire git history). That
means any DEPS entry gated on a `non_git_source`-style condition never gets
fetched by `gclient runhooks`, even with `custom_vars` set (tried, confirmed
it doesn't help). Each of these was discovered by a real ninja build failure
and fetched directly from its real upstream/Chromium-infra source.

Local durable cache: `/home/ada/engine/browser-deps-cache/` on adabox (ada
user). The build script still fetches from the network each run (simpler,
always gets the exact pinned bytes) — this cache exists so a future rebuild,
or recovery from one of these URLs going away, doesn't require re-discovering
each one from scratch via a failed CI run.

| # | Dependency | Real source | Local cache file | Install path in build |
|---|---|---|---|---|
| 24 | mold 3.0.0 (linker) | github.com/rui314/mold releases | `mold-3.0.0-x86_64-linux.tar.gz` | `buildtools/third_party/mold/cipd/mold` |
| 26 | Node.js v20.18.1 | nodejs.org/dist | `node-v20.18.1-linux-x64.tar.gz` | `third_party/node/linux/node-linux-x64/` |
| 27 | esbuild 0.28.2 (linux-x64) | npm `@esbuild/linux-x64` | `esbuild-linux-x64-0.28.2.tgz` | `third_party/devtools-frontend/src/third_party/esbuild/esbuild` |
| 28 | clang-format | Chromium GCS (exact pinned SHA256: `5d384f2a3e72f01c5c61dd07e3a2577723cfa20c8c019131467f00fb6da8a75c`) | `clang-format-5d384f2a.bin` | `buildtools/linux64-format/clang-format` |
| 29/30 | TypeScript 5.6.3 | npm `typescript` (5.x — **not** 7.x, see note below) | `typescript-5.6.3.tgz` | `third_party/typescript/linux-amd64/src/lib/` + a node-exec shim named `tsc` |
| batch | chromium-nodejs `node_modules.tar.gz` | Chromium GCS bucket `chromium-nodejs`, real pinned object `8b170cc9b6a9725b4082b7b2255ca797bc80ea5f` | `chromium-node_modules.tar.gz` | `third_party/node/node_modules/` |
| batch | chromium-bidi `node_modules.tar.gz` | Chromium GCS bucket `chromium-nodejs`, real pinned object `chromium-bidi/7da310bf...` | `chromium-bidi-node_modules.tar.gz` | `third_party/chromium-bidi/node_modules/` |
| batch | gperf | real system apt package (Ubuntu runner) | — (not cached, trivially reinstallable) | symlinked into `third_party/gperf/cipd/gperf` |
| batch | cpython3 linux-amd64 | real system python3 (Ubuntu runner) | — (not cached, trivially reinstallable) | symlinked into `third_party/cpython3/linux-amd64/bin/python3` |
| batch | Subresource Filter ruleset | Chromium GCS bucket `chromium-ads-detection`, real pinned object `22a0a5fc...` | `subresource-filter-UnindexedRules` | `third_party/subresource-filter-ruleset/data/UnindexedRules` |

## Important gotcha: TypeScript major-version trap

Chromium's real DEPS pins a CIPD package literally labeled `version:2@7.0.2` —
but that is **Chromium-infra's own internal CIPD build numbering**, not the
real npm `typescript@7.0.2` package. Real npm TS 7.x is the new Go-based
"tsgo" compiler line and ships almost no `lib/*.d.ts` files (confirmed: 1
total vs ~93 in a classic 5.x release). Using npm's real 7.0.2 breaks the
build (`lib.decorators.d.ts` missing and similar). The real fix is npm
`typescript@5.6.3`, which has the full classic lib/ set Chromium's build
actually expects. Don't "upgrade" this to match the DEPS version string
literally — the string doesn't mean what it looks like it means.

## The full real dependency audit (2026-10-27)

Chromium's complete DEPS file was parsed as real Python (not regex-guessed)
to find every `non_git_source`-gated entry relevant to a plain Linux
chrome+chromedriver+chrome_sandbox build (excluding Android/Windows/
internal-only entries, which don't apply — we don't set those checkout
flags). The table above covers every one found. If a future round hits
*another* missing dependency, something in Chromium's DEPS changed since
this audit (new upstream dependency added) — re-run the same real-DEPS-parse
approach rather than guessing.
