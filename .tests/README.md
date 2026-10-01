# Test suite

Everything is bash and everything runs against **real local git repositories**:
bare remotes with a `release` branch carrying the real consumer-facing core
(`diff`, `deps.sh`) and real `.suede/.dependencies/` records, built by
[`harness/with-suede-graph.sh`](./harness/with-suede-graph.sh). No GitHub, no
network, no mocks of the manifest format.

| Where | What it covers |
| --- | --- |
| `scripts/.tests/install-release.sh` | the installer: the tree and `.gitrepo` it writes, and when it declares |
| `dependency/release/.tests/` | what ships inside a dependency: `deps.sh`, `diff`, `sync` |
| `dependency/main/.tests/` | the maintainer's tools: `extract.sh`/`list.sh`/`diff.sh`, the publish guard, the downstream PR flow, and `shipped-content.sh` |
| `scripts/actions/.tests/` | `init.sh`, `push-main.sh`, and the upstream round trip through every script |
| `scripts/.tests/`, `scripts/populate/.tests/` | this repository's own subrepo helpers and the README generator |
| `actions/` | Tier C — what needs a real forge, run offline against Gitea |

Colocated tests are discovered by `.tests/harness/run-all.sh`: any `*.sh` whose
immediate parent is a `.tests/` directory. One placement rule — anything under
`dependency/` holding a `.gitrepo` is vendored into every consumer, so tests for
those scripts live in the unshipped parent (`dependency/main/.tests/` covers
`dependency/main/core/`). `shipped-content.sh` fails the build if a test
directory reappears inside a subrepo, and if a shipped script is not named in
its folder's README.

**Two files have to run on bash 3.2** — `scripts/.tests/install-release.sh`
and `dependency/release/.tests/deps.sh` — because the scripts they test ship to
consumers on macOS. CI runs them there. No `declare -A`, no `mapfile`, no
`${var,,}` in those two or in the harness they share.

## Run everything in a container (recommended)
```
.tests/run.sh                     # all of it
.tests/run.sh --verbose           # full output for every test
.tests/run.sh deps.sh ...         # run only the named test file(s)
```
`run.sh` builds `.tests/Dockerfile` and runs the suite with `--network none`,
so the run is provably hermetic; its exit code mirrors the suite. All arguments
are forwarded to `run-all.sh` inside the container.

The image is Debian with `git`, `curl`, `jq` and **git-subrepo 0.4.9**, the
version the actions install.

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
installed succeeds where a stock base image cannot.

If your devcontainer ships `/desolate-ca/trust-proxy-in-builds.sh`, it solves
exactly this. Shadowing the tag is the mode that fits, because `run.sh` calls
`docker build` directly and so has nowhere to accept a build-context override:

```
/desolate-ca/trust-proxy-in-builds.sh --image debian:bookworm-slim --shadow
.tests/run.sh                                    # then this, unchanged
```

Name the tag `.tests/Dockerfile` actually resolves — the `BASE_IMAGE` default,
`debian:bookworm-slim`. `--unshadow` puts the original back, and a `docker pull`
of the base silently undoes it. Anywhere else, build a base carrying your CA and
point `SUEDE_TEST_BASE_IMAGE` at it.

## Run directly (if your shell has the tools)
```
bash .tests/harness/run-all.sh           # all tests
bash .tests/harness/run-all.sh --verbose deps.sh
bash dependency/release/.tests/deps.sh   # one file, no orchestrator
```
The orchestrator checks for `git` and `git-subrepo` before it starts and names
anything missing, rather than letting half the run fail with
`git: 'subrepo' is not a git command`. If something is missing, the container
above is the supported answer.

## What CI runs

[`.github/workflows/test.yml`](../.github/workflows/test.yml) supplies
git-subrepo and nothing else, so a green run there and a green run here mean
the same thing. Three jobs:

| Job | Covers |
| --- | --- |
| `shell` | `run-all.sh` — every layer, through the orchestrator, on Linux |
| `macos` | the installer and `deps.sh` tests on bash 3.2 |
| `git-subrepo-main` | `run-all.sh` against unreleased git-subrepo; `continue-on-error` |

Tier C is not wired into CI — it needs a Docker daemon and a forge, and it is
run by hand.

## Harness
- `runner.sh` — `run_test_suite [--setup fn] [--cleanup fn] fn...`. Each test
  function runs in its own subshell, so state a later test needs has to be on
  disk or computed in `setup`.
- `color-logging.sh` — `log_pass` / `log_failure` / ...
- `with-suede-graph.sh` — `graph_make_dep`, `graph_advance_dep`,
  `graph_make_project [--dependency]` and assertions: the dependency graph on
  local bare repos
- `with-local-suede-chain.sh` — the older fixture for the init / sync /
  upstream round trip: a seed remote, a consumer, and stand-ins for this
  library's `dependency/*` branches
- `mock-curl.sh` — redirect a hosted URL to a local file for `bash <(curl ...)`
  (bash 4 only)
- `normalize.sh` — `strip_cr`
- `with-single-example-txt-file.sh` — fixture using a real read-only remote branch

## Tier C - the forge

`actions/` boots Gitea plus an `act_runner` in Docker, so the flows that are
fundamentally cross-repository can be exercised offline:

```
.tests/actions/bootstrap.sh      # boot the forge, seed repos, register a runner
.tests/actions/scenarios.sh      # trigger and assert
.tests/actions/bootstrap.sh --down
```

`scenarios.sh` covers the push-to-`release` flow: a push to `main` syncs the
`release` branch, and a diverged release dependency stops the publish and
leaves `release` where it was. It needs a Docker daemon and `jq`. Everything a
forge is *not* needed for is covered above at a fraction of the cost, so keep it
that way: add to Tier C only what genuinely needs a trigger, a permission or a
token to be real.
