# frozen_string_literal: true

require "time"
require "date"

# Read-only market data, sourced entirely from the Robinhood Trading MCP (read access spans all
# accounts; no trade permission is exercised here). Every method returns plain Ruby hashes/values
# with the specific fields the screen and the strategy prompt need - nothing else is passed on.
#
# Field paths below were confirmed against live tool responses (2026-09), not guessed - each
# tool wraps its payload as {"data" => {...}, "guide" => "..."}; "guide" is display advice for
# a chat agent and is ignored here.
class MarketData
  def initialize(client)
    @client = client
  end

  # { price:, bid:, ask:, prev_close: }
  def quote(symbol)
    row = data(@client.call("get_equity_quotes", { symbols: [symbol] }))
          .fetch("results", []).first || {}
    q = row["quote"] || {}
    {
      price: num(q["last_trade_price"]),
      bid: num(q["bid_price"]),
      ask: num(q["ask_price"]),
      prev_close: num(dig(row, "close", "price") || q["previous_close"])
    }
  end

  # { market_cap:, avg_volume:, price:, week_52_high:, week_52_low:, dividend_yield:, sector: }
  # ipo/listing-date is not exposed by this tool; #ipo_date is always nil (see Universe).
  def fundamentals(symbol)
    fundamentals_batch([symbol]).fetch(symbol, {})
  end

  # Same shape as #fundamentals, keyed by symbol. Chunked to the MCP's 10-symbol limit.
  #
  # get_equity_fundamentals raises (HTTP 400) when ANY symbol in the batch is inactive/
  # unresolvable rather than just omitting it, so a chunk that fails is retried one symbol at
  # a time; a symbol that still fails is simply left out (the screen then rejects it as
  # "no fundamentals"). A 503-name list will always contain some stale tickers.
  def fundamentals_batch(symbols)
    symbols.each_slice(10).each_with_object({}) do |chunk, acc|
      begin
        rows = data(@client.call("get_equity_fundamentals", { symbols: chunk })).fetch("results", [])
      rescue McpClient::Error
        rows = chunk.flat_map { |s| fundamentals_rows_for_one(s) }
      end
      rows.each do |row|
        sym = row["symbol"]
        acc[sym] = extract_fundamentals(row) if sym
      end
    end
  end

  # Latest value of a moving average (default EMA) on daily bars.
  def moving_average(symbol, period:, type: "ema")
    indicator(symbol, type: type, period: period)
  end

  # Latest RSI on daily bars.
  def rsi(symbol, period:)
    indicator(symbol, type: "rsi", period: period)
  end

  # Nearest earnings date (past or future) as a Date, or nil. Used for the earnings blackout.
  # Prefers the one unreported (eps.actual nil) entry; falls back to the closest reported one.
  def nearest_earnings_date(symbol)
    rows = data(@client.call("get_earnings_results", { symbol: symbol })).fetch("results", [])
    upcoming = rows.find { |r| dig(r, "eps", "actual").nil? }
    target = upcoming || rows.max_by { |r| dig(r, "report", "date").to_s }
    date(dig(target || {}, "report", "date"))
  end

  private

  def fundamentals_rows_for_one(symbol)
    data(@client.call("get_equity_fundamentals", { symbols: [symbol] })).fetch("results", [])
  rescue McpClient::Error
    [] # inactive / unresolvable - drop it
  end

  def extract_fundamentals(row)
    {
      market_cap: num(row["market_cap"]),
      avg_volume: num(row["average_volume_30_days"] || row["average_volume"]),
      price: num(row["high"] || row["open"]), # approximate; only used for the coarse sub-$5 filter
      week_52_high: num(row["high_52_weeks"]),
      week_52_low: num(row["low_52_weeks"]),
      dividend_yield: num(row["dividend_yield"]),
      ipo_date: nil, # not available from this tool - see Universe's handling
      sector: row["sector"]
    }
  end

  def indicator(symbol, type:, period:)
    result = data(@client.call("get_equity_technical_indicators", {
      symbol: symbol,
      type: type,
      interval: "day",
      period: period,
      start_time: (Time.now.utc - (60 * 60 * 24 * 800)).iso8601,
      output: "latest"
    }))
    series = dig(Array(result["indicators"]).first || {}, "series") || []
    num(dig(series.last || {}, "value"))
  end

  # Every tool result is {"data" => {...}, "guide" => "..."}; return the "data" payload (or the
  # raw hash if a caller ever gets something unwrapped).
  def data(result)
    return {} unless result.is_a?(Hash)

    result["data"].is_a?(Hash) ? result["data"] : result
  end

  def dig(hash, *keys)
    keys.reduce(hash) { |h, k| h.is_a?(Hash) ? h[k] : nil }
  end

  def num(value)
    return nil if value.nil? || value == ""

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def date(value)
    return nil if value.nil? || value == ""

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
