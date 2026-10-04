# Watching for SSH. Every script that reaches a remote tries the SSH spelling
# first unless told --https; these let a test prove which happened.
#
#   https_only_remote <bare> <owner/name>   https://example.test/<owner/name>.git
#                                            reaches <bare>; the SSH spelling
#                                            git@example.test:<owner/name>.git
#                                            reaches nothing
#   forget_https_only_remote
#   ssh_spy_start                            every ssh call is logged and fails
#   ssh_spy_calls                            how many there were
#   ssh_spy_stop
#
# Written for bash 3.2 too: the installer and deps.sh tests run on macOS.

https_only_remote() { # <bare> <owner/name>
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="url.$1.insteadOf"
  export GIT_CONFIG_VALUE_0="https://example.test/$2.git"
}
forget_https_only_remote() { unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0; }

SSH_SPY_DIR=""
ssh_spy_start() {
  SSH_SPY_DIR="$(mktemp -d)"
  : > "$SSH_SPY_DIR/calls"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/calls"\nexit 255\n' "$SSH_SPY_DIR" > "$SSH_SPY_DIR/ssh"
  chmod +x "$SSH_SPY_DIR/ssh"
  # The scripts only set GIT_SSH_COMMAND when it is unset, so this one wins.
  export GIT_SSH_COMMAND="$SSH_SPY_DIR/ssh"
}
ssh_spy_calls() { wc -l < "$SSH_SPY_DIR/calls" | tr -d ' '; }
ssh_spy_stop() { unset GIT_SSH_COMMAND; [[ -n "$SSH_SPY_DIR" ]] && rm -rf "$SSH_SPY_DIR"; SSH_SPY_DIR=""; }

assert_no_ssh() { # <label>
  if [[ "$(ssh_spy_calls)" == 0 ]]; then log_pass "$1"; return 0; fi
  log_failure "$1 (ssh was called $(ssh_spy_calls) time(s): $(head -1 "$SSH_SPY_DIR/calls"))"; return 1
}
assert_ssh_tried() { # <label>
  if [[ "$(ssh_spy_calls)" -gt 0 ]]; then log_pass "$1"; return 0; fi
  log_failure "$1 (ssh was never called)"; return 1
}
