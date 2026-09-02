# ConservativeRobinhoodAgent

Personal project. A local Ruby service that, on a weekday schedule, screens the S&P 500, asks Claude
for one conservative entry that fits `config/strategy.yml`, re-checks it against hard-coded
guardrails, and — if it passes — places it in a dedicated **Robinhood Agentic** account. Runs in
a terminal window you keep open (`ruby bin/watch.rb`).

## Safety switches (both default to the safe side)

| Env | Default | Effect |
|---|---|---|
| `DRYRUN` | `true` | Everything runs except the order. `DRYRUN=false` to place real orders. |
| `APPROVAL_MODE` | `confirm` | Every live order needs an SMS `YES <code>` reply. `notify` = fully autonomous. |

Fully live = `DRYRUN=false APPROVAL_MODE=notify ruby bin/watch.rb`.

Always on: trade access is scoped by Robinhood to the one funded Agentic account; `HALT` file in
the project root pauses all passes; `lib/guardrails.rb` is the authority on every order; sizing
is always checked against unleveraged, settled buying power (never margin).

## Fractional mode

`config/strategy.yml → sizing.fractional_shares: true` (current): entries are dollar-based market
orders so a small balance is usable. **The stop-loss is then script-monitored, not a real
order** — it's only checked when a pass runs, so a gap down between passes isn't caught until the
next pass. Set `false` for whole-share limit entries + native GTC stops (needs 7% ≥ 1 share).

## Run

```
ruby bin/authorize.rb     # one-time Robinhood OAuth (writes ~/.config/conservative-robinhood-agent/token.json)
ruby main.rb              # one pass, then exit — for dry-run checks
ruby bin/watch.rb         # foreground supervisor (the normal way to run it)
```

`bin/watch.rb` runs a **full pass** (screen + Claude + position management) at each `RUN_AT`
time on weekdays, plus a lightweight **stop-check** (position management only, no Claude —
just the deterministic guardrails) every `STOP_CHECK_MINUTES` while the market is open. It
prints every pass and a heartbeat; Ctrl-C stops it; a `HALT` file pauses everything. Config
comes from `.env` (copy `.env.example`). `data/sp500.csv` is the universe — you maintain it.
Requires Ruby ≥ 3.1.

## Layout

- `lib/agent.rb` — orchestrates a pass; `run(scan_for_entry: false)` = stop-check only, no Claude
- `lib/guardrails.rb` — re-derives whether/how big an order is allowed; the real safety layer
- `lib/strategy.rb` — builds the prompt, calls Claude, parses one proposal
- `lib/broker.rb` — the only writer; live orders, or routed to the paper ledger in dry-run
- `lib/paper.rb` — dry-run paper portfolio so the full lifecycle (limits, cool-downs, stops, P&L) is simulated
- `lib/mcp_client.rb` — MCP client + OAuth refresh + rate-limit backoff + call counters
- `lib/market_data.rb` · `lib/universe.rb` — read-only Robinhood data + the eligibility screen
- `lib/{journal,notifier,approval,config}.rb` — JSONL log, SMS, approval loop, config+validation

## Logs (`log/`, all gitignored)

- `journal.jsonl` — every decision + `scan_started` (effective config, git rev) + `scan_finished`
  (duration, MCP call/retry counts, outcome) + `candidates` (the ranked pool with technicals,
  what just missed the cut, what got dropped)
- `claude_calls.jsonl` — every Claude call: full prompt, full response, token usage
- `paper.jsonl` — dry-run paper positions: `paper_opened` / `paper_closed` with entry/exit/P&L
- `run.log` — the human-readable narrative (dated)

## Disclaimer

Robinhood puts full responsibility for agent-generated trades and losses on the account holder.
Not investment advice. Run it in dry mode until you trust it.
