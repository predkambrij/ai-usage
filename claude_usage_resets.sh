#!/usr/bin/env bash
# Report Claude (claude.ai subscription) usage limits and when each one resets.
#
# Source is the endpoint Claude Code's own /usage screen uses:
#   GET https://api.anthropic.com/api/oauth/usage  ->  utilization + resets_at
# It is read-only and authenticates with the OAuth token Claude Code stores in
# $CLAUDE_CONFIG_DIR/.credentials.json (default ~/.claude).
# Note: this endpoint is undocumented and may change without notice.
#
# The token is not refreshed here; if it has expired, run `claude` once with the
# same CLAUDE_CONFIG_DIR and it will refresh it.

set -uo pipefail

# Load .env from the script's own directory, so the script works from any cwd.
# Already-exported environment variables win over the file.
env_file="${CLAUDE_USAGE_ENV_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.env}"
if [[ -f "$env_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    line="${line#export }"
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [[ -z "${!key:-}" ]] && export "$key=$val"
  done < "$env_file"
fi

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CRED_FILE="$CONFIG_DIR/.credentials.json"
USAGE_URL="${CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"

show_json=0
for arg in "$@"; do
  case "$arg" in
    --json) show_json=1 ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \?//'
      echo
      echo "usage: $(basename "$0") [--json]"
      echo "  --json   print the raw usage response and exit"
      echo
      echo "env: CLAUDE_CONFIG_DIR (default ~/.claude) CLAUDE_USAGE_URL"
      echo "     CLAUDE_USAGE_ENV_FILE"
      echo "     read from .env next to this script; see .env.example"
      exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

[[ -r "$CRED_FILE" ]] || {
  echo "no credentials at $CRED_FILE — log in with: CLAUDE_CONFIG_DIR=$CONFIG_DIR claude" >&2
  exit 2; }

token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED_FILE")
expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CRED_FILE")
plan=$(jq -r '.claudeAiOauth.subscriptionType // "unknown"' "$CRED_FILE")
[[ -n "$token" ]] || { echo "no claudeAiOauth.accessToken in $CRED_FILE" >&2; exit 2; }

now=$(date +%s)
(( expires > 0 && expires / 1000 <= now )) && {
  echo "OAuth token in $CRED_FILE expired — run: CLAUDE_CONFIG_DIR=$CONFIG_DIR claude" >&2
  exit 2; }

usage=$(curl -sS --max-time 30 \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Content-Type: application/json" \
  "$USAGE_URL") || { echo "usage request failed" >&2; exit 2; }

if (( show_json )); then
  jq . <<<"$usage" 2>/dev/null || printf '%s\n' "$usage"
  exit 0
fi

jq -e '.five_hour | type == "object"' >/dev/null <<<"$usage" 2>/dev/null || {
  echo "unexpected usage response: $usage" >&2; exit 2; }

# Seconds -> "2h 12m" / "6d 04h 09m".
humanize() {
  local s=$1
  (( s <= 0 )) && { echo "now"; return; }
  local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60))
  if   (( d > 0 )); then printf '%dd %02dh %02dm' "$d" "$h" "$m"
  elif (( h > 0 )); then printf '%dh %02dm'       "$h" "$m"
  else                   printf '%dm %02ds'       "$m" "$((s%60))"
  fi
}

# 20-cell meter.
bar() {
  local pct=$1 filled i out=""
  (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  filled=$(( (pct * 20 + 50) / 100 ))
  for ((i=0; i<20; i++)); do (( i < filled )) && out+='#' || out+='.'; done
  printf '%s' "$out"
}

label_for() {
  case "$1" in
    five_hour)            echo "5-hour usage" ;;
    seven_day)            echo "Weekly usage" ;;
    seven_day_opus)       echo "Weekly Opus" ;;
    seven_day_sonnet)     echo "Weekly Sonnet" ;;
    seven_day_oauth_apps) echo "Weekly apps" ;;
    seven_day_cowork)     echo "Weekly Cowork" ;;
    *)                    echo "$1" ;;
  esac
}

echo "Claude subscription — usage (plan: $plan, config: $CONFIG_DIR)"
echo

limited=0
# Fixed windows first, then any other per-model weekly window the plan reports.
while IFS=$'\t' read -r key pct reset; do
  label=$(label_for "$key")
  printf '%-14s [%s] %3s%%' "$label" "$(bar "$pct")" "$pct"

  if [[ -n "$reset" ]] && epoch=$(date -d "$reset" +%s 2>/dev/null); then
    printf '   resets %s  (in %s)' \
      "$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z')" "$(humanize $((epoch - now)))"
  else
    printf '   resets unknown'
  fi
  echo

  (( pct >= 100 )) && limited=1
done < <(jq -r '
  ["five_hour", "seven_day"] as $fixed
  | ($fixed + ([keys[] | select(startswith("seven_day_"))] - $fixed)) as $order
  | . as $u
  | $order[]
  | select($u[.] | type == "object" and has("utilization"))
  | [., ($u[.].utilization // 0 | round | tostring), ($u[.].resets_at // "")]
  | @tsv' <<<"$usage")

if jq -e '.extra_usage.is_enabled == true' >/dev/null <<<"$usage"; then
  jq -r '.extra_usage | "\nExtra usage: \(.used_credits // 0) of \(.monthly_limit // "?") \(.currency // "") used this month"' <<<"$usage"
fi

exit $limited
