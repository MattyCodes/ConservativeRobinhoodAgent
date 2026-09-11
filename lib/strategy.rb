# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# The reasoning layer. Given the screened candidates (with technicals) and the current portfolio
# state, it asks Claude for AT MOST ONE entry that fits config/strategy.yml, or an explicit
# "no_trade". Claude never sees money: it picks a symbol and explains why. All sizing, pricing,
# and stop placement are computed deterministically downstream, then re-checked by guardrails.
#
# If a `transcript` Journal is passed, every call's full prompt + response + token usage is
# written to it (log/claude_calls.jsonl) for later review of prompt/behaviour quality.
class Strategy
  ENDPOINT = URI("https://api.anthropic.com/v1/messages")

  Proposal = Struct.new(:symbol, :rationale, :confidence, keyword_init: true)

  # Always returned by #propose. `closest_miss` (on no_trade) says how close the best candidate
  # got; `usage`/`model`/`raw` carry the API accounting and Claude's exact tool input.
  Outcome = Struct.new(:action, :proposal, :closest_miss, :confidence, :usage, :model, :raw,
                       keyword_init: true) do
    def enter?
      action == "enter" && !proposal.nil?
    end
  end

  # Field order matters: Claude fills a tool call's fields in the order they're declared here,
  # and with tool_choice forcing this tool there is no extended-thinking scratchpad separate
  # from it - these fields ARE the only place it can reason. `analysis` is declared first so the
  # verdict (`action`/`symbol`) is written AFTER the reasoning, not before it. (Observed live:
  # with action/symbol declared first, Claude would commit to e.g. "enter TROW" and only then,
  # in `rationale`, work out that TROW fails and a different symbol qualifies - too late to
  # change what it already submitted. That failure mode showed up in ~40% of no_trade calls.)
  PROPOSE_TOOL = {
    name: "propose_trade",
    description: "Return exactly one conservative entry that satisfies every rule, or no_trade.",
    strict: true, # guarantees tool_use.input actually validates against the schema below -
                  # without it, a long `analysis` was observed to drift out of JSON structure
                  # near the end and leave `action` empty instead of a real enter/no_trade.
    input_schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        analysis: { type: "string", description: "REQUIRED FIRST. Before deciding anything: check the 3-5 candidates with the best rank_score against both entry rules, explicitly, with their exact numbers, one by one. State pass/fail for each against each rule. Do this completely before writing anything below - action and symbol must be the conclusion of this analysis, never a preliminary guess you reasoned your way out of. Plain prose only: end it once your conclusion is reached, do not restate action/symbol/rationale/confidence as tags or any other markup inside this string - they belong only in their own fields below." },
        action: { type: "string", enum: %w[enter no_trade], description: "Must match the conclusion of `analysis` exactly. If `analysis` found a qualifying candidate, this is enter with that symbol - never no_trade." },
        symbol: { type: "string", description: "Ticker to buy; required when action=enter. Must be the candidate `analysis` concluded qualifies." },
        rationale: { type: "string", description: "Concise restatement of the analysis conclusion: which rule is met (enter) or why nothing qualified (no_trade), with the numbers." },
        closest_miss: { type: "string", description: "action=no_trade only: the single candidate that came closest to qualifying and exactly what it missed by, e.g. 'MSFT: RSI 46, needs <=40; otherwise a clean trend pullback'. Empty string if nothing was remotely close. Must be consistent with `analysis` - if analysis found a qualifier, closest_miss is moot because action should be enter, not no_trade." },
        # strict mode's schema subset doesn't support minimum/maximum on numbers - clamped in
        # code instead (see #propose).
        confidence: { type: "number", description: "Confidence in THIS decision (the enter, or the no_trade), from 0.0 to 1.0 - NOT a probability that trading is a good idea." }
      },
      required: %w[analysis action rationale confidence]
    }
  }.freeze

  def initialize(config, logger: ->(_) {}, transcript: nil)
    @config = config
    @log = logger
    @transcript = transcript
  end

  # candidates: [{ symbol:, name:, sector:, rank_score:, technicals: {...} }]
  # portfolio:  { settled_cash:, funded_balance:, ... }
  # Always returns an Outcome.
  def propose(candidates:, portfolio:)
    if candidates.empty?
      return Outcome.new(action: "no_trade", proposal: nil, closest_miss: "", confidence: 1.0,
                         usage: nil, model: nil, raw: nil)
    end

    system = system_prompt
    user = user_prompt(candidates, portfolio)
    body = {
      model: @config.claude_model,
      max_tokens: 4096, # headroom - a truncated tool call silently drops closest_miss etc.
      tool_choice: { type: "tool", name: "propose_trade" },
      tools: [PROPOSE_TOOL],
      system: system,
      messages: [{ role: "user", content: user }]
    }

    t, usage, model = request(body)
    confidence = t["confidence"].to_f.clamp(0.0, 1.0)
    @log.("strategy: #{t['action']} (confidence #{confidence}) [in #{usage&.dig('input_tokens')} out #{usage&.dig('output_tokens')} tok]")

    @transcript&.record("claude_call",
                        model: model, usage: usage, response: t,
                        system: system, user: user)

    if t["action"] == "enter" && !t["symbol"].to_s.empty?
      proposal = Proposal.new(symbol: t["symbol"].strip.upcase, rationale: t["rationale"].to_s, confidence: confidence)
      Outcome.new(action: "enter", proposal: proposal, closest_miss: "", confidence: confidence,
                  usage: usage, model: model, raw: t)
    else
      Outcome.new(action: "no_trade", proposal: nil, closest_miss: t["closest_miss"].to_s, confidence: confidence,
                  usage: usage, model: model, raw: t)
    end
  end

  private

  def system_prompt
    <<~TXT
      You pick conservative large-cap equity entries for an automated account, applying the two
      entry rules below MECHANICALLY.

      Both rules require the 50-day EMA to be above the 200-day EMA (an established uptrend).

        TREND-PULLBACK: price is above the 200-EMA, AND price is between the 50-EMA and
        trend_pullback_band_pct above it - i.e. price >= 50-EMA and
        price <= 50-EMA * (1 + trend_pullback_band_pct/100).

        MEAN-REVERSION: RSI <= rsi_entry_max, AND price is between meanrev_support_band_pct
        below the 200-EMA and twice that above it - i.e.
        price >= 200-EMA * (1 - meanrev_support_band_pct/100) and
        price <= 200-EMA * (1 + 2 * meanrev_support_band_pct/100).

      If a candidate satisfies EITHER rule exactly as written, return action=enter and cite the
      numbers. Do NOT impose conditions that are not in these rules: there is no "slope must be
      clearly rising", no "trend must be strongly confirmed", no "only marginally inside the
      band, so hold back". Inside the band is inside the band; RSI 39.9 <= 40 qualifies. Name
      which of the two rules you used, correctly.

      Return action=no_trade ONLY when no candidate satisfies either rule. Do not treat no_trade
      as a stylistic default.

      A downstream guardrail layer independently re-checks position sizing, the concurrent /
      sector / daily caps, cool-downs, and the earnings blackout, and is the final authority -
      you never need to be more conservative than the two rules above. Never propose a symbol
      that is not in the candidate list, is already held, is in cool-down, or whose sector is
      flagged at its cap. Position size, price, and stop placement are set by the system.

      Fill in `analysis` FIRST, before `action`. Work the candidates in it; only once that's
      done, set action/symbol to whatever `analysis` actually concluded. If partway through
      `analysis` you realize your first guess was wrong, that's fine - just make sure the
      symbol you finally submit is the one your own analysis says qualifies, not the one you
      started with.

      STRATEGY PARAMETERS (config/strategy.yml):
      #{JSON.pretty_generate(@config.strategy)}
    TXT
  end

  def user_prompt(candidates, portfolio)
    <<~TXT
      PORTFOLIO STATE:
      #{JSON.pretty_generate(portfolio)}

      CANDIDATES (passed the eligibility screen; pre-ranked by pullback depth, deepest first;
      technicals on daily bars):
      #{JSON.pretty_generate(candidates)}

      Call propose_trade with either one entry that satisfies every entry rule in section 3 and
      violates no rule in sections 2, 5, or 6, or action=no_trade. For an enter, the rationale
      must name the specific rule met (e.g. "mean-reversion: RSI 34 < 40 and price within 1% of
      rising 200-EMA") and cite the numbers.

      For a no_trade, fill in closest_miss: the ONE candidate nearest to satisfying a rule and
      the exact gap - which rule, current value vs threshold (e.g. "FE: RSI 41.3, needs <=40").
    TXT
  end

  # Returns [tool_input_hash, usage_hash, model_string].
  def request(body)
    req = Net::HTTP::Post.new(ENDPOINT)
    req["x-api-key"] = @config.anthropic_api_key
    req["anthropic-version"] = "2023-06-01"
    req["content-type"] = "application/json"
    req.body = JSON.generate(body)

    res = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, read_timeout: 90) do |http|
      http.request(req)
    end

    raise "Anthropic API HTTP #{res.code}: #{res.body}" unless res.code.to_i == 200

    payload = JSON.parse(res.body)
    block = Array(payload["content"]).find { |c| c["type"] == "tool_use" && c["name"] == "propose_trade" }
    raise "no propose_trade tool_use in response: #{res.body}" unless block

    [block.fetch("input"), payload["usage"], payload["model"]]
  end
end
