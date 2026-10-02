# frozen_string_literal: true

require_relative "spec_helper"

# Strategy#request is the only network call in this class (a direct Anthropic HTTP POST) - every
# spec here stubs it via SpecHelpers#stub_strategy_requests instead of calling the real API, and
# drives the exact multi-attempt sequences that produced the real bug this class works around
# (see lib/strategy.rb's MAX_ATTEMPTS comment and the 2026-09 incidents it cites).
describe Strategy do
  include SpecHelpers

  before do
    @strategy = Strategy.new(build_config, transcript: tmp_journal("claude_calls"))
  end

  def one_candidate(symbol: "AAPL")
    [{ symbol: symbol, name: "Test Co", sector: "Information Technology",
       rank_score: 0.01, technicals: {} }]
  end

  it "returns no_trade without calling Claude at all when there are no candidates" do
    @strategy.stub(:request, ->(_body) { raise "should not have called request" }) do
      outcome = @strategy.propose(candidates: [], portfolio: {})
      _(outcome.action).must_equal "no_trade"
      _(outcome.enter?).must_equal false
    end
  end

  it "returns a clean enter outcome on a well-formed first response" do
    stub_strategy_requests(@strategy, claude_enter("AAPL", confidence: 0.85)) do
      outcome = @strategy.propose(candidates: one_candidate, portfolio: {})
      _(outcome.enter?).must_equal true
      _(outcome.proposal.symbol).must_equal "AAPL"
      _(outcome.confidence).must_equal 0.85
      _(outcome.retried).must_equal false
    end
  end

  it "clamps an out-of-range confidence into [0.0, 1.0]" do
    stub_strategy_requests(@strategy, claude_enter("AAPL", confidence: 1.4)) do
      outcome = @strategy.propose(candidates: one_candidate, portfolio: {})
      _(outcome.confidence).must_equal 1.0
    end
  end

  it "returns a no_trade outcome carrying the closest_miss text" do
    stub_strategy_requests(@strategy, claude_no_trade(closest_miss: "MSFT: RSI 46, needs <=40")) do
      outcome = @strategy.propose(candidates: one_candidate, portfolio: {})
      _(outcome.enter?).must_equal false
      _(outcome.closest_miss).must_equal "MSFT: RSI 46, needs <=40"
    end
  end

  it "recovers from a single malformed response via retry (garbled tool-call-syntax symbol)" do
    stub_strategy_requests(
      @strategy,
      claude_malformed(symbol: "EBAY</ANT:PARAMETER>\n"),
      claude_enter("EBAY")
    ) do
      outcome = @strategy.propose(candidates: one_candidate(symbol: "EBAY"), portfolio: {})
      _(outcome.enter?).must_equal true
      _(outcome.proposal.symbol).must_equal "EBAY"
      _(outcome.retried).must_equal true
    end
  end

  it "recovers from a symbol missing outright on the first attempt" do
    stub_strategy_requests(
      @strategy,
      claude_malformed(symbol: nil),
      claude_enter("KEYS")
    ) do
      outcome = @strategy.propose(candidates: one_candidate(symbol: "KEYS"), portfolio: {})
      _(outcome.enter?).must_equal true
      _(outcome.proposal.symbol).must_equal "KEYS"
    end
  end

  it "keeps retrying up to MAX_ATTEMPTS and recovers on the final attempt" do
    stub_strategy_requests(
      @strategy,
      claude_malformed(symbol: nil),
      claude_malformed(symbol: "APH</parameter>"),
      claude_enter("APH")
    ) do
      outcome = @strategy.propose(candidates: one_candidate(symbol: "APH"), portfolio: {})
      _(outcome.enter?).must_equal true
      _(outcome.proposal.symbol).must_equal "APH"
      _(outcome.retried).must_equal true
    end
  end

  it "falls through to no_trade if every attempt comes back malformed (never places a wrong trade)" do
    stub_strategy_requests(
      @strategy,
      claude_malformed(symbol: nil),
      claude_malformed(symbol: nil),
      claude_malformed(symbol: nil)
    ) do
      outcome = @strategy.propose(candidates: one_candidate, portfolio: {})
      _(outcome.enter?).must_equal false
      _(outcome.action).must_equal "no_trade"
      _(outcome.retried).must_equal true
    end
  end

  it "never retries a well-formed no_trade response" do
    calls = 0
    fake = lambda do |_body|
      calls += 1
      [claude_no_trade, { "input_tokens" => 1, "output_tokens" => 1 }, "test-model"]
    end
    @strategy.stub(:request, fake) do
      @strategy.propose(candidates: one_candidate, portfolio: {})
    end
    _(calls).must_equal 1
  end

  it "tells Claude what was wrong with its last answer on a retry, not on the first attempt" do
    bodies = []
    responses = [claude_malformed(symbol: nil), claude_malformed(symbol: "EBAY</ANT:PARAMETER>"), claude_enter("EBAY")]
    fake = lambda do |body|
      bodies << body
      [responses.shift, { "input_tokens" => 1, "output_tokens" => 1 }, "test-model"]
    end
    @strategy.stub(:request, fake) do
      @strategy.propose(candidates: one_candidate(symbol: "EBAY"), portfolio: {})
    end

    users = bodies.map { |b| b[:messages].first[:content] }
    _(users.size).must_equal 3
    _(users[0]).wont_match(/CORRECTION/)
    _(users[1]).must_match(/CORRECTION/)
    _(users[1]).must_match(/was missing/)
    _(users[2]).must_match(/was "EBAY<\/ANT:PARAMETER>"/)
    # the retry is the original request plus the note - same system prompt, tools, forced tool
    _(users[1]).must_include users[0]
    _(bodies.map { |b| b[:system] }.uniq.size).must_equal 1
    _(bodies.map { |b| b[:tool_choice] }.uniq).must_equal [{ type: "tool", name: "propose_trade" }]
  end

  it "reports how many attempts the call took" do
    stub_strategy_requests(@strategy, claude_malformed(symbol: nil), claude_enter("AAPL")) do
      _(@strategy.propose(candidates: one_candidate, portfolio: {}).attempts).must_equal 2
    end
    stub_strategy_requests(@strategy, claude_enter("AAPL")) do
      _(@strategy.propose(candidates: one_candidate, portfolio: {}).attempts).must_equal 1
    end
    _(@strategy.propose(candidates: [], portfolio: {}).attempts).must_equal 0
  end
end
