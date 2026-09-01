# ConservativeRobinhoodAgent

Personal project. A local Ruby service that, once per weekday, screens the S&P 500, asks Claude
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
ruby bin/watch.rb         # foreground supervisor: pass on startup + one per weekday at RUN_AT (default 10:30 local)
```

`bin/watch.rb` prints every pass and a heartbeat; Ctrl-C stops it. Config comes from `.env`
(copy `.env.example`). `data/sp500.csv` is the universe — you maintain it. Requires Ruby ≥ 3.1.

## Layout

- `lib/agent.rb` — orchestrates one pass (manage positions → maybe one new entry)
- `lib/guardrails.rb` — re-derives whether/how big an order is allowed; the real safety layer
- `lib/strategy.rb` — builds the prompt, calls Claude, parses one proposal
- `lib/broker.rb` — the only writer; no-op unless `DRYRUN=false`
- `lib/mcp_client.rb` — MCP client + OAuth refresh + rate-limit backoff
- `lib/market_data.rb` · `lib/universe.rb` — read-only Robinhood data + the eligibility screen
- `lib/{journal,notifier,approval,config}.rb` — JSONL log, SMS, approval loop, config+validation

## Disclaimer

Robinhood puts full responsibility for agent-generated trades and losses on the account holder.
Not investment advice. Run it in dry mode until you trust it.
