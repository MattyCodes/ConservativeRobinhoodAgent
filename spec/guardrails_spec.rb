# frozen_string_literal: true

require_relative "spec_helper"

# Guardrails is the documented "authority" - it re-derives every entry rule and sizing cap
# independently of whatever Claude proposed. These specs exercise it directly against the real
# config/strategy.yml, with no network and no Claude involved at all.
describe Guardrails do
  include SpecHelpers

  before { @g = Guardrails.new(build_config) }

  it "accepts a trend-pullback candidate exactly at the top of its band" do
    # 50-EMA 100, 200-EMA 90, band 2% -> upper bound is exactly 102.0
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.0 },
                    portfolio: default_portfolio_state)
    _(d.ok?).must_equal true
    _(d.order.symbol).must_equal "TEST"
  end

  it "rejects a trend-pullback candidate one cent above the top of its band" do
    tech = { price: 102.01, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.01 },
                    portfolio: default_portfolio_state)
    _(d.ok?).must_equal false
    _(d.violations).must_include "no entry rule satisfied"
  end

  it "accepts a mean-reversion candidate exactly at RSI 40" do
    # 200-EMA 100, support band 3% -> valid price range [97, 106]
    tech = { price: 100.0, ema_fast: 105.0, ema_slow: 100.0, rsi: 40.0 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 100.0 },
                    portfolio: default_portfolio_state)
    _(d.ok?).must_equal true
  end

  it "rejects a mean-reversion candidate at RSI 40.1" do
    tech = { price: 100.0, ema_fast: 105.0, ema_slow: 100.0, rsi: 40.1 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 100.0 },
                    portfolio: default_portfolio_state)
    _(d.ok?).must_equal false
  end

  it "rejects any candidate in a downtrend (fast EMA below slow EMA) even with a qualifying RSI" do
    tech = { price: 100.0, ema_fast: 95.0, ema_slow: 102.0, rsi: 20.0 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 100.0 },
                    portfolio: default_portfolio_state)
    _(d.ok?).must_equal false
    _(d.violations).must_include "no entry rule satisfied"
  end

  it "rejects a symbol already held (no averaging down)" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    d = @g.evaluate(candidate: candidate(symbol: "AAPL", technicals: tech), quote: { ask: 102.0 },
                    portfolio: default_portfolio_state(open_symbols: ["AAPL"]))
    _(d.ok?).must_equal false
    _(d.violations.join).must_match(/already held/)
  end

  it "rejects a symbol still in its post-stop-out cooldown" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    d = @g.evaluate(candidate: candidate(symbol: "AAPL", technicals: tech), quote: { ask: 102.0 },
                    portfolio: default_portfolio_state(cooldown_symbols: ["AAPL"]))
    _(d.ok?).must_equal false
    _(d.violations.join).must_match(/cool-down/)
  end

  it "rejects an entry inside the earnings blackout window" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0, nearest_earnings_days: 1 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.0 },
                    portfolio: default_portfolio_state)
    _(d.ok?).must_equal false
    _(d.violations.join).must_match(/earnings blackout/)
  end

  it "allows an entry just outside the earnings blackout window" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0, nearest_earnings_days: 4 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.0 },
                    portfolio: default_portfolio_state)
    _(d.ok?).must_equal true
  end

  it "rejects a new entry at max concurrent positions" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.0 },
                    portfolio: default_portfolio_state(positions_count: 10))
    _(d.ok?).must_equal false
    _(d.violations.join).must_match(/max concurrent/)
  end

  it "rejects a new entry once the daily entry cap is reached" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.0 },
                    portfolio: default_portfolio_state(entries_today: 2))
    _(d.ok?).must_equal false
    _(d.violations.join).must_match(/daily new-entry cap/)
  end

  it "sizes a fractional entry to 10% of funded balance when nothing else binds" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.0 },
                    portfolio: default_portfolio_state(funded_balance: 1000.0, settled_cash: 1000.0))
    _(d.ok?).must_equal true
    _(d.order.order_type).must_equal "market"
    _(d.order.dollar_amount).must_equal 100.0
    _(d.order.stop_price).must_equal (102.0 * 0.93).round(2)
  end

  it "sizes down to the remaining daily-deploy room when that's the smallest cap" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    # start-of-day settled ~= settled_cash + deployed_today = 600 -> 25% = 150 allowed for the
    # day; 100 of it already spent -> only $50 of room left, well under the $100 position cap.
    portfolio = default_portfolio_state(funded_balance: 1000.0, settled_cash: 500.0,
                                        deployed_today: 100.0, entries_today: 1)
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.0 }, portfolio: portfolio)
    _(d.ok?).must_equal true
    _(d.order.dollar_amount).must_equal 50.0
  end

  it "rejects an entry that would push a sector over its cap" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    # sector cap is 25% of funded (250); already at 240, a ~$100 entry would breach it.
    portfolio = default_portfolio_state(funded_balance: 1000.0, settled_cash: 1000.0,
                                        sector_exposure: { "Information Technology" => 240.0 })
    d = @g.evaluate(candidate: candidate(sector: "Information Technology", technicals: tech),
                    quote: { ask: 102.0 }, portfolio: portfolio)
    _(d.ok?).must_equal false
    _(d.violations.join).must_match(/sector Information Technology/)
  end

  it "rejects a budget below the fractional minimum order size" do
    tech = { price: 102.0, ema_fast: 100.0, ema_slow: 90.0, rsi: 55.0 }
    portfolio = default_portfolio_state(funded_balance: 5.0, settled_cash: 5.0)
    d = @g.evaluate(candidate: candidate(technicals: tech), quote: { ask: 102.0 }, portfolio: portfolio)
    _(d.ok?).must_equal false
    _(d.violations.join).must_match(/below fractional minimum/)
  end
end
