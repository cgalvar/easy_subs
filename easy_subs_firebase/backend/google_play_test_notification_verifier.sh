#!/bin/bash

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$DIR/.deploy_state"
FUNCTION_NAME="${FUNCTION_NAME:-easySubs-googlePubSubHandler}"
LOG_LINES="${LOG_LINES:-80}"
PROJECT_ID="${PROJECT_ID:-}"
NON_INTERACTIVE="false"
WAIT_SECONDS="${WAIT_SECONDS:-30}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-3}"
FIREBASE_AUTH_FLAGS=()

if [ -n "${FIREBASE_TOKEN:-}" ]; then
  FIREBASE_AUTH_FLAGS+=(--token "$FIREBASE_TOKEN")
fi

print_error() {
  echo "❌ $1"
}

print_warning() {
  echo "⚠️ $1"
}

print_success() {
  echo "✅ $1"
}

usage() {
  cat <<EOF
Usage: ./google_play_test_notification_verifier.sh [project_id] [log_lines] [--non-interactive]

Interactive example:
  ./google_play_test_notification_verifier.sh cerebyte-ed47f

Compatibility / non-interactive example:
  ./google_play_test_notification_verifier.sh cerebyte-ed47f 80 --non-interactive

Environment overrides:
  PROJECT_ID=<firebase-project-id>
  LOG_LINES=<number-of-log-lines>
  FUNCTION_NAME=<firebase-function-name>
  WAIT_SECONDS=<seconds-to-wait-for-new-logs>
  POLL_INTERVAL_SECONDS=<seconds-between-log-checks>
  FIREBASE_TOKEN=<token-for-non-interactive-use>
EOF
}

parse_args() {
  local positional=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --non-interactive)
        NON_INTERACTIVE="true"
        shift
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [ -z "$PROJECT_ID" ] && [ "${#positional[@]}" -ge 1 ]; then
    PROJECT_ID="${positional[0]}"
  fi

  if [ "${#positional[@]}" -ge 2 ]; then
    LOG_LINES="${positional[1]}"
  fi
}

load_project_id() {
  if [ -z "$PROJECT_ID" ] && [ -f "$STATE_FILE" ]; then
    PROJECT_ID="$(grep -E '^PROJECT_ID=' "$STATE_FILE" | sed 's/^PROJECT_ID=//' || true)"
  fi
}

validate_inputs() {
  if [ -z "$PROJECT_ID" ]; then
    print_error "Could not determine PROJECT_ID. Pass it as the first argument or set PROJECT_ID."
    usage
    exit 1
  fi

  if ! command -v firebase > /dev/null 2>&1; then
    print_error "Firebase CLI is not installed. Install it with: npm install -g firebase-tools"
    exit 1
  fi

  if ! [[ "$LOG_LINES" =~ ^[0-9]+$ ]]; then
    print_error "LOG_LINES must be a positive integer."
    exit 1
  fi

  if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    print_error "WAIT_SECONDS must be a positive integer."
    exit 1
  fi

  if ! [[ "$POLL_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [ "$POLL_INTERVAL_SECONDS" -le 0 ]; then
    print_error "POLL_INTERVAL_SECONDS must be a positive integer greater than zero."
    exit 1
  fi
}

build_log_command() {
  LOG_COMMAND=(firebase functions:log --only "$FUNCTION_NAME" --project "$PROJECT_ID" -n "$LOG_LINES")

  if [ "${#FIREBASE_AUTH_FLAGS[@]}" -gt 0 ]; then
    LOG_COMMAND+=("${FIREBASE_AUTH_FLAGS[@]}")
  fi
}

filter_logs_after_marker() {
  local marker="$1"

  if [ -z "$marker" ]; then
    printf '%s\n' "$RAW_LOG_OUTPUT"
    return
  fi

  printf '%s\n' "$RAW_LOG_OUTPUT" | awk -v marker="$marker" '
    NF == 0 { next }
    $1 >= marker { print }
  '
}

current_log_marker() {
  date -u +"%Y-%m-%dT%H:%M:%S.000000000Z"
}

read_logs() {
  build_log_command
  RAW_LOG_OUTPUT="$(${LOG_COMMAND[@]} 2>&1 || true)"

  if printf '%s' "$RAW_LOG_OUTPUT" | grep -qiE 'Authentication Error|Error: Failed to get Firebase project|Permission denied|Not authorized'; then
    print_error "Could not read Firebase logs. Check your Firebase session or project permissions."
    echo ""
    printf '%s\n' "$RAW_LOG_OUTPUT"
    exit 1
  fi

  FILTERED_LOG_OUTPUT="$(filter_logs_after_marker "${1:-}")"
}

wait_for_logs() {
  local marker="$1"
  local elapsed=0

  while true; do
    read_logs "$marker"

    if [ -n "$FILTERED_LOG_OUTPUT" ]; then
      return 0
    fi

    if [ "$elapsed" -ge "$WAIT_SECONDS" ]; then
      return 1
    fi

    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done
}

show_test_instructions() {
  echo "🧪 Google Play Test Notification Verifier"
  echo ""
  echo "Project: $PROJECT_ID"
  echo "Function: $FUNCTION_NAME"
  echo ""
  echo "Send the test notification from this location:"
  echo "1) Google Play Console"
  echo "2) Monetization setup"
  echo "3) Real-time developer notifications"
  echo "4) Confirm the topic is: projects/$PROJECT_ID/topics/play-billing"
  echo "5) Click 'Send test notification'"
  echo ""
  read -r -p "Press Enter if you already sent the test notification... " _unused
}

evaluate_logs() {
  local output="$1"

  if [ -z "$output" ]; then
    print_error "No new RTDN logs were found after you confirmed the test notification."
    echo ""
    echo "What to check next:"
    echo "- Waited ${WAIT_SECONDS}s and no new logs appeared"
    echo "- Confirm the test notification was actually sent from Play Console"
    echo "- Confirm the topic is exactly projects/$PROJECT_ID/topics/play-billing"
    echo "- Retry once in case Firebase logs were delayed"
    return 1
  fi

  if printf '%s' "$output" | grep -q '\[easySubs\]\[googlePubSubHandler\] incoming' && \
     printf '%s' "$output" | grep -q '\[easySubs\]\[googlePubSubHandler\] missing purchaseToken, skipping'; then
    print_success "Todo correcto. Google Play test notification reached the backend successfully."
    return 0
  fi

  if printf '%s' "$output" | grep -q '\[easySubs\]\[googlePubSubHandler\] incoming' && \
     printf '%s' "$output" | grep -q '\[easySubs\]\[googlePubSubHandler\] updated subscription'; then
    print_success "Todo correcto. A real Google Play RTDN reached the backend and updated the subscription."
    return 0
  fi

  if printf '%s' "$output" | grep -q '\[easySubs\]\[googlePubSubHandler\] subscription not found for purchase token chain'; then
    print_warning "RTDN reached the backend, but the purchase token could not be matched yet."
    return 1
  fi

  if printf '%s' "$output" | grep -q '\[easySubs\]\[googlePubSubHandler\] unhandled error'; then
    print_error "RTDN reached the backend, but the handler threw an error."
    return 1
  fi

  print_error "No success pattern was found in the new logs after the test notification."
  return 1
}

main() {
  parse_args "$@"
  load_project_id
  validate_inputs

  local start_marker=""

  if [ "$NON_INTERACTIVE" = "false" ]; then
    start_marker="$(current_log_marker)"
    show_test_instructions
  fi

  if [ "$NON_INTERACTIVE" = "false" ]; then
    wait_for_logs "$start_marker" || true
  else
    read_logs "$start_marker"
  fi

  if [ "$NON_INTERACTIVE" = "false" ]; then
    echo ""
    echo "New logs detected after confirmation:"
    echo "------------------------------------------------------------"
    if [ -n "$FILTERED_LOG_OUTPUT" ]; then
      printf '%s\n' "$FILTERED_LOG_OUTPUT"
    else
      echo "(no new logs found)"
    fi
    echo "------------------------------------------------------------"
    echo ""
  fi

  evaluate_logs "$FILTERED_LOG_OUTPUT"
}

main "$@"