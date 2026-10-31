#!/usr/bin/env nu

# Rex orchestration only: the real work lives in the inner script.
#
# Failure policy: the script runs in a keep-open terminal block in the named
# session. On failure, the window stays in the session (frozen, labelled with
# the date).
# On success the window is closed, and the session is destroyed if that
# was its last window.

# Configuration
const session_label = "backups"
const window_label_prefix = "backup"
const inner_script = "~/..." | path expand

# Rex wrappers
def session-exists [label: string]: nothing -> bool {
  rex ls --json
  | from json
  | get sessions
  | where label == $label
  | is-not-empty
}

# Get the ID of the session with this label, creating an empty session first
# if it doesn't exist.
def ensure-session [label: string]: nothing -> string {
  if not (session-exists $label) {
    rex api call session.create ({label: $label} | to json --raw) | ignore
  }

  rex ls --json
  | from json
  | get sessions
  | where label == $label
  | get 0.session_id
}

# Run the inner script in a keep-open terminal block in a new window of the
# session.
def start-backup [session_id: string, command: string]: nothing -> record<block_id: string, window_id: string> {
  let stamp = date now | format date "%F %R"

  let created = rex run -s $session_id --json --keep-open --focus=false -- $command
  | from json

  # `rex run`'s --label names the block
  rex api call -s $session_id session.set_window_label (
    { window_id: $created.window_id, label: $"($window_label_prefix) ($stamp)" } | to json --raw
  ) | ignore

  {
    block_id: ($created.block_ids.0)
    window_id: $created.window_id
  }
}

# Wait for the block's program to exit and returns the child's result.
def wait-for-exit [session_id: string, block_id: string]: nothing -> record<exit_code: int, stdout: string, stderr: string> {
  rex wait -s $session_id $block_id | complete
}

# Close a block (and its window) and the session if that was its last block.
def close-session [session_id: string, block_id: string]: nothing -> nothing {
  rex block close -s $session_id $block_id | ignore

  let blocks = rex block ls --json -s $session_id | from json | get blocks
  if ($blocks | is-empty) {
    rex kill $session_id | ignore
  }
}

def main []: nothing -> nothing {
  let session_id = (ensure-session $session_label)
  let backup = (start-backup $session_id $inner_script)
  let wait = (wait-for-exit $session_id $backup.block_id)

  if $wait.exit_code == 0 {
    close-session $session_id $backup.block_id
  } else {
    print -e $"backup failed: child exited with status ($wait.exit_code) - window kept in the '($session_label)' session"
    print -e $wait.stderr
    exit $wait.exit_code
  }
}
