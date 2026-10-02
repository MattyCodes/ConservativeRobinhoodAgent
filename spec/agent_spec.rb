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

  it "still blocks an entry that fails a guardrail Claude didn't catch (earnings blackout)" do
    agent, _mcp, paper, strategy, = build_agent(symbols: { "AAPL" => trend_pullback_row(price: 105.0, earnings_days: 1) })
    stub_strategy_requests(strategy, claude_enter("AAPL")) { agent.run(scan_for_entry: true) }

    _(paper.open?("AAPL")).must_equal false
    _(agent.summary.join).must_match(/blocked AAPL/)
    _(agent.summary.join).must_match(/earnings blackout/)
  end

  # A $200 MMM position on a $1000 book leaves an Industrials sector (cap $250) too little room
  # for the ~$100 entry a new Industrials name would get - so it should never reach Claude.
  def sector_full_symbols
    {
      "MMM" => trend_pullback_row(price: 150.0), # held, Industrials
      "NSC" => trend_pullback_row(price: 300.0), # candidate, Industrials
      "AAPL" => trend_pullback_row(price: 105.0) # candidate, Information Technology
    }
  end

  def hold_mmm(paper_journal)
    paper_journal.record("paper_opened", symbol: "MMM", entry_price: 150.0, dollar_amount: 200.0,
                                        quantity: 1.3333, stop_price: 139.5, sector: "Industrials",
                                        order_type: "market")
  end

  it "keeps candidates in a sector with no room for a full-size entry away from Claude" do
    agent, _mcp, _paper, strategy, paper_journal = build_agent(symbols: sector_full_symbols)
    hold_mmm(paper_journal)

    seen = nil
    no_trade = lambda do |candidates:, portfolio:|
      seen = candidates.map { |c| c[:symbol] }
      Strategy::Outcome.new(action: "no_trade", proposal: nil, closest_miss: "", confidence: 0.5,
                            retried: false, attempts: 1)
    end
    strategy.stub(:propose, no_trade) { agent.run(scan_for_entry: true) }

    _(seen).must_equal ["AAPL"]
    event = agent.instance_variable_get(:@journal).events.find { |e| e["event"] == "candidates" }
    _(event["sectors_full"]).must_equal ["Industrials"]
  end

  it "doesn't call Claude at all when every candidate's sector is full" do
    symbols = sector_full_symbols.reject { |sym, _| sym == "AAPL" }
    agent, _mcp, paper, strategy, paper_journal = build_agent(symbols: symbols)
    hold_mmm(paper_journal)

    strategy.stub(:propose, ->(**) { raise "Strategy#propose should not have been called" }) do
      agent.run(scan_for_entry: true)
    end

    _(paper.open?("NSC")).must_equal false
    _(agent.summary.join).must_match(/no eligible candidates/)
  end

  it "recovers a real entry after Claude's response comes back malformed once" do
    agent, _mcp, paper, strategy, = build_agent(symbols: { "EBAY" => trend_pullback_row(price: 107.4) })
    stub_strategy_requests(
      strategy,
      claude_malformed(symbol: "EBAY</ANT:PARAMETER>\n"),
      claude_enter("EBAY")
    ) { agent.run(scan_for_entry: true) }

    _(paper.open?("EBAY")).must_equal true
    claude_call = agent.instance_variable_get(:@journal).events.find { |e| e["event"] == "claude_call" }
    _(claude_call["retried"]).must_equal true
    _(claude_call["attempts"]).must_equal 2
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
