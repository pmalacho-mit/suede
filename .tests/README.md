# Test suite

Three suites, cheapest first. The rule: **push every assertion to the cheapest
layer that can hold it.** Anything provable against a literal `World` must not
be tested with a git repository.

| Suite | What it holds | Run |
| --- | --- | --- |
| `unit/` | The planner and `check`, pure over literal `World`s — no repos, no network, no fixtures | `python3 -m unittest discover .tests/unit -t .tests/unit` |
| `integration/` | That the tree suede writes is the tree it planned, against generated local repos | `python3 -m unittest discover .tests/integration -t .tests/integration` |
| colocated `**/.tests/*.sh` | The shell surface: bootstrap argument translation, the v1 scripts | `bash .tests/harness/run-all.sh` |

`fixtures/make_graph.py` builds a graph of local bare repos from a small spec,
each with a real `release` branch and `.suede/.dependencies/`, so integration
tests exercise the actual manifest format rather than a mock of it.

`unit/test_purity.py` replaces the git layer with an object that raises on any
use, so the pure boundary fails loudly if it ever leaks. That boundary is the
reason the scenario matrix stays cheap.

The shell suite below is unchanged.


Colocated tests (`**/.tests/*.sh`, where `.tests` is the immediate parent) are
discovered and run by `.tests/harness/run-all.sh` on top of the shared harness
in `.tests/harness/`.

One placement rule: anything under `dependency/` that contains a `.gitrepo` is
vendored into every consumer, so tests for those scripts live in the unshipped
parent — `dependency/main/.tests/` covers `dependency/main/core/`. They are
discovered exactly like any other colocated suite; they just do not ship. The whole suite is **offline and deterministic** — no
GitHub, no network.

## Run everything in a container (recommended)
```
.tests/run.sh                    # run the whole suite
.tests/run.sh --verbose          # full output for every test
.tests/run.sh push-release.sh ...  # run only the named test file(s)
```
`run.sh` builds `.tests/Dockerfile` (git + curl + git-subrepo + identity) and
runs the suite with `--network none`, so the run is provably hermetic; its exit
code mirrors the suite. All arguments are forwarded to `run-all.sh` inside the
container.

The suite always runs against the image's own baked-in copy of the files (what
`.tests/Dockerfile` `COPY`s in), never a live mount of the working tree. The
image is rebuilt every run, so that copy reflects your current files — it's
simpler and provably self-contained.

The suite writes its results to `.tests/.last-run/` (gitignored): a
`transcript.log` plus one `<test>.log` per file, all plain text. `run.sh` prints
the transcript **after** the container exits and treats that file as the source
of truth — Docker can silently drop a container's final buffered stdout on exit
(no TTY), so the streamed output is never relied upon.

> The image *build* fetches git-subrepo once over the network; the test *run*
> needs none. Vendor git-subrepo into the repo if you want an air-gapped build too.

## Run directly (if git-subrepo is on PATH)
```
bash .tests/harness/run-all.sh           # all tests
bash .tests/harness/run-all.sh --verbose push-release.sh
```

## The report
One pass/fail line per test file (with a passed/total count) plus a summary box
(Total / Passed / Failed and the names of any failures); non-zero exit on
failure, so CI fails automatically.

## Harness
- `runner.sh` — `run_test_suite [--setup fn] [--cleanup fn] fn...`
- `color-logging.sh` — `log_pass` / `log_failure` / ...
- `mock-curl.sh` — redirect a hosted URL to a local file for `bash <(curl ...)`
- `normalize.sh` — `strip_cr`
- `with-single-example-txt-file.sh` — fixture using a real read-only remote branch
- `with-local-suede-chain.sh` — builds the whole topology on LOCAL bare repos,
  and (for the GitHub-fetching scripts) a `file://` mirror of the GitHub REST
  surface plus a 2-commit source repo

## Tier C - the forge

`actions/` boots Gitea plus an `act_runner` in Docker, so the two flows that are
fundamentally cross-repository (push to `main` syncs `release`; a `subrepo push`
into `release` opens a PR into `main`) can be exercised offline:

```
.tests/actions/bootstrap.sh      # boot the forge, seed repos, register a runner
.tests/actions/scenarios.sh      # trigger and assert
.tests/actions/bootstrap.sh --down
```

It needs a Docker daemon in this container. Everything a forge is *not* needed
for - extraction, the divergence guard, `check`, the PR description - is
covered above at a fraction of the cost, so keep it that way: add to Tier C
only what genuinely needs a trigger, a permission or a token to be real.
