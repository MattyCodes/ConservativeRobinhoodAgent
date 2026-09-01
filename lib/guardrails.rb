# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

# The authority. Claude's proposal is a suggestion; this class independently re-derives whether
# an entry is allowed and, if so, exactly how big it is. Nothing reaches the broker without an
# ok? Decision from here.
#
# All money math is BigDecimal. Every rejection is collected (not short-circuited) so the
# journal shows every reason a proposal failed.
#
# Two sizing modes (config sizing.fractional_shares):
#   whole-share  -> Order.order_type "limit", integer quantity, marketable limit price
#   fractional   -> Order.order_type "market", Order.dollar_amount set, quantity is the
#                   approximate fractional share count (informational only)
class Guardrails
  Decision = Struct.new(:ok, :violations, :order, keyword_init: true) do
    def ok?
      ok
    end
  end

  Order = Struct.new(:symbol, :order_type, :quantity, :dollar_amount, :limit_price,
                     :stop_price, :notional, :sector, keyword_init: true)

  def initialize(config)
    @c = config
  end

  # candidate: { symbol:, sector:, technicals: { price:, ema_fast:, ema_slow:, rsi:,
  #              nearest_earnings_days: } }
  # quote:     { ask: }   (falls back to technicals.price)
  # portfolio: { funded_balance:, settled_cash:, open_symbols: [], positions_count:,
  #              sector_exposure: { "Sector" => usd }, entries_today:, deployed_today:,
  #              cooldown_symbols: [] }
  def evaluate(candidate:, quote:, portfolio:)
    v = []
    sym = candidate[:symbol]
    t = candidate[:technicals] || {}
    ask = dec(quote[:ask]) || dec(t[:price])

    v << "no ask/price available" if ask.nil? || ask <= 0
    v << "symbol #{sym} already held (no averaging down)" if portfolio[:open_symbols].include?(sym)
    v << "symbol #{sym} in post-stop-out cool-down" if portfolio[:cooldown_symbols].include?(sym)

    if portfolio[:positions_count] >= @c.s(:sizing, :max_concurrent_positions)
      v << "at max concurrent positions (#{portfolio[:positions_count]})"
    end
    if portfolio[:entries_today] >= @c.s(:pacing, :max_new_positions_per_day)
      v << "daily new-entry cap reached (#{portfolio[:entries_today]})"
    end

    ed = t[:nearest_earnings_days]
    if !ed.nil? && ed.abs <= @c.s(:entry, :earnings_blackout_days)
      v << "within earnings blackout (#{ed}d)"
    end

    v << "no entry rule satisfied" unless ask && entry_rule_met?(t, ask)

    return Decision.new(ok: false, violations: v, order: nil) unless v.empty? && ask

    order, sizing_violations = size(sym, candidate[:sector], ask, portfolio)
    v.concat(sizing_violations)

    return Decision.new(ok: false, violations: v, order: nil) unless v.empty?

    Decision.new(ok: true, violations: [], order: order)
  end

  private

  # Trend-following OR mean-reversion, both requiring an intact up-trend (fast EMA above slow).
  def entry_rule_met?(t, price)
    fast = dec(t[:ema_fast])
    slow = dec(t[:ema_slow])
    rsi  = dec(t[:rsi])
    return false if fast.nil? || slow.nil? || rsi.nil?

    return false unless fast > slow # up-trend intact

    pull_band = pct(@c.s(:entry, :trend_pullback_band_pct))
    supp_band = pct(@c.s(:entry, :meanrev_support_band_pct))

    trend_entry = price > slow && price >= fast && price <= fast * (1 + pull_band)
    meanrev_entry = rsi <= dec(@c.s(:entry, :rsi_entry_max)) &&
                    price >= slow * (1 - supp_band) &&
                    price <= slow * (1 + supp_band * 2)

    trend_entry || meanrev_entry
  end

  # Returns [Order, []] on success or [nil, [violations]]. The dollar budget is derived
  # identically for both modes; only how it becomes an order differs.
  def size(symbol, sector, price, portfolio)
    funded = dec(portfolio[:funded_balance])
    settled = dec(portfolio[:settled_cash])

    position_cap = funded * pct(@c.s(:sizing, :max_position_pct))

    # Notional whose worst-case stop-out loss equals the per-trade risk budget.
    risk_cap = funded * pct(@c.s(:sizing, :max_risk_per_trade_pct)) / pct(@c.s(:exit, :stop_loss_pct))

    # Approximate start-of-day settled cash as what is left plus what was already committed today.
    day_reference = settled + dec(portfolio[:deployed_today])
    daily_room = day_reference * pct(@c.s(:pacing, :max_daily_deploy_pct)) - dec(portfolio[:deployed_today])

    budget = [position_cap, risk_cap, daily_room, settled].min

    order = fractional? ? build_fractional(symbol, sector, price, budget) : build_whole_share(symbol, sector, price, budget)
    return order if order[1].any? # [nil, violations]

    o = order[0]
    v = []
    sector_now = dec(portfolio.dig(:sector_exposure, sector) || 0)
    sector_cap = funded * pct(@c.s(:sizing, :max_sector_pct))
    if sector_now + dec(o.notional) > sector_cap
      v << "sector #{sector} would reach $#{(sector_now + dec(o.notional)).to_f.round(0)} > cap $#{sector_cap.to_f.round(0)}"
    end
    v << "notional $#{o.notional} exceeds settled cash $#{settled.to_f.round(2)}" if dec(o.notional) > settled

    v.empty? ? [o, []] : [nil, v]
  end

  def build_fractional(symbol, sector, price, budget)
    dollars = budget.floor(2)
    min = dec(@c.s(:sizing, :min_order_usd))
    if dollars < min
      return [nil, ["budget $#{budget.to_f.round(2)} below fractional minimum $#{min.to_f} " \
                    "(#{caps_note(price, budget)})"]]
    end

    stop_price = round_cent(price * (1 - pct(@c.s(:exit, :stop_loss_pct))))
    [Order.new(
      symbol: symbol, order_type: "market",
      quantity: (dollars / price).round(6).to_f, # approximate; the broker sends dollars, not shares
      dollar_amount: dollars.to_f,
      limit_price: nil,
      stop_price: stop_price.to_f,
      notional: dollars.to_f,
      sector: sector
    ), []]
  end

  def build_whole_share(symbol, sector, ask, budget)
    quantity = (budget / ask).floor
    return [nil, ["budget $#{budget.to_f.round(2)} < 1 share at $#{ask.to_f.round(2)} (#{caps_note(ask, budget)})"]] if quantity < 1

    limit_price = round_cent(ask * (1 + bps(@c.s(:entry, :marketable_limit_slippage_bps))))
    stop_price = round_cent(limit_price * (1 - pct(@c.s(:exit, :stop_loss_pct))))

    [Order.new(
      symbol: symbol, order_type: "limit",
      quantity: quantity.to_i,
      dollar_amount: nil,
      limit_price: limit_price.to_f,
      stop_price: stop_price.to_f,
      notional: (limit_price * quantity).to_f,
      sector: sector
    ), []]
  end

  def caps_note(price, budget)
    "price $#{price.to_f.round(2)}, budget $#{budget.to_f.round(2)}"
  end

  def fractional?
    @c.s(:sizing, :fractional_shares) == true
  end

  def dec(value)
    return nil if value.nil? || value == ""

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def pct(whole)
    BigDecimal(whole.to_s) / 100
  end

  def bps(whole)
    BigDecimal(whole.to_s) / 10_000
  end

  def round_cent(bd)
    bd.round(2)
  end
end
