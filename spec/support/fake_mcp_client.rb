# frozen_string_literal: true

require "date"

# Stands in for McpClient in specs: same #call(tool_name, args) interface, answers Robinhood's
# handful of read/write tools from an in-memory per-symbol market snapshot instead of the
# network. Specs cannot accidentally reach the real Robinhood API through this - there is no
# HTTP client here at all.
class FakeMcpClient
  DEFAULT_ACCOUNT = {
    "account_number" => "TEST0001", "account_id" => "TEST0001",
    "agentic_allowed" => true, "type" => "limited_margin"
  }.freeze

  attr_reader :calls

  # symbols: { "AAPL" => market_row(...), ... } - see Builders#market_row. A symbol with no
  # entry here behaves like Robinhood has nothing for it (empty fundamentals -> Universe
  # rejects it as "no fundamentals", same as a real inactive/unresolvable ticker).
  def initialize(symbols: {}, account: DEFAULT_ACCOUNT, positions: [], portfolio: {},
                 review: {}, order_result: {})
    @symbols = symbols
    @account = account
    @positions = positions
    @portfolio = portfolio
    @review = review
    @order_result = order_result
    @calls = []
  end

  def call_count
    @calls.size
  end

  def rate_limit_hits
    0
  end

  def call(tool_name, args = {})
    @calls << [tool_name, args]

    case tool_name
    when "get_accounts" then wrap([@account])
    when "get_equity_quotes" then quote_response(args.fetch(:symbols).first)
    when "get_equity_fundamentals" then fundamentals_response(args.fetch(:symbols))
    when "get_equity_technical_indicators"
      indicator_response(args.fetch(:symbols), args.fetch(:type), args.fetch(:period))
    when "get_earnings_results" then earnings_response(args.fetch(:symbol))
    when "get_portfolio" then wrap(@portfolio)
    when "get_equity_positions" then wrap(@positions)
    when "get_equity_orders" then wrap([])
    when "review_equity_order" then wrap(@review)
    when "place_equity_order", "cancel_equity_order" then wrap(@order_result)
    else
      raise "FakeMcpClient: no stub configured for tool #{tool_name.inspect} (args=#{args.inspect})"
    end
  end

  private

  def row_for(symbol)
    @symbols[symbol]
  end

  def quote_response(symbol)
    row = row_for(symbol)
    return wrap({ "results" => [] }) unless row

    wrap({
      "results" => [{
        "quote" => {
          "last_trade_price" => row.fetch(:price).to_s,
          "bid_price" => (row[:bid] || row[:price]).to_s,
          "ask_price" => (row[:ask] || row[:price]).to_s,
          "previous_close" => (row[:prev_close] || row[:price]).to_s
        }
      }]
    })
  end

  def fundamentals_response(symbols)
    rows = symbols.filter_map do |sym|
      row = row_for(sym)
      next nil unless row

      {
        "symbol" => sym,
        "market_cap" => row[:market_cap],
        "average_volume_30_days" => row[:avg_volume],
        "high" => row[:price],
        "high_52_weeks" => row[:week_52_high],
        "low_52_weeks" => row[:week_52_low],
        "dividend_yield" => row[:dividend_yield],
        "sector" => row[:sector]
      }
    end
    wrap({ "results" => rows })
  end

  # Both EMAs are requested as type="ema" with different `period` (50 vs 200); RSI is its own
  # type. There's no real ambiguity in practice since strategy.yml's ma_fast/ma_slow periods are
  # always far apart - splitting at 100 is a safe generic threshold. Matches the live tool's
  # contract: `symbols` in (array), data.results[] out, one entry per symbol.
  def indicator_response(symbols, type, period)
    results = symbols.map do |symbol|
      row = row_for(symbol) || {}
      value =
        if type == "rsi"
          row[:rsi]
        elsif period.to_i <= 100
          row[:ema_fast]
        else
          row[:ema_slow]
        end
      { "symbol" => symbol, "interval" => "day", "bounds" => "regular",
        "indicators" => [{ "type" => type, "params" => { "period" => period },
                           "series" => [{ "begins_at" => "2026-10-06T00:00:00Z", "value" => value }] }] }
    end
    wrap({ "results" => results })
  end

  def earnings_response(symbol)
    row = row_for(symbol) || {}
    days = row[:earnings_days]
    return wrap({ "results" => [] }) if days.nil?

    wrap({ "results" => [{ "eps" => { "actual" => nil },
                           "report" => { "date" => (Date.today + days).iso8601 } }] })
  end

  # Real McpClient#call returns the tool's payload already unwrapped one level (structuredContent
  # or parsed text) - but every real Robinhood tool result is itself {"data"=>{...},"guide"=>...},
  # which is what MarketData/Broker's own `data()`/`list()` helpers expect to unwrap. Match that
  # shape here so this fake is interchangeable with the real client from the callers' point of view.
  def wrap(payload)
    { "data" => payload, "guide" => "fake tool response for specs" }
  end
end
