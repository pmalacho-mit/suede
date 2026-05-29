#!/usr/bin/env bash
# Build the test image and run the full suite in a container.
# Exit code mirrors the suite (0 = all passed), so it drops into CI directly.
#
#   .tests/run.sh           # test your current working tree (repo mounted)
#   .tests/run.sh --baked   # test the snapshot COPYed into the image
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${SUEDE_TEST_IMAGE:-suede-tests}"

docker build -f "$ROOT/.tests/Dockerfile" -t "$IMAGE" "$ROOT"

if [[ "${1:-}" == "--baked" ]]; then
  exec docker run --rm --network none "$IMAGE"
fi
# Mount the working copy so edits don't require a rebuild (build only re-runs if
# the Dockerfile changes). chmod/tmp happen inside the container or /tmp.
exec docker run --rm --network none -v "$ROOT:/repo" "$IMAGE"
