# ai-usage

Show your AI subscription usage limits **and when each one resets**, for Claude
(claude.ai subscription), Codex (ChatGPT plan) and the [z.ai](https://z.ai) GLM
coding plan.

`ai-usage.sh` reads the same endpoints each tool's own usage screen uses and
prints the reset times they return, converted to your local timezone.

```
Claude subscription — usage (plan: pro, config: /home/me/.claude)

5-hour usage   [###.................]  16%   resets 2026-11-14 16:50:00 CET  (in 3h 42m)
Weekly usage   [########............]  41%   resets 2026-11-14 16:00:00 CET  (in 2h 52m)
Weekly Fable   [###.................]  17%   resets 2026-11-14 16:00:00 CET  (in 2h 52m)

Codex (ChatGPT plan) — usage (plan: free, config: /home/me/.codex)

30-day         [##################..]  90%   resets 2026-11-27 23:50:41 CET  (in 13d 10h 42m)

Z.ai GLM coding plan — usage (plan: lite)

5-hour usage   [################....]  80%   resets 2026-07-30 14:13:55 CEST  (in 2h 05m)
Weekly usage   [###############.....]  76%   resets 2026-08-05 16:11:13 CEST  (in 6d 04h 02m)
Tool calls     [....................]   2%   resets 2026-08-01 16:11:13 CEST  (in 2d 04h 02m)
               2 of 100 used, 98 remaining
                 search-prime   2
                 web-reader     0
                 zread          0
```

## Setup

Requires `bash`, `curl` and `jq`.

```sh
cp .env.example .env       # then add your z.ai API key
./ai-usage.sh
```

| Provider | Credentials |
| --- | --- |
| `claude` | the login Claude Code stores in `$CLAUDE_CONFIG_DIR` (default `~/.claude`) |
| `codex` | the ChatGPT login Codex stores in `$CODEX_HOME` (default `~/.codex`) |
| `zai` | `ZAI_API_KEY` |

Settings are read from the environment or from a `.env` file next to the script.
`.env` is gitignored. Expired Claude/Codex tokens are not refreshed; run `claude`
or `codex` once to refresh them.

## Usage

```
./ai-usage.sh                # every provider that has credentials
./ai-usage.sh claude         # one provider (several can be named)
./ai-usage.sh zai --json     # raw API response
./ai-usage.sh zai --probe    # also send a 1-token chat request (costs a prompt)
./ai-usage.sh --help
```

With no provider named, providers without credentials are skipped; naming one
that has none is an error.

Exit codes: `0` fine, `1` some limit is at 100%, `2` error — so it works in cron
or a monitor.

## Daily usage and billing

`zai_daily.py` compares daily billing records with Z.ai's usage report. Run it
with Docker Compose; Python and plotting dependencies stay in the container.
Set `ZAI_API_KEY` in `.env` as above, then:

```sh
docker compose run --build --rm daily --start-date 2026-10-09 --end-date 2026-10-15
# or
docker compose run --build --rm daily
```

Omit dates for month-to-date. Dates are inclusive, use **UTC+8**, and can span
up to 31 days. The full requested range is included. If the final day has no
daily billing rows, minutely records are aggregated automatically and marked `†`.

- **CLI:** daily totals and gaps, plus input/cached-input/output token counts
  and list-price costs, overall and per model.
- **Chart:** stacked billing categories, usage totals, signed gaps, and a daily
  table with list-price costs.
- **CSV:** exact daily counts, costs, and billing sources.

Files are saved to `reports/zai-daily.png` and `reports/zai-daily.csv` on the host.
Use `--output reports/custom.png` to change the name (`.svg` and `.pdf` also work),
or `docker compose run --rm daily --help` for options.

Gap means **usage − billing**; a negative value means billing reports more
tokens. The APIs can lag or disagree. `no rows` means missing billing data,
not confirmed zero usage or cost. List-price cost uses the ledger's model prices
in the account currency; it is not the amount charged for your Coding Plan.

![Daily billing and usage comparison](docs/zai-daily.png)

[Example CSV](docs/zai-daily.csv)

## Caveat

The usage endpoints are undocumented, so any provider may change or remove its
endpoint at any time. Unrecognised limit types are printed with their raw fields
rather than guessed at, and a malformed response exits `2` instead of reporting
something wrong.
