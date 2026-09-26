# frozen_string_literal: true

require_relative "spec_helper"

# Integration-level behavioral specs: the real Agent, Guardrails, Broker, PaperLedger, Universe,
# MarketData, and Strategy all run for real - only the two actual network boundaries are faked:
# FakeMcpClient stands in for Robinhood, and Strategy#request (the Anthropic HTTP call) is
# stubbed per-test via stub_strategy_requests. Notifier is replaced with a no-op so nothing ever
# reaches Twilio either. Nothing here can reach a real external service.
describe Agent do
  include SpecHelpers

  # symbols: fed to FakeMcpClient - anything not listed here is simply absent from Robinhood,
  # same as a real inactive/unresolvable ticker (Universe rejects it as "no fundamentals").
  def build_agent(symbols:, account: FakeMcpClient::DEFAULT_ACCOUNT, review: {},
                  config_overrides: {})
    config = build_config(config_overrides)
    fake_mcp = FakeMcpClient.new(symbols: symbols, account: account, review: review)
    paper_journal = tmp_journal("paper")
    paper = PaperLedger.new(paper_journal, start_usd: 1000.0,
                                          quote_fn: ->(sym) { symbols[sym] && symbols[sym][:price] })
    strategy = Strategy.new(config, logger: ->(_msg) {}, transcript: tmp_journal("claude_calls"))
    agent = Agent.new(config, mcp: fake_mcp, paper: paper, journal: tmp_journal("journal"),
                      transcript: tmp_journal("claude_calls"), log_path: tmp_log_path,
                      strategy: strategy, notifier: NullNotifier.new)
    [agent, fake_mcp, paper, strategy, paper_journal]
  end

  it "places a paper entry when Claude proposes a candidate that clears every guardrail" do
    agent, _mcp, paper, strategy, = build_agent(symbols: { "AAPL" => trend_pullback_row(price: 105.0) })
    stub_strategy_requests(strategy, claude_enter("AAPL")) { agent.run(scan_for_entry: true) }

    _(paper.open?("AAPL")).must_equal true
    _(agent.summary.join).must_match(/AAPL/)
  end

  it "blocks the entry when it would push a sector over its cap, even though Claude proposed it" do
    symbols = {
      "MSFT" => trend_pullback_row(price: 300.0), # existing IT position
      "KEYS" => trend_pullback_row(price: 330.0) # candidate, also IT - otherwise clean
    }
    agent, _mcp, paper, strategy, paper_journal = build_agent(symbols: symbols)
    # Pre-existing MSFT position worth ~$240 of a $1000 book - 24% of the 25% IT sector cap,
    # leaving only $10 of room, well under the ~$100 a fresh entry would need.
    paper_journal.record("paper_opened", symbol: "MSFT", entry_price: 300.0, dollar_amount: 240.0,
                                        quantity: 0.8, stop_price: 279.0, sector: "Information Technology",
                                        order_type: "market")

    stub_strategy_requests(strategy, claude_enter("KEYS")) { agent.run(scan_for_entry: true) }

    _(paper.open?("KEYS")).must_equal false
    _(agent.summary.join).must_match(/blocked KEYS/)
    _(agent.summary.join).must_match(/sector/)
  end

  it "recovers a real entry after Claude's response comes back malformed once" do
    agent, _mcp, paper, strategy, = build_agent(symbols: { "EBAY" => trend_pullback_row(price: 107.4) })
    stub_strategy_requests(
      strategy,
      claude_malformed(symbol: "EBAY</ANT:PARAMETER>\n"),
      claude_enter("EBAY")
    ) { agent.run(scan_for_entry: true) }

    _(paper.open?("EBAY")).must_equal true
  end

  it "rejects an off-list symbol without placing anything, if malformed persists through every retry" do
    agent, _mcp, paper, strategy, = build_agent(symbols: { "EBAY" => trend_pullback_row(price: 107.4) })
    stub_strategy_requests(
      strategy,
      claude_malformed(symbol: "EBAY</ANT:PARAMETER>\n"),
      claude_malformed(symbol: "EBAY</ANT:PARAMETER>\n"),
      claude_malformed(symbol: "EBAY</ANT:PARAMETER>\n")
    ) { agent.run(scan_for_entry: true) }

    _(paper.open?("EBAY")).must_equal false
    _(agent.summary.join).must_match(/rejected/)
  end

  it "never calls Claude once the daily entry cap is already reached" do
    agent, _mcp, paper, strategy, = build_agent(symbols: { "AAPL" => trend_pullback_row(price: 105.0) })
    # Two entries already recorded today satisfies pacing.max_new_positions_per_day (2) - if
    # Strategy#propose were called anyway, this raises and the spec fails loudly.
    agent.instance_variable_get(:@journal).record("order_placed", role: "entry", symbol: "X",
                                                                  notional: 100.0)
    agent.instance_variable_get(:@journal).record("order_placed", role: "entry", symbol: "Y",
                                                                  notional: 100.0)
    strategy.stub(:propose, ->(**) { raise "Strategy#propose should not have been called" }) do
      agent.run(scan_for_entry: true)
    end
    _(paper.positions).must_equal []
  end

  it "closes a paper position with a script stop once price drops through the stop level" do
    agent, _mcp, paper, _strategy, paper_journal = build_agent(symbols: { "NSC" => market_row(price: 280.0, ema_fast: 300, ema_slow: 290, rsi: 50) })
    paper_journal.record("paper_opened", symbol: "NSC", entry_price: 318.765, dollar_amount: 99.66,
                                        quantity: 0.31264, stop_price: 296.45, sector: "Industrials",
                                        order_type: "market")

    agent.run(scan_for_entry: false)

    _(paper.open?("NSC")).must_equal false
    _(agent.summary.join).must_match(/SCRIPT STOP NSC/)
  end

  it "leaves a paper position open and just tracks the stop level while price stays above it" do
    agent, _mcp, paper, = build_agent(symbols: { "NSC" => market_row(price: 316.0, ema_fast: 300, ema_slow: 290, rsi: 50) })
    journal = agent.instance_variable_get(:@journal)
    paper.open(symbol: "NSC", entry_price: 318.765, dollar_amount: 99.66, quantity: 0.31264,
              stop_price: 296.45, sector: "Industrials", order_type: "market")

    agent.run(scan_for_entry: false)

    _(paper.open?("NSC")).must_equal true
    _(journal.events.any? { |e| e["event"] == "stop_tracked" && e["symbol"] == "NSC" }).must_equal true
  end

  it "closes a position on the time exit regardless of a healthy price" do
    agent, _mcp, paper, _strategy, paper_journal = build_agent(symbols: { "NSC" => market_row(price: 330.0, ema_fast: 300, ema_slow: 290, rsi: 50) })
    paper_journal.record("paper_opened", symbol: "NSC", entry_price: 318.765, dollar_amount: 99.66,
                                        quantity: 0.31264, stop_price: 296.45, sector: "Industrials",
                                        order_type: "market", at: (Time.now.utc - (40 * 86_400)).iso8601)

    agent.run(scan_for_entry: false)

    _(paper.open?("NSC")).must_equal false
    _(agent.summary.join).must_match(/time exit/)
  end
end
