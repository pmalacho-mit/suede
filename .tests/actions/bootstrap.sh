#!/usr/bin/env bash
#
# Seed the local forge: an admin user, a PAT, two repositories, and a runner.
#
#   .tests/actions/bootstrap.sh          # bring it up and seed it
#   .tests/actions/bootstrap.sh --down   # tear it all down
#
# Everything below goes through the Gitea API, so the same calls the scenarios
# use to assert are the ones that set the world up. Writes the credentials the
# scenarios need to .tests/actions/.env (gitignored).
#
# Needs a Docker daemon in this container (the docker-in-docker feature).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

readonly GITEA="http://localhost:3000"
readonly ADMIN="suede-admin"
readonly PASSWORD="suede-admin-password-1"
readonly ORG="test-org"
readonly ENV_FILE="$HERE/.env"

say() { printf '[tier-c] %s\n' "$*" >&2; }
die() { printf '[tier-c] %s\n' "$*" >&2; exit 1; }

compose() { docker compose --project-directory "$HERE" -f "$HERE/docker-compose.yml" "$@"; }

api() {
  local method="$1" path="$2"
  shift 2
  curl -fsS -X "$method" -H "Content-Type: application/json" \
    -H "Authorization: token $TOKEN" "$GITEA/api/v1$path" "$@"
}

if [[ "${1-}" == "--down" ]]; then
  RUNNER_TOKEN=unused compose down --volumes --remove-orphans
  rm -f "$ENV_FILE"
  say "torn down"
  exit 0
fi

docker info >/dev/null 2>&1 || die "no Docker daemon (this needs the docker-in-docker feature)"

# Gitea first, alone: the runner cannot register until there is a registration
# token to register with, and only a running Gitea can mint one.
say "starting gitea"
RUNNER_TOKEN=placeholder compose up -d gitea

say "waiting for gitea to answer"
for _ in $(seq 1 60); do
  curl -fsS "$GITEA/api/healthz" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$GITEA/api/healthz" >/dev/null 2>&1 || die "gitea never became healthy"

say "creating the admin user"
compose exec -T -u git gitea gitea admin user create \
  --username "$ADMIN" --password "$PASSWORD" --email "$ADMIN@example.test" --admin \
  >/dev/null 2>&1 || say "admin already exists"

say "minting a token"
TOKEN="$(curl -fsS -X POST -H "Content-Type: application/json" \
  -u "$ADMIN:$PASSWORD" \
  -d '{"name":"suede-tier-c","scopes":["write:repository","write:user","write:admin","write:organization"]}' \
  "$GITEA/api/v1/users/$ADMIN/tokens" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha1"])')"
[[ -n "$TOKEN" ]] || die "could not mint a token"

say "creating $ORG and its repositories"
api POST /orgs -d "{\"username\":\"$ORG\"}" >/dev/null 2>&1 || say "$ORG already exists"
for repo in dep-lib consumer; do
  api POST "/orgs/$ORG/repos" -d "{\"name\":\"$repo\",\"auto_init\":false}" >/dev/null 2>&1 \
    || say "$repo already exists"
done

say "registering the runner"
REGISTRATION="$(api GET /admin/runners/registration-token | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
RUNNER_TOKEN="$REGISTRATION" compose up -d runner

say "waiting for the runner to appear"
for _ in $(seq 1 30); do
  api GET /admin/runners 2>/dev/null | grep -q suede-tier-c && break
  sleep 2
done

{
  printf 'GITEA_URL=%s\n' "$GITEA"
  printf 'GITEA_TOKEN=%s\n' "$TOKEN"
  printf 'GITEA_ORG=%s\n' "$ORG"
  printf 'GITEA_ADMIN=%s\n' "$ADMIN"
  printf 'GITEA_PASSWORD=%s\n' "$PASSWORD"
  printf 'SUEDE_ROOT=%s\n' "$ROOT"
} > "$ENV_FILE"

say "ready - credentials in $ENV_FILE"
say "run the scenarios with: bash $HERE/scenarios.sh"
