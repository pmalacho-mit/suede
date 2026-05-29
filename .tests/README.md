# Test suite

Colocated tests (`**/.tests/*.sh`, where `.tests` is the immediate parent) are
discovered and run by `.tests/scripts/find-and-run-all.sh` on top of the shared
harness in `.tests/harness/`. The whole suite is **offline and deterministic** —
no GitHub, no network.

## Run everything in a container (recommended)
```
.tests/scripts/run.sh            # tests your working tree (repo mounted)
.tests/scripts/run.sh --baked    # tests the snapshot copied into the image
```
`run.sh` builds `.tests/Dockerfile` (git + curl + git-subrepo + identity) and
runs the suite with `--network none`, so the run is provably hermetic; its exit
code mirrors the suite. CI does the same in `.github/workflows/test.yml`.

> The image *build* fetches git-subrepo once over the network; the test *run*
> needs none. Vendor git-subrepo into the repo if you want an air-gapped build too.

## Run directly (if git-subrepo is on PATH)
```
bash .tests/scripts/find-and-run-all.sh
```

## The report
A per-test pass/fail log plus a summary box (Total / Passed / Failed and the
names of any failures); non-zero exit on failure, so CI fails automatically.

## Harness
- `runner.sh` — `run_test_suite [--setup fn] [--cleanup fn] fn...`
- `color-logging.sh` — `log_pass` / `log_failure` / ...
- `mock-curl.sh` — redirect a hosted URL to a local file for `bash <(curl ...)`
- `normalize.sh` — `strip_cr`
- `with-single-example-txt-file.sh` — fixture using a real read-only remote branch
- `with-local-suede-chain.sh` — builds the whole topology on LOCAL bare repos,
  and (for the GitHub-fetching scripts) a `file://` mirror of the GitHub REST
  surface plus a 2-commit source repo

## How the GitHub-fetching scripts run offline
`degit.sh` and `install/gitrepo.sh` honor two origin overrides (default to real
GitHub, so production is unchanged — and they double as GitHub-Enterprise/mirror
support):
- `GITHUB_API_ORIGIN` — where degit fetches the tarball + commit checks
- `SUEDE_SCRIPT_BASE` — where install/gitrepo fetches its sibling scripts

The fixture points both at a local `file://` tree, so these tests use real
`curl`/`git`/`tar` against the filesystem — no network, but the same code paths.

## Opt-in live check (degit)
`scripts/utils/.tests/degit.sh` runs offline by default. Set `SUEDE_TEST_LIVE=1`
to instead fetch the real hosted commits from `github.com/pmalacho-mit/suede`,
which exercises actual HTTP (auth, redirects, rate limits). Pass `GITHUB_TOKEN`
to avoid rate limits. Keep this OFF in the hermetic `--network none` CI job; run
it as a separate, network-enabled step if you want it in CI:
```
SUEDE_TEST_LIVE=1 GITHUB_TOKEN=... bash scripts/utils/.tests/degit.sh
```
