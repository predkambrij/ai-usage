#!/usr/bin/env bash
# Report AI subscription usage limits and when each one resets, for:
#
#   claude  Claude (claude.ai subscription)
#           GET https://api.anthropic.com/api/oauth/usage
#           auth: OAuth token Claude Code stores in $CLAUDE_CONFIG_DIR/.credentials.json
#   codex   Codex (ChatGPT plan)
#           GET https://chatgpt.com/backend-api/wham/usage
#           auth: ChatGPT token Codex stores in $CODEX_HOME/auth.json
#   zai     z.ai GLM coding plan
#           GET https://api.z.ai/api/monitor/usage/quota/limit
#           auth: ZAI_API_KEY
#
# These are the endpoints each tool's own usage screen reads. They are
# read-only, but undocumented, and may change without notice.
#
# An expired Claude OAuth token is refreshed here with its refresh token (the
# same exchange Claude Code does) and the new tokens are written back to
# .credentials.json. Codex tokens are not refreshed; run `codex` once.

set -uo pipefail

PROVIDERS=(claude codex zai)

# Provider return codes (also the script's exit code, except NOT_CONFIGURED).
RC_OK=0 RC_LIMITED=1 RC_ERROR=2 RC_NOT_CONFIGURED=3

SHOW_JSON=0
DO_PROBE=0
EXPLICIT=1   # 0 when no provider was named on the command line
NOW=$(date +%s)

# ---------------------------------------------------------------- helpers ---

usage() {
  cat <<EOF
usage: $(basename "$0") [claude] [codex] [zai] [--json] [--probe]

Report usage limits and reset times. With no provider named, every provider
that has credentials is reported and the others are skipped.

  --json    print the raw usage response(s) instead of the report
  --probe   zai only: also send a 1-token chat request, the only way to see
            the server's own "limit will reset at ..." message (costs a prompt)

exit: 0 fine, 1 some limit is at 100%, 2 error

env (also read from .env next to this script; see .env.example):
  AI_USAGE_ENV_FILE   alternative .env path
  CLAUDE_CONFIG_DIR   default ~/.claude        CLAUDE_USAGE_URL
  CLAUDE_TOKEN_URL CLAUDE_OAUTH_CLIENT_ID      (used to refresh the token)
  CODEX_HOME          default ~/.codex         CODEX_USAGE_URL
  ZAI_API_KEY         required for zai         ZAI_API_BASE ZAI_QUOTA_URL
  ZAI_API_URL ZAI_MODEL ZAI_SERVER_TZ          (used by --probe)
EOF
}

err() { echo "$*" >&2; }

# Report a provider as lacking credentials. Only an error worth printing when
# the provider was asked for by name; otherwise main just lists it as skipped.
not_configured() {
  (( EXPLICIT )) && err "$*"
  return $RC_NOT_CONFIGURED
}

# Load .env from the script's own directory, so the script works from any cwd.
# Already-exported environment variables win over the file.
load_env() {
  local env_file line key val
  env_file="${AI_USAGE_ENV_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.env}"
  [[ -f "$env_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    line="${line#export }"
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [[ -z "${!key:-}" ]] && export "$key=$val"
  done < "$env_file"
}

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

# print_row LABEL PERCENT RESET_EPOCH   (epoch in seconds; empty or 0 = unknown)
print_row() {
  local label=$1 pct=${2:-0} epoch=${3:-}
  printf '%-14s [%s] %3s%%' "$label" "$(bar "$pct")" "$pct"
  if [[ -n "$epoch" && "$epoch" != "0" ]]; then
    printf '   resets %s  (in %s)' \
      "$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z')" "$(humanize $((epoch - NOW)))"
  else
    printf '   resets unknown'
  fi
  echo
}

print_json() { jq . <<<"$1" 2>/dev/null || printf '%s\n' "$1"; }

# ----------------------------------------------------------------- claude ---

# Exchange the refresh token in CRED_FILE for a new access token and write the
# result back (atomically, keeping the file's other fields and permissions).
# Claude Code rotates the refresh token on every use, so the new one must be
# saved or the next refresh fails.
claude_refresh() {
  local cred_file=$1 refresh url client_id resp tmp
  refresh=$(jq -r '.claudeAiOauth.refreshToken // empty' "$cred_file")
  [[ -n "$refresh" ]] || { err "claude: no refresh token in $cred_file"; return 1; }
  url="${CLAUDE_TOKEN_URL:-https://platform.claude.com/v1/oauth/token}"
  client_id="${CLAUDE_OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"

  resp=$(jq -nc --arg rt "$refresh" --arg cid "$client_id" \
           '{grant_type: "refresh_token", refresh_token: $rt, client_id: $cid}' |
         curl -sS --max-time 30 -X POST -H "Content-Type: application/json" \
           -H "User-Agent: ${CLAUDE_USER_AGENT:-claude-cli/2.1.0 (external, cli)}" \
           --data-binary @- "$url") || { err "claude: token refresh request failed"; return 1; }
  jq -e '.access_token | strings' >/dev/null 2>&1 <<<"$resp" || {
    err "claude: token refresh rejected: $(jq -c '.error // .' <<<"$resp" 2>/dev/null || echo "$resp")"
    return 1; }

  tmp=$(mktemp "$cred_file.XXXXXX") || return 1
  chmod --reference="$cred_file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  jq --argjson r "$resp" --argjson now "$(date +%s%3N)" '
    .claudeAiOauth.accessToken = $r.access_token
    | .claudeAiOauth.refreshToken = ($r.refresh_token // .claudeAiOauth.refreshToken)
    | .claudeAiOauth.expiresAt = ($now + (($r.expires_in // 3600) * 1000))
    | if ($r.scope | type) == "string" then .claudeAiOauth.scopes = ($r.scope | split(" ")) else . end
  ' "$cred_file" > "$tmp" && mv -f "$tmp" "$cred_file" || {
    rm -f "$tmp"; err "claude: could not write refreshed token to $cred_file"; return 1; }
}

claude_usage() {
  local config_dir cred_file url token expires plan usage rows
  config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  config_dir="${config_dir/#\~/$HOME}"
  cred_file="$config_dir/.credentials.json"
  url="${CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"

  [[ -r "$cred_file" ]] || {
    not_configured "claude: no credentials at $cred_file — log in with: CLAUDE_CONFIG_DIR=$config_dir claude"
    return; }

  # Refresh a minute early so the token can't expire mid-request.
  expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$cred_file")
  if (( expires > 0 && expires / 1000 <= NOW + 60 )); then
    claude_refresh "$cred_file" || {
      err "claude: OAuth token in $cred_file expired and could not be refreshed — run: CLAUDE_CONFIG_DIR=$config_dir claude"
      return $RC_ERROR; }
  fi

  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file")
  plan=$(jq -r '.claudeAiOauth.subscriptionType // "unknown"' "$cred_file")
  [[ -n "$token" ]] || {
    not_configured "claude: no claudeAiOauth.accessToken in $cred_file"; return; }

  usage=$(curl -sS --max-time 30 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" \
    "$url") || { err "claude: usage request failed"; return $RC_ERROR; }

  (( SHOW_JSON )) && { print_json "$usage"; return $RC_OK; }

  jq -e '(.limits | type == "array") or (.five_hour | type == "object")' \
    >/dev/null 2>&1 <<<"$usage" || {
    err "claude: unexpected usage response: $usage"; return $RC_ERROR; }

  echo "Claude subscription — usage (plan: $plan, config: $config_dir)"
  echo

  # Rows come from the `limits` array, which is where per-model windows (e.g.
  # Fable) are reported. Older responses without it fall back to the top-level
  # five_hour / seven_day* keys.
  rows=$(jq -r '
    def name: if type == "object" then (.display_name // .id // .name // "?") else tostring end;
    def legacy_label:
      {five_hour: "5-hour usage", seven_day: "Weekly usage", seven_day_opus: "Weekly Opus",
       seven_day_sonnet: "Weekly Sonnet", seven_day_oauth_apps: "Weekly apps",
       seven_day_cowork: "Weekly Cowork"}[.] // .;
    if (.limits | type == "array" and length > 0) then
      .limits[]
      | (if   .kind == "session"    then "5-hour usage"
         elif .kind == "weekly_all" then "Weekly usage"
         else ((.group // "weekly") | if . == "session" then "5-hour" else (.[:1] | ascii_upcase) + .[1:] end)
              + " "
              + ([.scope.model, .scope.surface] | map(select(. != null) | name) | join(" ")
                 | if . == "" then "scoped" else . end)
         end) as $label
      | [$label, (.percent // 0 | round | tostring), (.resets_at // "")]
    else
      ["five_hour", "seven_day"] as $fixed
      | ($fixed + ([keys[] | select(startswith("seven_day_"))] - $fixed)) as $order
      | . as $u
      | $order[]
      | select($u[.] | type == "object" and has("utilization"))
      | [legacy_label, ($u[.].utilization // 0 | round | tostring), ($u[.].resets_at // "")]
    end
    | @tsv' <<<"$usage")

  local rc=$RC_OK label pct reset epoch
  while IFS=$'\t' read -r label pct reset; do
    [[ -n "$label" ]] || continue
    epoch=""
    [[ -n "$reset" ]] && epoch=$(date -d "$reset" +%s 2>/dev/null)
    print_row "$label" "$pct" "$epoch"
    (( pct >= 100 )) && rc=$RC_LIMITED
  done <<<"$rows"

  if jq -e '.extra_usage.is_enabled == true' >/dev/null <<<"$usage"; then
    jq -r '.extra_usage | "\nExtra usage: \(.used_credits // 0) of \(.monthly_limit // "?") \(.currency // "") used this month"' <<<"$usage"
  fi

  return $rc
}

# ------------------------------------------------------------------ codex ---

# Window length in seconds (+ optional prefix) -> label. Window lengths depend
# on the plan (paid: 5-hour + weekly; free: 30-day).
codex_label() {
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

codex_usage() {
  local codex_dir auth_file url token account payload expires usage plan rows
  codex_dir="${CODEX_HOME:-$HOME/.codex}"
  codex_dir="${codex_dir/#\~/$HOME}"
  auth_file="$codex_dir/auth.json"
  url="${CODEX_USAGE_URL:-https://chatgpt.com/backend-api/wham/usage}"

  [[ -r "$auth_file" ]] || {
    not_configured "codex: no credentials at $auth_file — log in with: codex login"; return; }

  token=$(jq -r '.tokens.access_token // empty' "$auth_file")
  account=$(jq -r '.tokens.account_id // empty' "$auth_file")
  [[ -n "$token" ]] || {
    not_configured "codex: no ChatGPT token in $auth_file (API-key auth has no plan limits)"
    return; }

  # The access token is a JWT; read its exp claim to catch expiry up front.
  payload=$(cut -d. -f2 <<<"$token" | tr '_-' '/+')
  while (( ${#payload} % 4 )); do payload+='='; done
  expires=$(base64 -d 2>/dev/null <<<"$payload" | jq -r '.exp // 0' 2>/dev/null)
  (( ${expires:-0} > 0 && expires <= NOW )) && {
    err "codex: ChatGPT token in $auth_file expired — run codex once to refresh it"
    return $RC_ERROR; }

  local headers=(-H "Authorization: Bearer $token" -H "User-Agent: codex-cli")
  [[ -n "$account" ]] && headers+=(-H "ChatGPT-Account-Id: $account")
  usage=$(curl -sS --max-time 30 "${headers[@]}" "$url") || {
    err "codex: usage request failed"; return $RC_ERROR; }

  (( SHOW_JSON )) && { print_json "$usage"; return $RC_OK; }

  jq -e '.rate_limit | type == "object"' >/dev/null 2>&1 <<<"$usage" || {
    err "codex: unexpected usage response: $usage"; return $RC_ERROR; }

  plan=$(jq -r '.plan_type // "unknown"' <<<"$usage")
  echo "Codex (ChatGPT plan) — usage (plan: $plan, config: $codex_dir)"
  echo

  # Main limits first, then code review and any per-model limits, if reported.
  rows=$(jq -r '
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

  local rc=$RC_OK secs pct reset prefix
  while IFS=$'\t' read -r secs pct reset prefix; do
    [[ -n "$pct" ]] || continue
    print_row "$(codex_label "$secs" "$prefix")" "$pct" "$reset"
    (( pct >= 100 )) && rc=$RC_LIMITED
  done <<<"$rows"

  jq -e '.rate_limit.limit_reached == true' >/dev/null <<<"$usage" && rc=$RC_LIMITED

  if jq -e '.credits.has_credits == true' >/dev/null <<<"$usage"; then
    jq -r '.credits | "\nCredits: \(if .unlimited then "unlimited" else .balance // "?" end)"' <<<"$usage"
  fi

  return $rc
}

# -------------------------------------------------------------------- zai ---

# The unit/number enum is undocumented; map the combinations that are known and
# fall back to something honest rather than guessing.
zai_label() {
  case "$1/$2/$3" in                      # type/unit/number
    TOKENS_LIMIT/3/5) echo "5-hour usage"  ;;
    TOKENS_LIMIT/6/1) echo "Weekly usage"  ;;
    TIME_LIMIT/5/1)   echo "Tool calls"    ;;
    *)                echo "$1 (unit=$2 number=$3)" ;;
  esac
}

# Send a 1-token chat request. A 429 body carries "Your limit will reset at
# <YYYY-MM-DD HH:MM:SS>" in the server's timezone (UTC+8); everything else
# means the request went through.
zai_probe() {
  local api_key=$1 api_base=$2 url model server_tz body reset epoch
  url="${ZAI_API_URL:-$api_base/api/coding/paas/v4/chat/completions}"
  model="${ZAI_MODEL:-glm-5}"
  server_tz="${ZAI_SERVER_TZ:-Asia/Shanghai}"

  echo
  body=$(curl -sS --max-time 30 -X POST "$url" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}") || {
      err "zai: probe request failed"; return $RC_ERROR; }

  reset=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' <<<"$body" | head -1)
  if [[ -n "$reset" ]]; then
    if epoch=$(TZ="$server_tz" date -d "$reset" +%s 2>/dev/null); then
      echo "probe: rate limited — server says reset at $(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z') (in $(humanize $((epoch - $(date +%s)))))"
    else
      echo "probe: rate limited — server says reset at $reset ($server_tz)"
    fi
    return $RC_LIMITED
  elif grep -q '"error"' <<<"$body"; then
    err "zai: probe: unexpected error: $body"
    return $RC_ERROR
  fi
  echo "probe: chat request accepted — not currently rate limited."
  return $RC_OK
}

# Sibling endpoints /api/monitor/usage/{model,tool}-usage exist but return an
# empty body for API-key auth (they appear to need a browser session), so there
# is nothing further to report from them.
zai_usage() {
  local api_base url api_key quota level rows
  api_base="${ZAI_API_BASE:-https://api.z.ai}"
  url="${ZAI_QUOTA_URL:-$api_base/api/monitor/usage/quota/limit}"
  api_key="${ZAI_API_KEY:-}"

  [[ -n "$api_key" ]] || {
    not_configured "zai: ZAI_API_KEY is not set — copy .env.example to .env and add your key"
    return; }

  quota=$(curl -sS --max-time 30 \
    -H "Authorization: $api_key" \
    -H "Accept-Language: en-US,en" \
    -H "Content-Type: application/json" \
    "$url") || { err "zai: quota request failed"; return $RC_ERROR; }

  (( SHOW_JSON )) && { print_json "$quota"; return $RC_OK; }

  jq -e '.success == true and (.data.limits | type == "array")' >/dev/null 2>&1 <<<"$quota" || {
    err "zai: unexpected quota response: $quota"; return $RC_ERROR; }

  level=$(jq -r '.data.level // "unknown"' <<<"$quota")
  echo "Z.ai GLM coding plan — usage (plan: $level)"
  echo

  # "-" stands in for empty fields: tab is IFS whitespace, so `read` would
  # otherwise collapse consecutive empty columns.
  rows=$(jq -r '
    .data.limits[] | [
      .type, (.unit|tostring), (.number|tostring), (.percentage // 0 | tostring),
      (.nextResetTime // 0 | tostring),
      (.currentValue // "-" | tostring), (.usage // "-" | tostring),
      (.remaining // "?" | tostring),
      ([.usageDetails[]? | "\(.modelCode)=\(.usage)"] | join(",") | if . == "" then "-" else . end)
    ] | @tsv' <<<"$quota")

  local rc=$RC_OK type unit number pct reset cur used remaining details parts p
  while IFS=$'\t' read -r type unit number pct reset cur used remaining details; do
    [[ -n "$type" ]] || continue
    print_row "$(zai_label "$type" "$unit" "$number")" "$pct" "$((reset / 1000))"  # ms -> s

    [[ "$cur" != "-" && "$used" != "-" ]] &&
      printf '%-14s %s of %s used, %s remaining\n' "" "$cur" "$used" "$remaining"

    if [[ "$details" != "-" ]]; then
      IFS=',' read -ra parts <<<"$details"
      for p in "${parts[@]}"; do
        printf '%-16s %-14s %s\n' "" "${p%%=*}" "${p#*=}"
      done
    fi

    (( pct >= 100 )) && rc=$RC_LIMITED
  done <<<"$rows"

  if (( DO_PROBE )); then
    zai_probe "$api_key" "$api_base"
    case $? in
      "$RC_ERROR")   return $RC_ERROR ;;
      "$RC_LIMITED") rc=$RC_LIMITED ;;
    esac
  fi

  return $rc
}

# ------------------------------------------------------------------- main ---

main() {
  local selected=() arg
  for arg in "$@"; do
    case "$arg" in
      claude|codex|zai) selected+=("$arg") ;;
      --json)           SHOW_JSON=1 ;;
      --probe)          DO_PROBE=1 ;;
      -h|--help)        usage; exit 0 ;;
      *) err "unknown argument: $arg (try --help)"; exit $RC_ERROR ;;
    esac
  done

  command -v jq >/dev/null || { err "jq is required"; exit $RC_ERROR; }
  load_env

  # With no provider named, unconfigured ones are skipped rather than errors.
  (( ${#selected[@]} )) || { selected=("${PROVIDERS[@]}"); EXPLICIT=0; }

  local provider out rc exit_code=$RC_OK shown=0 skipped=()
  for provider in "${selected[@]}"; do
    # Capture stdout so the blank separator is only printed between reports.
    out=$("${provider}_usage"); rc=$?
    if (( ! EXPLICIT && rc == RC_NOT_CONFIGURED )); then skipped+=("$provider"); continue; fi

    if [[ -n "$out" ]]; then
      (( shown )) && echo
      printf '%s\n' "$out"
      shown=1
    fi

    case $rc in
      "$RC_LIMITED") (( exit_code == RC_OK )) && exit_code=$RC_LIMITED ;;
      "$RC_OK")      ;;
      *)             exit_code=$RC_ERROR ;;
    esac
  done

  if (( ${#skipped[@]} == ${#PROVIDERS[@]} )); then
    err "no provider is configured (try --help)"
    exit $RC_ERROR
  elif (( ${#skipped[@]} )); then
    err ""
    err "skipped (no credentials): ${skipped[*]}"
  fi

  exit $exit_code
}

main "$@"
