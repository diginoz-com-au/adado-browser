# AdaDo Browser — real source fork (ADADO-671)

Ticket: ADADO-671, "AdaDo Browser = our FORK of ungoogled-chromium (own repo,
own branding, we build it)". UUID `1227e3e4-68a5-43ca-9aa0-736303473a15`.

## Why this repo exists, and why it's separate from `../adado-browser/`

Dan's ticket text explicitly rejects the approach every prior AdaDo Browser
ticket (644/653/665/805/814/815) took: *"(b) flatpak-installing
ungoogled-chromium as-is = renting third-party. ... THE FORK: fork
ungoogled-chromium's source + build tooling into our own git repo
(adado-browser)."* The `../adado-browser/` directory in this same
`adado-engine` repo is that rejected approach: it composes a **prebuilt**
ungoogled-chromium AppImage (`/opt/adado-browser`, 205MB ELF, not built by
us) with a runtime enterprise-policy JSON layer. That work is real and
already verified (see `../adado-browser/ADADO-805-*.md`), but per this
ticket's own text it is exactly what Dan said not to do for the "own
build" thesis, so it does not satisfy ADADO-671 and this pass does not
re-cite it as evidence for 671.

**This directory (`adado-browser-src/`) is the actual fork**: a full,
unmodified `git clone` of the real upstream
`github.com/ungoogled-software/ungoogled-chromium` repo (verify with
`git log` — real upstream commit history, e.g. `800d0bb5 Update to Chromium
154.0.8037.57`), remote renamed `upstream`, with our own AdaDo branding
layer added as new commits/patches on top. `origin` is intentionally unset:
creating our own hosted GitHub repo for it is a repo/org-creation decision
(same class of gap as ADADO-336's "GitHub repo-split needs Dan" — filed,
not guessed at).

## What "ungoogled-chromium's source + build tooling" actually means

Important nuance: `ungoogled-chromium`'s own git repo does **not** vendor
full Chromium source (that would be tens of GB). It vendors the *build
tooling and patch set* (`utils/`, `patches/`, `flags.gn`, `downloads.ini`,
`domain_substitution.list`) that downloads a pinned Chromium source tree
at build time and transforms it. Forking *this* repo — tooling + patches +
pinned revision — **is** "forking ungoogled-chromium's source + build
tooling" in the sense the project itself uses those words (see
`docs/building.md` step 1: Chromium source itself is fetched by
`utils/downloads.py`, not carried in the repo).

## What's actually built and tested this pass

1. **The fork itself**: `git log -3` in this directory shows real upstream
   history (not a copy-paste). `git remote -v` shows `upstream` pointing at
   the real project; no `origin` yet (see above).

2. **Baked-in default search = AdaDo/MAGPIE, at build/source time (not just
   runtime policy)**: `patches/extra/adado-branding/default-search-adado.patch`.
   Built by taking the *already-upstream-accepted* patch
   `patches/core/ungoogled-chromium/replace-google-search-engine-with-nosearch.patch`
   (which is the real, tested mechanism ungoogled-chromium itself uses to
   neutralize the `google` entry in
   `third_party/search_engines_data/resources/definitions/prepopulated_engines.json`)
   and extending it one step further: instead of "No Search", the entry
   becomes `"AdaDo Search"` / keyword `adado` / `search_url` =
   `http://localhost:6475/search?q={searchTerms}` — the exact same MAGPIE
   endpoint already runtime-verified working in `../adado-browser/policies/managed_policies.json`
   (`DefaultSearchProviderSearchURL`), now applied as a real source patch
   instead of only a runtime override.
   Added to `patches/series` (line 112, after the core nosearch patch so it
   applies second, on top of it).

   **Self-tested** (no full Chromium checkout available in this sandboxed
   session, so tested the honest way — reconstruct the *exact* post-nosearch-patch
   file content from the nosearch patch's own diff hunk, since that's the
   verbatim state our patch must apply against):
   ```
   $ git apply -p1 --check --unsafe-paths \
       --directory=.selftest \
       patches/extra/adado-branding/default-search-adado.patch
   (exit 0, no output = applies cleanly)
   ```
   Reconstructed fixture + real applied result committed under
   `.selftest/` for inspection/re-running.

3. **`devutils/validate_config.py` — ungoogled-chromium's OWN real
   sanity-checker — passes clean on our fork** (checks patch readability,
   series duplicates/unused patches, GN flag sort/dupes, downloads.ini
   schema): exit code 0, no warnings, confirmed via subprocess capture.

4. **Repeatable build pipeline**: `tools/build-adado-browser.sh`, a direct
   transcription of `docs/building.md`'s real 6-step recipe (retrieve/unpack
   pinned Chromium source, prune, apply patches, domain-substitute, gn gen,
   ninja build), parameterized for `$BUILD_ROOT`/`$JOBS`, `bash -n` syntax
   checked (exit 0).

## Honest gap: no compiled binary from this fork yet

This build session is sandboxed to `/home/ada/adado-engine`,
`/home/ada/scripts`, `/home/ada/adado-cli` and adabox's `/` has 56GB free.
A real ungoogled-chromium build needs a ~30GB source checkout plus
~100-150GB of build output (`out/Default/`) — it cannot fit in the space
available to this session, and attempting a partial `gclient`/`downloads.py`
fetch that fills the remaining disk on a shared production box is
irresponsible to start without a dedicated build volume. This is exactly
the "BUILD INFRA... decide the build host" cost the ticket itself calls out
as "the bulk of the work, and why it's a project not a task."

**Filed as ADADO-671's concrete follow-on** (youdo.py grant request): Dan
needs to decide/provision a build host with >=200GB free disk (a dedicated
volume on adabox, or a separate builder VM) before `tools/build-adado-browser.sh`
can be run to completion and produce the "ONE clean branded build" the
ticket asks for as the starting bar. Until then, this fork + branding patch
+ pipeline is the real, verified, non-padded first slice of ADADO-671 —
not a rebuild of the already-done 644/653/665/805/814/815 policy-compose
work, and not a claim that a binary was produced when it wasn't.

## Also identified, not yet patched (needs real source to author safely)

Product-name/icon/about-page branding (ticket also asks for "name 'AdaDo
Browser', AdaDo icon/splash, about page") requires patching Chromium's
`chrome/app/theme/<brand>/BRANDING` file + `branding_path_component` GN
default + new icon assets under `chrome/app/theme/<brand>/`. This is the
real, standard mechanism (used by every other rebranded Chromium fork), but
authoring the exact diff hunks against files we don't have checked out
would be guessing at content we can't apply-test — unlike the search-engine
patch above, which we could reconstruct and self-test from another patch
already in this exact repo. Left as an explicit next step once a real
Chromium checkout exists on a properly provisioned build host, rather than
committing an unverified patch.
