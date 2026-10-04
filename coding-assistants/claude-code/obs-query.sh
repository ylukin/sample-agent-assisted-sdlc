#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# obs-query — run the CloudWatch Logs Insights queries from obs.md from the CLI.
#
# Takes the TUI command copied from the SDLC inspector (`agentcore exec --it
# --runtime <arn> --region <r> --session-id <id>`) and extracts the runtime
# ARN, region and session ID from it. The log group is derived from the
# runtime ID: /aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT.
#
# Prerequisites:
#   - AWS CLI v2, jq
#   - logs:StartQuery, logs:GetQueryResults on the runtime log group
#
# Usage:
#   obs-query.sh <query> [options] [--cmd "<TUI command>"]
#   pbpaste | obs-query.sh <query> [options]        # TUI command on stdin
#
# Queries (see obs.md for what each one means):
#   events        All events for one pipeline run
#   cost          Per-session cost rollup
#   tools         Tool usage
#   hooks         Hook decisions (PreToolUse blocks)
#   models        Models used + average latency
#   invocations   Separate `claude` invocations within the run (one user_prompt each)
#   subagents     Task tool subagent calls
#   complexity    SIMPLE (0) vs COMPLEX (>=1) heuristic
#   discover      Which log streams / session IDs hold claude_code events (troubleshooting)
#
# Options:
#   --cmd "<cmd>"      TUI command from the inspector (otherwise read from stdin)
#   --session <id>     Session ID (overrides the TUI command)
#   --runtime <arn>    Runtime ARN (overrides the TUI command)
#   --region <region>  Region (overrides the TUI command / ARN)
#   --since <dur>      Lookback window: 30m, 6h, 2d (default: 24h)
#   --stream <name>    OTel log stream (default: otel-rt-logs)
#   --all              cost/tools/hooks/models: query all sessions, not just this one
#   --json             Print raw get-query-results JSON
#   -h, --help         Show this help
#
# Examples:
#   obs-query.sh cost --cmd "agentcore exec --it --runtime arn:aws:... --region us-west-2 --session-id sdlc-..."
#   pbpaste | obs-query.sh events --since 2h
#   pbpaste | obs-query.sh tools --all --since 7d
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  sed -n '/^# Usage:/,/^# ═══/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die() { echo "error: $*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI not found"
command -v jq >/dev/null || die "jq not found"

[[ $# -ge 1 ]] || usage 1
case "$1" in -h|--help) usage 0 ;; esac
QUERY_NAME=$1; shift

TUI_CMD=""
SESSION=""
RUNTIME_ARN=""
REGION=""
SINCE="24h"
STREAM="otel-rt-logs"
ALL_SESSIONS=false
RAW_JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd)      TUI_CMD=${2:?--cmd needs a value}; shift 2 ;;
    --session)  SESSION=${2:?--session needs a value}; shift 2 ;;
    --runtime)  RUNTIME_ARN=${2:?--runtime needs a value}; shift 2 ;;
    --region)   REGION=${2:?--region needs a value}; shift 2 ;;
    --since)    SINCE=${2:?--since needs a value}; shift 2 ;;
    --stream)   STREAM=${2:?--stream needs a value}; shift 2 ;;
    --all)      ALL_SESSIONS=true; shift ;;
    --json)     RAW_JSON=true; shift ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown option: $1 (see --help)" ;;
  esac
done

# ─── Parse the TUI command ────────────────────────────────────────────────

if [[ -z $TUI_CMD && -z $RUNTIME_ARN && ! -t 0 ]]; then
  TUI_CMD=$(cat)
fi

# Flatten line continuations (`\` + newline) into one line of tokens.
TUI_CMD=$(printf '%s' "$TUI_CMD" | tr '\\\n\t' '   ')

# Prints the value following flag $1 in the TUI command, if present.
extract_flag() {
  printf '%s' "$TUI_CMD" | grep -oE -- "$1[[:space:]=]+[^[:space:]]+" | head -n1 \
    | sed -E "s/^$1[[:space:]=]+//; s/^[\"']//; s/[\"']\$//" || true
}

[[ -n $RUNTIME_ARN ]] || RUNTIME_ARN=$(extract_flag --runtime)
[[ -n $REGION ]]      || REGION=$(extract_flag --region)
[[ -n $SESSION ]]     || SESSION=$(extract_flag --session-id)

[[ -n $RUNTIME_ARN ]] || die "no runtime ARN — pass --cmd \"<TUI command>\", pipe it on stdin, or use --runtime"

ARN_RE='^arn:aws[a-z-]*:bedrock-agentcore:([a-z0-9-]+):[0-9]{12}:runtime/([A-Za-z0-9_-]+)$'
[[ $RUNTIME_ARN =~ $ARN_RE ]] || die "not a runtime ARN: $RUNTIME_ARN"
[[ -n $REGION ]] || REGION=${BASH_REMATCH[1]}
RUNTIME_ID=${BASH_REMATCH[2]}
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"

RUNTIME_ACCOUNT=$(cut -d: -f5 <<<"$RUNTIME_ARN")
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "no valid AWS credentials (aws sts get-caller-identity failed)"
[[ $CALLER_ACCOUNT == "$RUNTIME_ACCOUNT" ]] \
  || die "credentials are for account $CALLER_ACCOUNT but the runtime is in $RUNTIME_ACCOUNT — set AWS_PROFILE"

# The session ID is interpolated into the query string — restrict its charset.
if [[ -n $SESSION && ! $SESSION =~ ^[A-Za-z0-9_-]+$ ]]; then
  die "invalid session ID: $SESSION"
fi

[[ $STREAM =~ ^[A-Za-z0-9_./-]+$ ]] || die "invalid stream name: $STREAM"

case "$SINCE" in
  *m) SINCE_SECS=$(( ${SINCE%m} * 60 )) ;;
  *h) SINCE_SECS=$(( ${SINCE%h} * 3600 )) ;;
  *d) SINCE_SECS=$(( ${SINCE%d} * 86400 )) ;;
  *)  die "--since must look like 30m, 6h or 2d" ;;
esac

# ─── Queries (kept in sync with obs.md) ───────────────────────────────────

require_session() {
  [[ -n $SESSION ]] || die "query '$QUERY_NAME' needs a session ID (--session-id in the TUI command, or --session)"
}

# Session filter line for queries that run fleet-wide unless scoped.
optional_session_filter() {
  if [[ -n $SESSION && $ALL_SESSIONS == false ]]; then
    printf '| filter resource.attributes.session.id = "%s"\n' "$SESSION"
  fi
}

case "$QUERY_NAME" in
  events)
    require_session
    QUERY=$(cat <<EOF
fields @timestamp, body,
       attributes.model, attributes.cost_usd,
       attributes.input_tokens, attributes.output_tokens,
       attributes.duration_ms, attributes.prompt.id
| filter @logStream = "$STREAM"
| filter resource.attributes.session.id = "$SESSION"
| sort @timestamp asc
| limit 200
EOF
) ;;
  cost)
    QUERY=$(cat <<EOF
fields resource.attributes.session.id as session,
       attributes.cost_usd as cost,
       attributes.input_tokens as input_tok,
       attributes.output_tokens as output_tok
| filter @logStream = "$STREAM"
| filter body = "claude_code.api_request"
$(optional_session_filter)
| stats sum(cost)      as total_cost_usd,
        sum(input_tok) as input_tokens,
        sum(output_tok) as output_tokens,
        count()        as api_calls
        by session
| sort total_cost_usd desc
| limit 50
EOF
) ;;
  tools)
    QUERY=$(cat <<EOF
fields attributes.tool_name as tool
| filter @logStream = "$STREAM"
| filter body = "claude_code.tool_result"
$(optional_session_filter)
| stats count() as calls by tool
| sort calls desc
EOF
) ;;
  hooks)
    QUERY=$(cat <<EOF
fields @timestamp, attributes.tool_name, attributes.decision,
       attributes.source, resource.attributes.session.id as session
| filter @logStream = "$STREAM"
| filter body = "claude_code.tool_decision"
$(optional_session_filter)
| sort @timestamp desc
| limit 100
EOF
) ;;
  models)
    QUERY=$(cat <<EOF
fields attributes.model as model, attributes.duration_ms as ms
| filter @logStream = "$STREAM"
| filter body = "claude_code.api_request"
$(optional_session_filter)
| stats avg(ms) as avg_ms, count() as calls by model
| sort calls desc
EOF
) ;;
  invocations)
    require_session
    QUERY=$(cat <<EOF
fields @timestamp, attributes.prompt.id as prompt_id
| filter @logStream = "$STREAM"
| filter resource.attributes.session.id = "$SESSION"
| filter body = "claude_code.user_prompt"
| sort @timestamp asc
EOF
) ;;
  subagents)
    require_session
    QUERY=$(cat <<EOF
fields @timestamp, attributes.tool_name as tool,
       attributes.success as ok, attributes.duration_ms as ms
| filter @logStream = "$STREAM"
| filter body = "claude_code.tool_result"
| filter resource.attributes.session.id = "$SESSION"
| filter tool = "Agent"
| sort @timestamp asc
EOF
) ;;
  complexity)
    require_session
    QUERY=$(cat <<EOF
fields attributes.tool_name as tool
| filter @logStream = "$STREAM"
| filter body = "claude_code.tool_result"
| filter resource.attributes.session.id = "$SESSION"
| filter tool = "Agent"
| stats count() as subagent_calls
EOF
) ;;
  discover)
    QUERY=$(cat <<EOF
fields @logStream as stream, resource.attributes.session.id as session
| filter @message like "claude_code."
| stats count() as events, max(@timestamp) as last_seen by stream, session
| sort last_seen desc
| limit 50
EOF
) ;;
  *) die "unknown query: $QUERY_NAME (see --help)" ;;
esac

# Drop the blank line left behind when optional_session_filter prints nothing.
QUERY=$(printf '%s\n' "$QUERY" | sed '/^$/d')

# ─── Run ──────────────────────────────────────────────────────────────────

SCOPE=${SESSION:-"(none)"}
[[ $ALL_SESSIONS == true ]] && SCOPE="all sessions"
echo "query=$QUERY_NAME region=$REGION session=$SCOPE stream=$STREAM since=$SINCE" >&2
echo "log group: $LOG_GROUP" >&2

END=$(date +%s)
START=$(( END - SINCE_SECS ))

QID=$(aws logs start-query --region "$REGION" \
  --log-group-name "$LOG_GROUP" \
  --start-time "$START" --end-time "$END" \
  --query-string "$QUERY" \
  --query queryId --output text)

while :; do
  OUT=$(aws logs get-query-results --region "$REGION" --query-id "$QID")
  STATUS=$(jq -r .status <<<"$OUT")
  case "$STATUS" in
    Scheduled|Running) sleep 1 ;;
    Complete) break ;;
    *) die "query $QID ended with status $STATUS" ;;
  esac
done

jq -r '.statistics | "scanned \(.recordsScanned|floor) records, \((.bytesScanned/1048576*100|floor)/100) MB, matched \(.recordsMatched|floor)"' <<<"$OUT" >&2

if [[ $RAW_JSON == true ]]; then
  jq . <<<"$OUT"
  exit 0
fi

if [[ $(jq '.results | length' <<<"$OUT") -eq 0 ]]; then
  echo "(no results)" >&2
  exit 0
fi

# Each result row is [{field, value}, ...]. Build a TSV table whose columns are
# the union of fields across rows (first-seen order), minus the internal @ptr.
jq -r '
  [.results[] | map(select(.field != "@ptr")) | map({(.field): .value}) | add] as $rows
  | ([.results[][] | .field | select(. != "@ptr")] | reduce .[] as $f ([]; if index([$f]) then . else . + [$f] end)) as $cols
  | ($cols | @tsv),
    ($rows[] | . as $r | [ $cols[] | $r[.] // "-" ] | @tsv)
' <<<"$OUT" | column -t -s $'\t'
