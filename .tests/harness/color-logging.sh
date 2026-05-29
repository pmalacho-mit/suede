RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NO_COLOR='\033[0m'

log_info() {
  printf "%b[INFO]%b %s\n" "$YELLOW" "$NO_COLOR" "$*"
}

log_success() {
  printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NO_COLOR" "$*"
}

log_pass() {
  printf "%b[PASS]%b %s\n" "$GREEN" "$NO_COLOR" "$*"
}

log_error() {
  printf "%b[ERROR]%b %s\n" "$RED" "$NO_COLOR" "$*"
}

log_failure() {
  printf "%b[FAIL]%b %s\n" "$RED" "$NO_COLOR" "$*"
}