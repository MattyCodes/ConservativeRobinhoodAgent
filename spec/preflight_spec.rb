# frozen_string_literal: true

require_relative "spec_helper"
require "preflight"

describe Preflight do
  include SpecHelpers

  # --- helpers: a synthetic "compliant server" derived from the agent's own probe calls ---------

  def json_schema_type(value)
    case value
    when String then "string"
    when Integer then "integer"
    when Float then "number"
    when Array then "array"
    when true, false then "boolean"
    else "object"
    end
  end

  def output_schema_for(paths)
    closed = -> { { "type" => "object", "properties" => {}, "additionalProperties" => false } }
    root = closed.call
    paths.each do |path|
      node = root
      path.scan(/[^.\[\]]+|\[\]/).each do |step|
        if step == "[]"
          node["type"] = %w[null array]
          node["items"] ||= closed.call
          node = node["items"]
        else
          node["properties"][step] ||= closed.call
          node = node["properties"][step]
        end
      end
    end
    root
  end

  # What a server that exactly matches the current code would publish.
  def compliant_tools(calls = Preflight.probe_calls)
    calls.group_by { |c| c[:tool] }.map do |name, group|
      props = group.flat_map { |c| c[:args].to_a }.to_h { |k, v| [k.to_s, { "type" => json_schema_type(v) }] }
      { "name" => name,
        "inputSchema" => { "type" => "object", "properties" => props, "additionalProperties" => false },
        "outputSchema" => output_schema_for(Preflight::RESPONSE_PATHS.fetch(name)) }
    end
  end

  def tool_named(tools, name)
    tools.find { |t| t["name"] == name }
  end

  # --- the probes ---------------------------------------------------------------------------

  it "captures the agent's real calls without touching the network" do
    refuse = ->(*) { raise "preflight probes must not open connections" }
    calls = Net::HTTP.stub(:new, refuse) { Net::HTTP.stub(:start, refuse) { Preflight.probe_calls } }

    tools = calls.map { |c| c[:tool] }.uniq
    _(tools).must_include "get_equity_technical_indicators"
    _(tools).must_include "place_equity_order"
    _(tools).must_include "cancel_equity_order"
  end

  it "probes every MCP tool the lib code calls, and has response paths for each" do
    called_in_code = Dir[File.join(SpecHelpers::ROOT, "lib", "*.rb")].reject { |f| f.end_with?("preflight.rb") }
                        .flat_map { |f| File.read(f, encoding: "UTF-8").scan(/\.call\("([a-z_]+)"/).flatten }.uniq
    probed = Preflight.probe_calls.map { |c| c[:tool] }.uniq

    _(called_in_code - probed).must_equal [], "tools called in lib/ but never probed by Preflight"
    _(probed - Preflight::RESPONSE_PATHS.keys).must_equal [], "probed tools with no RESPONSE_PATHS entry"
  end

  # --- request-side validation ---------------------------------------------------------------

  it "passes when the server matches what the agent sends and reads" do
    problems, checked = Preflight.validate(Preflight.probe_calls, compliant_tools)
    _(problems).must_equal []
    _(checked).must_be :>, 10
  end

  it "reproduces the 2026-10-07 outage: agent sends `symbol`, server now wants `symbols`" do
    old_call = { label: "MarketData#moving_average", tool: "get_equity_technical_indicators",
                 args: { symbol: "AAPL", type: "ema", interval: "day", period: 50 } }
    schema = { "properties" => { "symbols" => { "type" => %w[null array] }, "type" => { "type" => "string" },
                                 "interval" => { "type" => "string" }, "period" => { "type" => %w[null integer] } },
               "required" => %w[symbols type interval], "additionalProperties" => false }

    problems = Preflight.request_problems(old_call, schema)
    _(problems.join("\n")).must_match(/does not accept argument\(s\) \["symbol"\]/)
    _(problems.join("\n")).must_match(/requires argument\(s\) \["symbols"\]/)
  end

  it "flags a wrong argument type (e.g. a number where the server wants a string)" do
    call = { label: "Broker#place_entry", tool: "place_equity_order", args: { quantity: 1.5 } }
    schema = { "properties" => { "quantity" => { "type" => "string" } }, "additionalProperties" => false }
    _(Preflight.request_problems(call, schema).join).must_match(/sends number .* wants string/)
  end

  it "accepts an integer where the server wants a number, and null where null is allowed" do
    call = { label: "x", tool: "t", args: { a: 3, b: nil } }
    schema = { "properties" => { "a" => { "type" => "number" }, "b" => { "type" => %w[null array] } },
               "additionalProperties" => false }
    _(Preflight.request_problems(call, schema)).must_equal []
  end

  it "checks array item types and enums" do
    schema = { "properties" => { "symbols" => { "type" => "array", "items" => { "type" => "string" } },
                                 "side" => { "type" => "string", "enum" => %w[buy sell] } },
               "additionalProperties" => false }
    bad = { label: "x", tool: "t", args: { symbols: ["AAPL", 5], side: "hold" } }
    problems = Preflight.request_problems(bad, schema).join("\n")
    _(problems).must_match(/argument symbols\[\]: agent sends integer/)
    _(problems).must_match(/"hold" is not one of/)
  end

  it "reports a tool the server no longer offers" do
    problems, = Preflight.validate([{ label: "x", tool: "get_equity_quotes", args: {} }], [])
    _(problems.join).must_match(/get_equity_quotes .* no longer has this tool/)
  end

  # --- response-side validation ---------------------------------------------------------------

  it "flags a response field the agent reads that a closed schema no longer has" do
    tools = compliant_tools
    results = tool_named(tools, "get_equity_technical_indicators")["outputSchema"]["properties"]["data"]["properties"]
    results.delete("results") # the pre-10-07 shape had `indicators` here instead

    problems, = Preflight.validate(Preflight.probe_calls, tools)
    _(problems.join("\n")).must_match(/get_equity_technical_indicators: .* `data\.results\[\]\.symbol` .* no longer has `results`/)
  end

  it "does not call a field missing from an OPEN object a break (indicator bars vary by type)" do
    open_bar = { "type" => "object", "properties" => { "begins_at" => { "type" => "string" } } }
    schema = { "type" => "object", "additionalProperties" => false, "properties" => {
      "data" => { "type" => "object", "additionalProperties" => false, "properties" => {
        "results" => { "type" => "array", "items" => { "type" => "object", "additionalProperties" => false, "properties" => {
          "indicators" => { "type" => "array", "items" => { "type" => "object", "additionalProperties" => false, "properties" => {
            "series" => { "type" => "array", "items" => open_bar }
          } } }
        } } }
      } }
    } }
    _(Preflight.response_problems("get_equity_technical_indicators", schema)
       .grep(/series\[\]\.value/)).must_equal []
  end

  it "flags a tool with no outputSchema at all, since its fields can't be verified" do
    _(Preflight.response_problems("get_equity_quotes", nil).join).must_match(/no outputSchema/)
  end

  # --- check ----------------------------------------------------------------------------------

  Source = Struct.new(:tools, :error) do
    def list_tools
      raise error if error

      tools
    end
  end

  it "returns an ok result for a matching server" do
    result = Preflight.check(Source.new(compliant_tools))
    _(result.ok?).must_equal true
    _(result.calls_checked).must_be :>, 10
  end

  it "returns drift problems (not an exception) for a changed server" do
    tools = compliant_tools
    tool_named(tools, "get_equity_technical_indicators")["inputSchema"]["properties"].delete("symbols")
    result = Preflight.check(Source.new(tools))
    _(result.ok?).must_equal false
    _(result.problems.join).must_match(/get_equity_technical_indicators/)
  end

  it "reports an unreachable server as unreachable, not as drift" do
    [McpClient::Error.new("boom"), Errno::ECONNREFUSED.new, SocketError.new("dns")].each do |error|
      result = Preflight.check(Source.new(nil, error))
      _(result.unreachable).wont_be_nil
      _(result.problems).must_equal []
      _(result.ok?).must_equal false
    end
  end
end
