# frozen_string_literal: true

# Shared factories for spec market-data rows and canned Claude tool-call responses. Mixed into
# specs via SpecHelpers.
module Builders
  # One symbol's worth of everything MarketData/Universe need, with conservative large-cap
  # defaults so a row passes the eligibility screen unless a test overrides something on
  # purpose. Callers only need to specify what actually matters for the scenario at hand.
  def market_row(price:, ema_fast:, ema_slow:, rsi:, sector: "Information Technology",
                 market_cap: 50_000_000_000, avg_volume: 5_000_000, week_52_high: nil,
                 week_52_low: nil, dividend_yield: 1.0, earnings_days: 60)
    {
      price: price, bid: price, ask: price, prev_close: price,
      ema_fast: ema_fast, ema_slow: ema_slow, rsi: rsi,
      market_cap: market_cap, avg_volume: avg_volume,
      week_52_high: week_52_high || (price * 1.15).round(2),
      week_52_low: week_52_low || (price * 0.75).round(2),
      dividend_yield: dividend_yield, sector: sector, earnings_days: earnings_days
    }
  end

  # Satisfies TREND-PULLBACK against the real config/strategy.yml thresholds (2% band): fast EMA
  # above slow EMA, price just inside the band above the fast EMA.
  def trend_pullback_row(price: 105.0, sector: "Information Technology", **overrides)
    market_row(price: price, ema_fast: (price / 1.01).round(3), ema_slow: (price / 1.15).round(3),
               rsi: 55.0, sector: sector, **overrides)
  end

  # Satisfies MEAN-REVERSION against the real thresholds (RSI<=40, 3% support band): oversold
  # RSI, price near a rising 200-EMA, clearly outside the trend-pullback band so it only
  # qualifies via mean-reversion.
  def mean_reversion_row(price: 100.0, sector: "Health Care", **overrides)
    market_row(price: price, ema_fast: (price * 1.03).round(3), ema_slow: (price * 0.98).round(3),
               rsi: 32.0, sector: sector, **overrides)
  end

  # Satisfies neither rule: downtrend (fast EMA below slow EMA), so both rules fail at the very
  # first precondition regardless of price/RSI.
  def non_qualifying_row(price: 100.0, sector: "Materials", **overrides)
    market_row(price: price, ema_fast: (price * 0.95).round(3), ema_slow: (price * 1.02).round(3),
               rsi: 50.0, sector: sector, **overrides)
  end

  def claude_enter(symbol, rationale: "test rationale citing the rule and numbers",
                   confidence: 0.8, analysis: "test analysis reaching this conclusion")
    { "analysis" => analysis, "action" => "enter", "symbol" => symbol,
      "rationale" => rationale, "confidence" => confidence }
  end

  def claude_no_trade(closest_miss: "", confidence: 0.7,
                      analysis: "test analysis, nothing qualifies")
    { "analysis" => analysis, "action" => "no_trade", "closest_miss" => closest_miss,
      "rationale" => "", "confidence" => confidence }
  end

  # Reproduces the observed live bug (2026-09-16/17/21): the real top-level `symbol` field comes
  # back garbled (a trailing tool-call-syntax fragment) or missing outright, even though `action`
  # still says "enter" and `analysis` correctly worked out a real symbol.
  def claude_malformed(symbol: nil, confidence: 0.8)
    { "analysis" => "test analysis that concluded a real symbol qualified",
      "action" => "enter", "symbol" => symbol, "rationale" => "test", "confidence" => confidence }
  end
end
