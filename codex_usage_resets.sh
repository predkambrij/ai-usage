#!/usr/bin/env bash
# Report Codex (ChatGPT plan) usage limits and when each one resets.
#
# Source is the endpoint the Codex CLI/app uses for its usage display:
#   GET https://chatgpt.com/backend-api/wham/usage  ->  used_percent + reset_at
# It is read-only and authenticates with the ChatGPT token Codex stores in
# $CODEX_HOME/auth.json (default ~/.codex).
# Note: this endpoint is undocumented and may change without notice.
#
# Window lengths depend on the plan (paid: 5-hour + weekly; free: 30-day), so
# each window is labelled from its reported length. The token is not refreshed
# here; if it has expired, run `codex` once and it will refresh it.

set -uo pipefail

# Load .env from the script's own directory, so the script works from any cwd.
# Already-exported environment variables win over the file.
env_file="${CODEX_USAGE_ENV_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.env}"
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

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_DIR="${CODEX_DIR/#\~/$HOME}"
AUTH_FILE="$CODEX_DIR/auth.json"
USAGE_URL="${CODEX_USAGE_URL:-https://chatgpt.com/backend-api/wham/usage}"

show_json=0
for arg in "$@"; do
  case "$arg" in
    --json) show_json=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      echo
      echo "usage: $(basename "$0") [--json]"
      echo "  --json   print the raw usage response and exit"
      echo
      echo "env: CODEX_HOME (default ~/.codex) CODEX_USAGE_URL CODEX_USAGE_ENV_FILE"
      echo "     read from .env next to this script; see .env.example"
      exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

[[ -r "$AUTH_FILE" ]] || {
  echo "no credentials at $AUTH_FILE — log in with: codex login" >&2
  exit 2; }

token=$(jq -r '.tokens.access_token // empty' "$AUTH_FILE")
account=$(jq -r '.tokens.account_id // empty' "$AUTH_FILE")
[[ -n "$token" ]] || {
  echo "no ChatGPT token in $AUTH_FILE (API-key auth has no plan limits)" >&2
  exit 2; }

now=$(date +%s)

# The access token is a JWT; read its exp claim to catch expiry up front.
payload=$(cut -d. -f2 <<<"$token" | tr '_-' '/+')
while (( ${#payload} % 4 )); do payload+='='; done
expires=$(base64 -d 2>/dev/null <<<"$payload" | jq -r '.exp // 0' 2>/dev/null)
(( ${expires:-0} > 0 && expires <= now )) && {
  echo "ChatGPT token in $AUTH_FILE expired — run codex once to refresh it" >&2
  exit 2; }

usage=$(curl -sS --max-time 30 \
  -H "Authorization: Bearer $token" \
  ${account:+-H "ChatGPT-Account-Id: $account"} \
  -H "User-Agent: codex-cli" \
  "$USAGE_URL") || { echo "usage request failed" >&2; exit 2; }

if (( show_json )); then
  jq . <<<"$usage" 2>/dev/null || printf '%s\n' "$usage"
  exit 0
fi

jq -e '.rate_limit | type == "object"' >/dev/null <<<"$usage" 2>/dev/null || {
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

# Window length in seconds -> label.
label_for() {
  local secs=$1 prefix=$2 name
  case "$secs" in
    18000)   name="5-hour" ;;
    604800)  name="Weekly" ;;
    2592000) name="30-day" ;;
    "")      name="window" ;;
    *) if (( secs % 86400 == 0 )); then name="$((secs/86400))-day"
       else name="$((secs/3600))-hour"; fi ;;
  esac
  echo "${prefix:+$prefix }$name"
}

plan=$(jq -r '.plan_type // "unknown"' <<<"$usage")
echo "Codex (ChatGPT plan) — usage (plan: $plan, config: $CODEX_DIR)"
echo

limited=0
# Main limits first, then code review and any per-model limits, if reported.
while IFS=$'\t' read -r secs pct reset prefix; do
  label=$(label_for "$secs" "$prefix")
  printf '%-14s [%s] %3s%%' "$label" "$(bar "$pct")" "$pct"

  if [[ -n "$reset" && "$reset" != "0" ]]; then
    printf '   resets %s  (in %s)' \
      "$(date -d "@$reset" '+%Y-%m-%d %H:%M:%S %Z')" "$(humanize $((reset - now)))"
  else
    printf '   resets unknown'
  fi
  echo

  (( pct >= 100 )) && limited=1
done < <(jq -r '
  def windows($prefix):
    select(type == "object")
    | (.primary_window, .secondary_window)
    | select(type == "object")
    | [(.limit_window_seconds // "" | tostring),
       (.used_percent // 0 | round | tostring), (.reset_at // 0 | tostring), $prefix];
  (.rate_limit | windows("")),
  (.code_review_rate_limit | windows("Review")),
  (.additional_rate_limits // [] | if type == "array" then .[] else empty end
   | (.limit_name // .metered_feature // "Extra") as $n | .rate_limit | windows($n))
  | @tsv' <<<"$usage")

jq -e '.rate_limit.limit_reached == true' >/dev/null <<<"$usage" && limited=1

if jq -e '.credits.has_credits == true' >/dev/null <<<"$usage"; then
  jq -r '.credits | "\nCredits: \(if .unlimited then "unlimited" else .balance // "?" end)"' <<<"$usage"
fi

exit $limited
