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

  PROPOSE_TOOL = {
    name: "propose_trade",
    description: "Return exactly one conservative entry that satisfies every rule, or no_trade.",
    input_schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        action: { type: "string", enum: %w[enter no_trade] },
        symbol: { type: "string", description: "Ticker to buy; required when action=enter." },
        rationale: { type: "string", description: "Which entry rule is met and the specific evidence." },
        confidence: { type: "number", minimum: 0, maximum: 1 }
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
  # Returns Proposal or nil.
  def propose(candidates:, portfolio:)
    return nil if candidates.empty?

    body = {
      model: @config.claude_model,
      max_tokens: 1024,
      tool_choice: { type: "tool", name: "propose_trade" },
      tools: [PROPOSE_TOOL],
      system: system_prompt,
      messages: [{ role: "user", content: user_prompt(candidates, portfolio) }]
    }

    tool_input = request(body)
    @log.("strategy: #{tool_input['action']} (confidence #{tool_input['confidence']})")

    return nil unless tool_input["action"] == "enter"
    return nil if tool_input["symbol"].to_s.empty?

    Proposal.new(
      symbol: tool_input["symbol"].strip.upcase,
      rationale: tool_input["rationale"].to_s,
      confidence: tool_input["confidence"].to_f
    )
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

      CANDIDATES (already passed the eligibility screen; technicals on daily bars):
      #{JSON.pretty_generate(candidates)}

      Call propose_trade with either one entry that satisfies every entry rule in section 3 and
      violates no rule in sections 2, 5, or 6, or action=no_trade. Your rationale must name the
      specific rule met (e.g. "mean-reversion: RSI 34 < 40 and price within 1% of rising 200-EMA")
      and cite the numbers from the candidate data.
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
