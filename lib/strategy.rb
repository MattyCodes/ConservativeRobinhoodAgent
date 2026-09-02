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

  PROPOSE_TOOL = {
    name: "propose_trade",
    description: "Return exactly one conservative entry that satisfies every rule, or no_trade.",
    input_schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        action: { type: "string", enum: %w[enter no_trade] },
        symbol: { type: "string", description: "Ticker to buy; required when action=enter." },
        rationale: { type: "string", description: "action=enter: which entry rule is met, with the numbers. action=no_trade: why nothing qualified." },
        closest_miss: { type: "string", description: "action=no_trade only: the single candidate that came closest to qualifying and exactly what it missed by, e.g. 'MSFT: RSI 46, needs <=40; otherwise a clean trend pullback'. Empty string if nothing was remotely close." },
        confidence: { type: "number", minimum: 0, maximum: 1, description: "Confidence in THIS decision (the enter, or the no_trade) - NOT a probability that trading is a good idea." }
      },
      required: %w[action rationale confidence]
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
    confidence = t["confidence"].to_f
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
      You select conservative, large-cap equity entries for an automated account. You must obey
      the strategy rules below exactly. Prefer no_trade over a marginal setup - most runs should
      return no_trade. Never propose a symbol that is not in the provided candidate list. Never
      propose a symbol already held, in cool-down, or whose sector is already at its cap. You are
      choosing a name and justifying it against a specific entry rule; position size, price, and
      stops are handled by the system, not by you.

      STRATEGY RULES (config/strategy.yml):
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

      For a no_trade, still fill in closest_miss: pick the ONE candidate that was nearest to
      qualifying and state exactly what it missed by (which rule, current value vs threshold).
      This is used to tell whether the rules are too tight or the market is just quiet.
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
