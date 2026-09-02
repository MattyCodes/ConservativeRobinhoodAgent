# frozen_string_literal: true

require "time"

# A paper portfolio for DRY-RUN mode. Without this, every dry run starts from "0 positions" -
# the agent never simulates holding anything, so concurrent-position limits, sector caps,
# cool-downs, trailing stops, time exits, and P&L are never exercised. With it, Broker routes
# its position/portfolio reads and would-be fills here instead of to no-ops, so a week of dry
# running produces a real, reviewable track record.
#
# State lives in log/paper.jsonl as paper_opened / paper_closed events (one open position per
# symbol at a time - the strategy never averages down or re-enters a held name).
class PaperLedger
  # journal: a Journal pointed at log/paper.jsonl
  # quote_fn: ->(symbol) => last price (Float) or nil
  def initialize(journal, start_usd:, quote_fn:)
    @j = journal
    @start_usd = start_usd.to_f
    @quote = quote_fn
  end

  def start_usd
    @start_usd
  end

  # Broker-shaped open positions (what manage_open_positions iterates).
  def positions
    open_lots.map do |lot|
      {
        "symbol" => lot["symbol"],
        "quantity" => lot["quantity"],
        "shares_available_for_sells" => lot["quantity"],
        "average_buy_price" => lot["entry_price"],
        "created_at" => lot["at"]
      }
    end
  end

  # { equity:, settled_cash:, buying_power: } - cash shrinks by cost basis on open, grows back
  # plus/minus realised P&L on close; equity marks open positions to market.
  def portfolio
    lots = open_lots
    invested = lots.sum { |l| l["dollar_amount"].to_f }
    market_value = lots.sum { |l| (@quote.call(l["symbol"]) || l["entry_price"].to_f) * l["quantity"].to_f }
    realized = @j.events.select { |e| e["event"] == "paper_closed" }.sum { |e| e["pnl_usd"].to_f }
    cash = (@start_usd - invested + realized).round(2)
    { equity: (cash + market_value).round(2), settled_cash: cash, buying_power: cash }
  end

  def open?(symbol)
    open_lots.any? { |l| l["symbol"] == symbol }
  end

  def open(symbol:, entry_price:, dollar_amount:, quantity:, stop_price:, sector:, order_type:)
    @j.record("paper_opened", symbol: symbol, entry_price: round4(entry_price),
                              dollar_amount: round2(dollar_amount), quantity: round6(quantity),
                              stop_price: round4(stop_price), sector: sector, order_type: order_type)
  end

  # exit_price nil -> use the current quote. Returns the recorded event, or nil if not held.
  def close(symbol:, reason:, exit_price: nil)
    lot = open_lots.find { |l| l["symbol"] == symbol }
    return nil unless lot

    entry = lot["entry_price"].to_f
    qty = lot["quantity"].to_f
    px = (exit_price || @quote.call(symbol) || entry).to_f
    opened_at = (Time.parse(lot["at"]) rescue Time.now)
    held_days = ((Time.now - opened_at) / 86_400).round

    @j.record("paper_closed", symbol: symbol, reason: reason,
                              entry_price: round4(entry), exit_price: round4(px), quantity: round6(qty),
                              held_days: held_days, opened_at: lot["at"],
                              pnl_usd: round4((px - entry) * qty),
                              pnl_pct: entry.positive? ? round2(((px - entry) / entry) * 100) : nil)
  end

  private

  # The still-open lot per symbol: the (closes+1)-th open, if it exists.
  def open_lots
    tally = Hash.new { |h, k| h[k] = { opens: [], closes: 0 } }
    @j.events.each do |e|
      sym = e["symbol"]
      next unless sym

      tally[sym][:opens] << e if e["event"] == "paper_opened"
      tally[sym][:closes] += 1 if e["event"] == "paper_closed"
    end
    tally.each_with_object([]) do |(_sym, h), acc|
      acc << h[:opens][h[:closes]] if h[:opens].size > h[:closes]
    end
  end

  def round2(n)
    n.nil? ? nil : n.to_f.round(2)
  end

  def round4(n)
    n.nil? ? nil : n.to_f.round(4)
  end

  def round6(n)
    n.nil? ? nil : n.to_f.round(6)
  end
end
