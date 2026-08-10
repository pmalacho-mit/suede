#!/usr/bin/env bash
# Build the test image and run the full suite inside it.
# Exit code mirrors the suite (0 = all passed), so it drops into CI directly.
#
#   .tests/run.sh                 # run the whole suite
#   .tests/run.sh --verbose       # full output for every test
#   .tests/run.sh push-release.sh # run only the named test file(s)
#
# SUEDE_GIT_SUBREPO_REF pins the git-subrepo the image builds with (default
# 0.4.9); CI also runs it against `main` so a change in git-subrepo's
# assumptions fails here rather than silently downstream.
#
# SUEDE_TEST_BASE_IMAGE substitutes the base image. Needed where the build
# cannot reach the public registry directly — a mirror, an air-gapped host, or
# a development environment that intercepts TLS and needs its CA in the base.
#
# All arguments are forwarded to the in-container runner
# (.tests/harness/run-all.sh).
#
# The suite always runs against the snapshot baked into the image (the files
# COPYed in by .tests/Dockerfile) — never a live mount of the working tree.
# The image is rebuilt every run, so that snapshot already reflects your current
# files; this is simpler to reason about and provably self-contained (a clean
# build either has everything it needs or it doesn't).
#
# Output delivery: the suite writes its results into .tests/.last-run/ (shared
# with the container) and this script prints the transcript AFTER the container
# exits. Docker can silently drop a container's final buffered stdout when
# PID 1 exits without a TTY, so the transcript FILE — not the streamed stdout —
# is the source of truth. The results dir lives under the repo because that is a
# host path Docker shares into the container.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${SUEDE_TEST_IMAGE:-suede-tests}"

BUILD_ARGS=(--build-arg "GIT_SUBREPO_REF=${SUEDE_GIT_SUBREPO_REF:-0.4.9}")
[[ -n "${SUEDE_TEST_BASE_IMAGE:-}" ]] && BUILD_ARGS+=(--build-arg "BASE_IMAGE=$SUEDE_TEST_BASE_IMAGE")

docker build -f "$ROOT/.tests/Dockerfile" "${BUILD_ARGS[@]}" -t "$IMAGE" "$ROOT"

# Results land here (gitignored). Cleared each run; left afterwards so per-test
# logs can be inspected.
RESULTS_HOST="$ROOT/.tests/.last-run"
rm -rf "$RESULTS_HOST"
mkdir -p "$RESULTS_HOST"

# Pass the full command so forwarded flags reach run-all.sh (a bare
# `docker run IMAGE <args>` would replace the CMD instead of appending to it).
# The container's own stdout is discarded — the transcript file is authoritative.
# --user so the logs land owned by whoever ran this rather than by root, which
# would make the next run's cleanup fail. HOME is redirected because that
# user has none inside the image; the git identity is --system for the same
# reason.
status=0
docker run --rm --network none \
  --user "$(id -u):$(id -g)" \
  -e "HOME=/tmp" \
  -e "SUEDE_TEST_VERBOSE=${SUEDE_TEST_VERBOSE:-0}" \
  -e "SUEDE_TEST_LOGDIR=/results" \
  -v "$RESULTS_HOST:/results" \
  "$IMAGE" bash .tests/harness/run-all.sh "$@" >/dev/null 2>&1 || status=$?

if [[ -s "$RESULTS_HOST/transcript.log" ]]; then
  cat "$RESULTS_HOST/transcript.log"
else
  echo "No transcript produced; the suite failed before writing results (exit $status)." >&2
  [[ $status -eq 0 ]] && status=1
fi

exit "$status"
