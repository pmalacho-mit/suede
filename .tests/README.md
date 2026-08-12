# Test suite

Layers, cheapest first. The rule: **push every assertion to the cheapest layer
that can hold it.** Anything provable against a literal `World` must not be
tested with a git repository.

| Layer | What it holds |
| --- | --- |
| `unit/` | The planner and `check`, pure over literal `World`s — no repos, no network, no fixtures |
| `integration/` | That the tree suede writes is the tree it planned, against generated local repos |
| colocated `**/.tests/*.sh` | The shell surface: the bootstrap's argument translation, the release-flow scripts, the publish guard |
| `actions/` | Tier C — what needs a real forge, run offline against Gitea |

**One command runs the first three.** `scripts/.tests/suede-unit.sh` and
`suede-integration.sh` are thin wrappers that hand the Python suites to the
same orchestrator, so `run-all.sh` reports every layer in one transcript with
one summary. A suite you have to remember to run separately is a suite that
stops being run.

`fixtures/make_graph.py` builds a graph of local bare repos from a small spec,
each with a real `release` branch and `.suede/.dependencies/`, so integration
tests exercise the actual manifest format rather than a mock of it.

`unit/test_purity.py` replaces the git layer with an object that raises on any
use, so the pure boundary fails loudly if it ever leaks. That boundary is the
reason the scenario matrix stays cheap.

`integration/test_subrepo.py` is the one suite that runs **git-subrepo itself**,
against a tree suede installed. An install hand-writes its `.gitrepo` instead of
going through `git subrepo clone`, and every other assertion here is about the
tree suede writes — all of them would stay green if git-subrepo changed what it
expects of that tree. It skips when git-subrepo is absent, which is why CI runs
the suite against a pinned version and against `main`.

Colocated tests are discovered by `.tests/harness/run-all.sh`: any `*.sh` whose
immediate parent is a `.tests/` directory. One placement rule — anything under
`dependency/` holding a `.gitrepo` is vendored into every consumer, so tests
for those scripts live in the unshipped parent (`dependency/main/.tests/`
covers `dependency/main/core/`). `shipped-content.sh` fails the build if a test
directory reappears inside a subrepo.

The whole suite is **offline and deterministic** — no GitHub, no network.

## Run everything in a container (recommended)
```
.tests/run.sh                     # unit + integration + shell, all of it
.tests/run.sh --verbose           # full output for every test
.tests/run.sh push-release.sh ... # run only the named test file(s)
```
`run.sh` builds `.tests/Dockerfile` and runs the suite with `--network none`,
so the run is provably hermetic; its exit code mirrors the suite. All arguments
are forwarded to `run-all.sh` inside the container.

The image pins **Python 3.9** — the floor the installer supports, and what
macOS Command Line Tools ship — plus **git-subrepo 0.4.9**, the version the
actions install. A suite that passes on the floor passes above it; the version
matrix in CI covers the other interpreters.

| Variable | For |
| --- | --- |
| `SUEDE_GIT_SUBREPO_REF` | build against another git-subrepo (CI also runs `main`) |
| `SUEDE_TEST_BASE_IMAGE` | substitute the base image where the build cannot reach the public registry — a mirror, an air-gapped host, or a dev environment that intercepts TLS and needs its CA in the base |
| `SUEDE_TEST_IMAGE` | name the built image something else |

The container runs as **your** user, so `.tests/.last-run/` comes back readable
and the next run can clean it up. The suite always runs against the snapshot
baked into the image, never a live mount; the image is rebuilt every run, so
that snapshot reflects your current files.

The suite writes its results to `.tests/.last-run/` (gitignored): a
`transcript.log` plus one `<test>.log` per file, all plain text. `run.sh` prints
the transcript **after** the container exits and treats that file as the source
of truth — Docker can silently drop a container's final buffered stdout on exit
(no TTY), so the streamed output is never relied upon.

> The image *build* fetches git-subrepo once over the network; the test *run*
> needs none.

### When the build cannot reach the network

The build's one network step is the `git clone` of git-subrepo, and it fails
like this behind a TLS-intercepting proxy:

```
fatal: unable to access 'https://github.com/ingydotnet/git-subrepo/':
       server certificate verification failed. CAfile: none CRLfile: none
```

The tell is that the *same* clone works in your shell and fails in the build: a
container trusts CAs from its own image, so a host that has the interceptor's CA
installed succeeds where a stock base image cannot. Confirm which one you have
with `openssl s_client -connect github.com:443 </dev/null | openssl x509 -noout
-issuer` — an issuer that is not a public CA is an interceptor.

If your devcontainer ships `/desolate-ca/trust-proxy-in-builds.sh`, it solves
exactly this. Shadowing the tag is the mode that fits, because `run.sh` calls
`docker build` directly and so has nowhere to accept a build-context override:

```
/desolate-ca/trust-proxy-in-builds.sh --image python:3.9-slim-bookworm --shadow
.tests/run.sh                                    # then this, unchanged
```

Name the tag `.tests/Dockerfile` actually resolves — the `BASE_IMAGE` default,
`python:3.9-slim-bookworm`. Every `FROM` of it in that daemon then gets a
CA-trusting derivative; `--unshadow` puts the original back, and a `docker pull`
of the base silently undoes it.

Anywhere else, build a base carrying your CA and point `SUEDE_TEST_BASE_IMAGE`
at it. That is the same fix delivered by hand.

## Run directly (if your shell has the tools)
```
bash .tests/harness/run-all.sh           # all tests
bash .tests/harness/run-all.sh --verbose suede-unit.sh
```
The orchestrator checks for `git`, `python3 >= 3.9` and `git-subrepo` before it
starts and names anything missing, rather than letting half the run fail with
`git: 'subrepo' is not a git command`. If something is missing, the container
above is the supported answer.

The Python suites can also be run on their own — they need nothing but a
stdlib `python3` (plus git-subrepo, if you want `test_subrepo.py` to run rather
than skip):
```
python3 -m unittest discover .tests/unit -t .tests/unit
python3 -m unittest discover .tests/integration -t .tests/integration
```

## What CI runs

[`.github/workflows/test.yml`](../.github/workflows/test.yml) supplies
interpreters and git-subrepo versions and nothing else, so a green run there and
a green run here mean the same thing. Three jobs:

| Job | Covers |
| --- | --- |
| `python` | `py_compile`, then both Python suites on 3.9–3.13 × ubuntu + macOS |
| `shell` | `run-all.sh` — every layer, through the orchestrator, on Linux |
| `git-subrepo-main` | the same against unreleased git-subrepo; `continue-on-error` |

macOS is not decoration: it is the only runner that catches a case-insensitive
collision between two entry names, and it is what sets the 3.9 floor. The
`shell` job is Linux-only because the harness wants bash 4 and macOS ships 3.2.

Tier C is not wired into CI — it needs a Docker daemon and a forge, and it is
run by hand.

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

`actions/` boots Gitea plus an `act_runner` in Docker, so the flows that are
fundamentally cross-repository can be exercised offline:

```
.tests/actions/bootstrap.sh      # boot the forge, seed repos, register a runner
.tests/actions/scenarios.sh      # trigger and assert
.tests/actions/bootstrap.sh --down
```

`scenarios.sh` covers the push-to-`release` flow today: a push to `main` syncs
the `release` branch, and a diverged release dependency stops the publish and
leaves `release` where it was. The other cross-repository flow — a `subrepo
push` into `release` reverting and opening a PR into `main` — has the harness
but not yet the scenario; its pieces are covered at Layer 2 by
`dependency/main/.tests/`.

It needs a Docker daemon in this container. Everything a forge is *not* needed
for - extraction, the divergence guard, `check`, the PR description - is
covered above at a fraction of the cost, so keep it that way: add to Tier C
only what genuinely needs a trigger, a permission or a token to be real.
