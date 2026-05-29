#!/usr/bin/env bash
# Build the test image and run the full suite inside it.
# Exit code mirrors the suite (0 = all passed), so it drops into CI directly.
#
#   .tests/run.sh                 # run the whole suite
#   .tests/run.sh --verbose       # full output for every test
#   .tests/run.sh degit.sh ...    # run only the named test file(s)
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

docker build -f "$ROOT/.tests/Dockerfile" -t "$IMAGE" "$ROOT"

# Results land here (gitignored). Cleared each run; left afterwards so per-test
# logs can be inspected.
RESULTS_HOST="$ROOT/.tests/.last-run"
rm -rf "$RESULTS_HOST"
mkdir -p "$RESULTS_HOST"

# Pass the full command so forwarded flags reach run-all.sh (a bare
# `docker run IMAGE <args>` would replace the CMD instead of appending to it).
# The container's own stdout is discarded — the transcript file is authoritative.
status=0
docker run --rm --network none \
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
