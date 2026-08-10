# Reproducible environment for the suede test suite.
#   Build (from repo root):  docker build -f .tests/Dockerfile -t suede-tests .
#   Run:                      docker run --rm suede-tests
#
# Pinned to Python 3.9 on purpose: that is the floor the installer supports
# (macOS Command Line Tools ship 3.9.6), and a suite that passes on the floor
# passes above it. The version matrix in CI covers the other interpreters; this
# image is about everything else being identical every time.
# BASE_IMAGE exists so an environment with its own registry mirror or TLS
# interception can substitute an equivalent base without editing this file.
ARG PYTHON_VERSION=3.9
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-bookworm
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl && rm -rf /var/lib/apt/lists/*

# git-subrepo: required by the local-chain fixture, upstream.sh and the release
# sync. Pinned to the version the actions install, so local == CI == production.
# Override to test against an unreleased git-subrepo:
#   docker build --build-arg GIT_SUBREPO_REF=main ...
ARG GIT_SUBREPO_REF=0.4.9
RUN git clone --quiet --branch "${GIT_SUBREPO_REF}" --depth 1 \
      https://github.com/ingydotnet/git-subrepo /opt/git-subrepo
ENV PATH="/opt/git-subrepo/lib:${PATH}" GITSUBREPO=/opt/git-subrepo

# A git identity (subrepo + commits need one) and safe.directory so a COPYed or
# mounted repo isn't rejected for "dubious ownership".
#
# --system, not --global: run.sh runs the container as the host user so results
# come back owned by whoever ran it, and a $HOME-scoped identity would be
# invisible to that user.
RUN git config --system user.name  "suede-test" \
      && git config --system user.email "suede-test@example.com" \
      && git config --system init.defaultBranch main \
      && git config --system --add safe.directory '*'

WORKDIR /repo
# Only what the suite needs, so edits to docs or the worker don't bust the
# build cache. `dependency/` is here because the release-flow scripts and the
# guard that keeps them out of what ships both live under it.
COPY .tests /repo/.tests
COPY scripts /repo/scripts
COPY dependency /repo/dependency
CMD ["bash", ".tests/harness/run-all.sh"]
