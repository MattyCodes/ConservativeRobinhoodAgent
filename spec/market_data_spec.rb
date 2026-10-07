# frozen_string_literal: true

require_relative "spec_helper"

# Pins MarketData to the live Robinhood tool contracts (checked against the server's own
# tools/list on 2026-10-07). The 2026-10-07 outage was get_equity_technical_indicators changing
# from `symbol` to `symbols` with a results[] response - FakeMcpClient had the old shape baked
# in, so nothing failed until the live server rejected every call.
describe MarketData do
  include SpecHelpers

  # Records exactly what MarketData sends and answers in the live response shape.
  class RecordingClient
    attr_reader :sent

    def initialize(&responder)
      @responder = responder
      @sent = []
    end

    def call(tool, args = {})
      @sent << [tool, args]
      @responder.call(tool, args)
    end
  end

  def indicator_payload(*rows)
    { "data" => { "results" => rows.map { |sym, val|
      { "symbol" => sym, "indicators" => [{ "type" => "ema", "series" => [{ "value" => val }] }] }
    } } }
  end

  it "asks for technical indicators with `symbols` (an array), never `symbol`" do
    client = RecordingClient.new { |_t, _a| indicator_payload(["AAPL", 324.28]) }
    MarketData.new(client).moving_average("AAPL", period: 50)

    tool, args = client.sent.first
    _(tool).must_equal "get_equity_technical_indicators"
    _(args[:symbols]).must_equal ["AAPL"]
    _(args).wont_include :symbol
    _(args[:interval]).must_equal "day"
    _(args[:output]).must_equal "latest"
  end

  it "reads the latest value from the entry matching the requested symbol" do
    client = RecordingClient.new { |_t, _a| indicator_payload(["MSFT", 1.0], ["AAPL", 324.28]) }
    _(MarketData.new(client).moving_average("AAPL", period: 50)).must_equal 324.28
  end

  it "returns nil when the symbol is absent from the results (e.g. not_found)" do
    client = RecordingClient.new { |_t, _a| indicator_payload }
    _(MarketData.new(client).rsi("AAPL", period: 14)).must_be_nil
  end

  it "returns RSI the same way" do
    client = RecordingClient.new { |_t, _a| indicator_payload(["AAPL", 54.56]) }
    _(MarketData.new(client).rsi("AAPL", period: 14)).must_equal 54.56
  end
end
