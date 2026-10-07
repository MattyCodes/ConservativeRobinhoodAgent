# frozen_string_literal: true

require_relative "config"
require_relative "mcp_client"
require_relative "market_data"
require_relative "broker"
require_relative "guardrails"

# Catches Robinhood MCP contract drift before it costs a trading session. The server publishes
# an input and output JSON schema for every tool (tools/list); this checks the agent against them:
#
#   REQUEST side  - runs the real MarketData and Broker code against a recording client (nothing
#                   is sent anywhere), captures every tool call they actually make, and validates
#                   each call's arguments against the tool's inputSchema (unknown args, missing
#                   required args, wrong types). Derived from the code, so it can't go stale.
#   RESPONSE side - RESPONSE_PATHS lists the response fields the code reads; each must still exist
#                   in the tool's outputSchema. (Hand-maintained; spec/preflight_spec.rb fails if
#                   a tool the code calls has no entry here.)
#
# History: 2026-10-07 get_equity_technical_indicators changed `symbol` -> `symbols` and
# `indicators` -> `results[]`, silently blinding every pass until someone read the logs.
module Preflight
  Result = Struct.new(:problems, :calls_checked, :tools_checked, :unreachable, keyword_init: true) do
    def ok?
      problems.empty? && !unreachable
    end
  end

  # tool => response paths the code reads. "[]" steps into an array. A path is fine as long as it
  # resolves as far as the schema describes: an open object/array ends the check, and a field only
  # counts as missing when its parent object is closed (additionalProperties: false).
  RESPONSE_PATHS = {
    "get_accounts" => %w[data.accounts[].account_number data.accounts[].agentic_allowed data.accounts[].type],
    "get_equity_quotes" => %w[
      data.results[].quote.last_trade_price data.results[].quote.bid_price data.results[].quote.ask_price
      data.results[].quote.previous_close data.results[].close.price
    ],
    "get_equity_fundamentals" => %w[
      data.results[].symbol data.results[].market_cap data.results[].average_volume_30_days
      data.results[].high data.results[].open data.results[].high_52_weeks data.results[].low_52_weeks
      data.results[].dividend_yield data.results[].sector
    ],
    "get_equity_technical_indicators" => %w[
      data.results[].symbol data.results[].indicators[].series[].value
    ],
    "get_earnings_results" => %w[data.results[].eps.actual data.results[].report.date],
    "get_portfolio" => %w[data.total_value data.buying_power.buying_power data.buying_power.unleveraged_buying_power],
    "get_equity_positions" => %w[
      data.positions[].symbol data.positions[].quantity data.positions[].average_buy_price
      data.positions[].shares_available_for_sells
    ],
    "get_equity_orders" => %w[data.orders[].id data.orders[].state data.orders[].symbol data.orders[].side data.orders[].type],
    "review_equity_order" => %w[data.order_checks data.market_data_disclosure],
    "place_equity_order" => [],
    "cancel_equity_order" => []
  }.freeze

  # Stands in for McpClient while probing: records each call, answers with just enough shape for
  # the caller to keep going. It is the only "client" the probes ever see.
  class Recorder
    attr_reader :calls
    attr_accessor :label

    def initialize
      @calls = []
      @label = nil
    end

    def call(tool, args = {})
      @calls << { label: @label, tool: tool, args: args }
      case tool
      when "get_accounts"
        { "data" => { "accounts" => [{ "account_number" => "PROBE0001", "agentic_allowed" => true, "type" => "limited_margin" }] } }
      when "get_equity_orders"
        { "data" => { "orders" => [{ "id" => "probe-order", "state" => "queued", "symbol" => "PROBE", "side" => "sell", "type" => "stop_market" }] } }
      when "get_portfolio"
        { "data" => { "total_value" => "1", "buying_power" => { "buying_power" => "1", "unleveraged_buying_power" => "1" } } }
      else
        { "data" => { "results" => [] } }
      end
    end
  end

  # The only Config surface Broker touches in live mode.
  ProbeConfig = Struct.new(:fractional) do
    def dry_run?
      false
    end

    def account_number
      nil
    end

    def s(*path)
      raise "Preflight probe: Broker read unexpected config #{path.inspect}" unless path == %i[sizing fractional_shares]

      fractional
    end
  end

  module_function

  # Every [tool, args] the agent's MarketData and Broker would send, captured by exercising them
  # for real against a Recorder. No network.
  def probe_calls
    recorder = Recorder.new
    md = MarketData.new(recorder)
    quiet = ->(_msg) {}

    order = lambda do |type|
      Guardrails::Order.new(symbol: "PROBE", order_type: type, quantity: 1.5, dollar_amount: 10.0,
                            limit_price: 10.0, stop_price: 9.3, notional: 10.0, sector: "Probe")
    end
    fractional = Broker.new(ProbeConfig.new(true), recorder, logger: quiet)
    whole = Broker.new(ProbeConfig.new(false), recorder, logger: quiet)

    probes = {
      "MarketData#quote" => -> { md.quote("PROBE") },
      "MarketData#fundamentals_batch" => -> { md.fundamentals_batch(Array.new(11) { |i| "P#{i}" }) },
      "MarketData#moving_average" => -> { md.moving_average("PROBE", period: 50, type: "ema") },
      "MarketData#rsi" => -> { md.rsi("PROBE", period: 14) },
      "MarketData#nearest_earnings_date" => -> { md.nearest_earnings_date("PROBE") },
      "Broker#positions" => -> { fractional.positions },
      "Broker#portfolio" => -> { fractional.portfolio },
      "Broker#review_entry (market)" => -> { fractional.review_entry(order.call("market")) },
      "Broker#place_entry (market)" => -> { fractional.place_entry(order.call("market")) },
      "Broker#close_position" => -> { fractional.close_position("PROBE", 0.5, reason: "probe") },
      "Broker#review_entry (limit)" => -> { whole.review_entry(order.call("limit")) },
      "Broker#place_entry (limit)" => -> { whole.place_entry(order.call("limit")) },
      "Broker#place_stop" => -> { whole.place_stop(symbol: "PROBE", quantity: 1, stop_price: 9.3) },
      "Broker#replace_stop" => -> { whole.replace_stop(symbol: "PROBE", quantity: 1, new_stop: 9.5) },
      "Broker#cancel_order" => -> { whole.cancel_order("probe-order") }
    }
    probes.each do |label, fn|
      recorder.label = label
      fn.call
    end
    recorder.calls
  end

  # tools: the array from tools/list. Returns [problems, count_of_calls_checked].
  def validate(calls, tools)
    by_name = tools.to_h { |t| [t["name"], t] }
    problems = []

    calls.each do |c|
      tool = by_name[c[:tool]]
      if tool.nil?
        problems << "#{c[:tool]} (#{c[:label]}): the server no longer has this tool"
        next
      end
      problems.concat(request_problems(c, tool["inputSchema"] || {}))
    end

    calls.map { |c| c[:tool] }.uniq.each do |name|
      tool = by_name[name] or next
      problems.concat(response_problems(name, tool["outputSchema"]))
    end
    [problems.uniq, calls.size]
  end

  # tools_source: anything responding to #list_tools (the real McpClient). Network/auth failures
  # are reported as `unreachable` rather than raised: that is a different problem from drift.
  def check(tools_source)
    tools = tools_source.list_tools
    problems, n = validate(probe_calls, tools)
    Result.new(problems: problems, calls_checked: n, tools_checked: RESPONSE_PATHS.size, unreachable: nil)
  rescue McpClient::Error, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
    Result.new(problems: [], calls_checked: 0, tools_checked: 0, unreachable: "#{e.class}: #{e.message}")
  end

  # --- request side ---------------------------------------------------------

  def request_problems(call, schema)
    where = "#{call[:tool]} (#{call[:label]})"
    props = schema["properties"] || {}
    args = call[:args].transform_keys(&:to_s)
    problems = []

    if schema["additionalProperties"] == false
      unknown = args.keys - props.keys
      problems << "#{where}: server does not accept argument(s) #{unknown.inspect} (accepts #{props.keys.inspect})" unless unknown.empty?
    end
    missing = Array(schema["required"]) - args.keys
    problems << "#{where}: server requires argument(s) #{missing.inspect} that the agent does not send" unless missing.empty?

    args.each do |key, value|
      spec = props[key] or next
      problems.concat(type_problems("#{where}: argument #{key}", value, spec))
    end
    problems
  end

  def type_problems(where, value, spec)
    problems = []
    types = Array(spec["type"])
    if types.any? && (json_types(value) & types).empty?
      problems << "#{where}: agent sends #{json_types(value).first} (#{value.inspect[0, 30]}) but the server wants #{types.join('/')}"
    elsif value.is_a?(Array) && spec["items"].is_a?(Hash)
      value.each { |v| problems.concat(type_problems("#{where}[]", v, spec["items"])) }
    end
    if spec["enum"].is_a?(Array) && !value.nil? && !spec["enum"].include?(value)
      problems << "#{where}: #{value.inspect} is not one of #{spec['enum'].inspect}"
    end
    problems
  end

  def json_types(value)
    case value
    when nil then %w[null]
    when true, false then %w[boolean]
    when Integer then %w[integer number]
    when Float then %w[number]
    when String then %w[string]
    when Array then %w[array]
    when Hash then %w[object]
    else [value.class.to_s]
    end
  end

  # --- response side --------------------------------------------------------

  def response_problems(tool, output_schema)
    paths = RESPONSE_PATHS[tool]
    return [] if paths.nil? || paths.empty?
    return ["#{tool}: the server publishes no outputSchema, so the fields the agent reads can't be verified"] if output_schema.nil?

    paths.filter_map do |path|
      broken = first_missing_step(output_schema, path.scan(/[^.\[\]]+|\[\]/))
      "#{tool}: the agent reads response field `#{path}` but the server's schema no longer has `#{broken}`" if broken
    end
  end

  # Returns the first step that the schema says doesn't exist, or nil if the path resolves (or the
  # schema stops describing the structure, e.g. an open object).
  def first_missing_step(schema, steps)
    steps.each do |step|
      return nil unless schema.is_a?(Hash)
      return nil if schema.key?("anyOf") || schema.key?("oneOf")

      if step == "[]"
        return "[]" unless Array(schema["type"]).include?("array")

        schema = schema["items"]
      else
        return nil unless schema["properties"].is_a?(Hash)

        unless schema["properties"].key?(step)
          # Only a closed object can prove a field is gone; an open one (e.g. the indicator bar,
          # whose field names depend on the indicator) may simply not list it.
          return schema["additionalProperties"] == false ? step : nil
        end

        schema = schema["properties"][step]
      end
    end
    nil
  end
end
