# Reproducible environment for the suede test suite.
#   Build (from repo root):  docker build -f .tests/Dockerfile -t suede-tests .
#   Run:                      docker run --rm suede-tests
# The container provides git + curl + git-subrepo + a git identity — everything
# the harness and the local-chain fixture need.
FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl && rm -rf /var/lib/apt/lists/*

# git-subrepo: required by the local-chain fixture, upstream.sh, and the sync.
# Pin to the version your actions install so local == CI == production.
RUN git clone --quiet --branch 0.4.9 --depth 1 \
      https://github.com/ingydotnet/git-subrepo /opt/git-subrepo
ENV PATH="/opt/git-subrepo/lib:${PATH}" GITSUBREPO=/opt/git-subrepo

# A git identity (subrepo + commits need one) and safe.directory so a COPYed or
# mounted repo isn't rejected for "dubious ownership".
RUN git config --global user.name  "suede-test" \
      && git config --global user.email "suede-test@example.com" \
      && git config --global init.defaultBranch main \
      && git config --global --add safe.directory '*'

WORKDIR /repo
# Only what the suite needs: the harness/tests and the scripts under test.
# Keeping this narrow means edits to unrelated files don't bust the build cache,
# and the baked image stays small. The default `run.sh` invocation mounts the
# working tree over /repo anyway; this COPY is what `--baked` runs against.
COPY .tests/harness /repo/.tests/harness
COPY scripts /repo/scripts
CMD ["bash", ".tests/harness/run-all.sh"]
