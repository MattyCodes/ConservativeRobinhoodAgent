# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# The reasoning layer. Given the screened candidates (with technicals) and the current portfolio
# state, it asks Claude for AT MOST ONE entry that fits config/strategy.yml, or an explicit
# "no_trade". Claude never sees money: it picks a symbol and explains why. All sizing, pricing,
# and stop placement are computed deterministically downstream, then re-checked by guardrails.
class Strategy
  ENDPOINT = URI("https://api.anthropic.com/v1/messages")

  Proposal = Struct.new(:symbol, :rationale, :confidence, keyword_init: true)

  # Always returned by #propose. On no_trade, `closest_miss` says how close the best candidate
  # got - the instrument for judging whether the rules are too tight vs. the market just quiet.
  Outcome = Struct.new(:action, :proposal, :closest_miss, :confidence, keyword_init: true) do
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

  def initialize(config, logger: ->(_) {})
    @config = config
    @log = logger
  end

  # candidates: [{ symbol:, name:, sector:, technicals: {...} }]
  # portfolio:  { settled_cash:, funded_balance:, open_positions: [...], sector_exposure: {...},
  #               entries_today:, deployed_today:, cooldown_symbols: [...] }
  # Always returns an Outcome.
  def propose(candidates:, portfolio:)
    return Outcome.new(action: "no_trade", proposal: nil, closest_miss: "", confidence: 1.0) if candidates.empty?

    body = {
      model: @config.claude_model,
      max_tokens: 1024,
      tool_choice: { type: "tool", name: "propose_trade" },
      tools: [PROPOSE_TOOL],
      system: system_prompt,
      messages: [{ role: "user", content: user_prompt(candidates, portfolio) }]
    }

    t = request(body)
    confidence = t["confidence"].to_f
    @log.("strategy: #{t['action']} (confidence #{confidence})")

    if t["action"] == "enter" && !t["symbol"].to_s.empty?
      proposal = Proposal.new(symbol: t["symbol"].strip.upcase, rationale: t["rationale"].to_s, confidence: confidence)
      Outcome.new(action: "enter", proposal: proposal, closest_miss: "", confidence: confidence)
    else
      Outcome.new(action: "no_trade", proposal: nil, closest_miss: t["closest_miss"].to_s, confidence: confidence)
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

    block.fetch("input")
  end
end
