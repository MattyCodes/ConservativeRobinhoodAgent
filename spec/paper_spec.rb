# frozen_string_literal: true

require_relative "spec_helper"

describe PaperLedger do
  include SpecHelpers

  def ledger(start_usd: 1000.0, quotes: {})
    @quotes = quotes
    PaperLedger.new(tmp_journal("paper"), start_usd: start_usd, quote_fn: ->(sym) { @quotes[sym] })
  end

  it "starts with full cash and no positions" do
    l = ledger
    _(l.positions).must_equal []
    _(l.portfolio[:settled_cash]).must_equal 1000.0
    _(l.portfolio[:equity]).must_equal 1000.0
  end

  it "reduces cash by the cost basis on open and marks the position to the live quote" do
    l = ledger(quotes: { "AAPL" => 110.0 })
    l.open(symbol: "AAPL", entry_price: 100.0, dollar_amount: 100.0, quantity: 1.0,
           stop_price: 93.0, sector: "Information Technology", order_type: "market")

    _(l.open?("AAPL")).must_equal true
    _(l.positions.first["symbol"]).must_equal "AAPL"
    pf = l.portfolio
    _(pf[:settled_cash]).must_equal 900.0
    _(pf[:equity]).must_equal 1010.0 # 900 cash + 1.0 share marked at 110
  end

  it "computes P&L on close and restores cash plus/minus the realized gain" do
    l = ledger(quotes: { "AAPL" => 100.0 })
    l.open(symbol: "AAPL", entry_price: 100.0, dollar_amount: 100.0, quantity: 1.0,
           stop_price: 93.0, sector: "Information Technology", order_type: "market")

    ev = l.close(symbol: "AAPL", reason: "stop_loss", exit_price: 93.0)
    _(ev["pnl_usd"]).must_equal(-7.0)
    _(ev["pnl_pct"]).must_equal(-7.0)
    _(l.open?("AAPL")).must_equal false

    pf = l.portfolio
    _(pf[:settled_cash]).must_equal 993.0 # 1000 - 100 entry + 93 back
    _(pf[:equity]).must_equal 993.0 # nothing open left to mark
  end

  it "returns nil when closing a symbol that isn't open" do
    l = ledger
    _(l.close(symbol: "NOPE", reason: "manual")).must_be_nil
  end

  it "allows re-entry into a symbol after it was closed, tracking only the new lot" do
    l = ledger(quotes: { "AAPL" => 120.0 })
    l.open(symbol: "AAPL", entry_price: 100.0, dollar_amount: 100.0, quantity: 1.0,
           stop_price: 93.0, sector: "Information Technology", order_type: "market")
    l.close(symbol: "AAPL", reason: "stop_loss", exit_price: 93.0)
    l.open(symbol: "AAPL", entry_price: 110.0, dollar_amount: 100.0, quantity: 1.0,
           stop_price: 102.3, sector: "Information Technology", order_type: "market")

    _(l.positions.size).must_equal 1
    _(l.positions.first["average_buy_price"]).must_equal 110.0
  end
end
