# frozen_string_literal: true

require "securerandom"

# The only component that touches Robinhood's write tools. In LIVE mode it places real orders.
# In DRY-RUN mode, if a PaperLedger was supplied, position/portfolio reads and would-be fills
# are routed to the paper portfolio (so the strategy's full lifecycle is simulated); without
# one, mutating calls are logged no-ops. review_equity_order is non-mutating and always hits
# the real API, so a dry run still surfaces real quotes / buying-power / halt alerts.
class Broker
  class NotAgentic < StandardError; end

  def initialize(config, mcp_client, logger: ->(_) {}, paper: nil)
    @c = config
    @mcp = mcp_client
    @log = logger
    @paper = paper
  end

  def paper?
    @c.dry_run? && !@paper.nil?
  end

  # Resolves and caches the single agentic-tradable account, verifying it is a cash account.
  def account_number
    @account_number ||= begin
      resolved = @c.account_number || discover_account
      assert_cash_account(resolved)
      resolved
    end
  end

  def positions
    return @paper.positions if paper?

    list(@mcp.call("get_equity_positions", { account_number: account_number }))
      .reject { |p| p["quantity"].to_f.zero? }
  end

  def open_orders(symbol = nil)
    return [] if paper? # the paper ledger has no resting orders; stops are script-enforced

    rows = list(@mcp.call("get_equity_orders", { account_number: account_number }))
    rows = rows.select { |o| %w[queued confirmed partially_filled unconfirmed].include?(o["state"]) }
    symbol ? rows.select { |o| o["symbol"] == symbol } : rows
  end

  # { equity:, settled_cash:, buying_power: } - settled_cash is what guardrails may deploy.
  #
  # settled_cash is sourced from buying_power.unleveraged_buying_power rather than the plain
  # "cash" field: per Robinhood, buying_power already excludes unsettled (T+1) proceeds, and
  # the unleveraged figure is the one guaranteed not to reflect any margin extension - this
  # account is agentic_allowed but type=limited_margin, so this is the actual enforcement of
  # "never use margin" (see strategy.yml exit/pacing caps, which are always checked against
  # this number, never against a margin-inclusive buying power).
  def portfolio
    return @paper.portfolio if paper?

    p = data(@mcp.call("get_portfolio", { account_number: account_number }))
    bp = p["buying_power"].is_a?(Hash) ? p["buying_power"] : {}
    {
      equity: num(p["total_value"]),
      settled_cash: num(bp["unleveraged_buying_power"] || bp["buying_power"]),
      buying_power: num(bp["buying_power"])
    }
  end

  # Non-mutating simulation; safe in every mode. Returns Robinhood's alerts + estimated cost.
  def review_entry(order)
    @mcp.call("review_equity_order", entry_params(order))
  end

  # entry_ref_price: the price to record as the paper fill (from Guardrails - the quote used to
  # size the order). Ignored in live mode.
  def place_entry(order, entry_ref_price: nil)
    if paper?
      px = entry_ref_price || order.limit_price
      @paper.open(symbol: order.symbol, entry_price: px, dollar_amount: order.notional,
                  quantity: order.quantity, stop_price: order.stop_price,
                  sector: order.sector, order_type: order.order_type)
      @log.("PAPER entry #{order.symbol} #{order.order_type} ~$#{order.notional} @#{px}")
      return { paper: true, entry_price: px }
    end
    return dry(:entry, entry_params(order)) if @c.dry_run?

    ref = SecureRandom.uuid
    result = @mcp.call("place_equity_order", entry_params(order).merge(ref_id: ref))
    detail = order.order_type == "market" ? "$#{order.dollar_amount}" : "x#{order.quantity} @limit #{order.limit_price}"
    @log.("LIVE entry placed #{order.symbol} #{detail} ref=#{ref}")
    { placed: true, ref_id: ref, order: result }
  end

  # Native GTC stop. Not possible on a fractional position - Robinhood rejects stop orders on
  # fractional quantities - so in fractional mode this is a deliberate no-op and the stop is
  # enforced script-side by Agent (see strategy.yml sizing.fractional_shares).
  def place_stop(symbol:, quantity:, stop_price:)
    return { skipped: "paper mode - stop is script-monitored" } if paper?
    return { skipped: "fractional mode - stop is script-monitored" } if fractional?

    params = {
      account_number: account_number, symbol: symbol, side: "sell",
      type: "stop_market", stop_price: fmt(stop_price), quantity: qty_str(quantity),
      time_in_force: "gtc", market_hours: "regular_hours"
    }
    return dry(:stop, params) if @c.dry_run?

    ref = SecureRandom.uuid
    result = @mcp.call("place_equity_order", params.merge(ref_id: ref))
    @log.("LIVE stop placed #{symbol} x#{quantity} stop #{stop_price} ref=#{ref}")
    { placed: true, ref_id: ref, order: result }
  end

  def fractional?
    @c.s(:sizing, :fractional_shares) == true
  end

  def cancel_order(order_id)
    return { dry_run: true, would_cancel: order_id } if @c.dry_run?

    @mcp.call("cancel_equity_order", { account_number: account_number, order_id: order_id })
  end

  # Full-position market sell (regular hours). Used for the time-based exit and the
  # script-monitored stop. quantity may be fractional (up to 6 dp). `reason` is recorded by the
  # paper ledger and ignored live.
  def close_position(symbol, quantity, reason: "manual")
    if paper?
      ev = @paper.close(symbol: symbol, reason: reason)
      @log.("PAPER close #{symbol} (#{reason}) pnl #{ev && ev['pnl_pct']}%")
      return { paper: true, close: ev }
    end

    params = {
      account_number: account_number, symbol: symbol, side: "sell",
      type: "market", quantity: qty_str(quantity),
      time_in_force: "gfd", market_hours: "regular_hours"
    }
    return dry(:close, params) if @c.dry_run?

    ref = SecureRandom.uuid
    result = @mcp.call("place_equity_order", params.merge(ref_id: ref))
    @log.("LIVE close #{symbol} x#{qty_str(quantity)} ref=#{ref}")
    { placed: true, ref_id: ref, order: result }
  end

  # Cancels any resting sell stop on the symbol and places a fresh one at new_stop.
  def replace_stop(symbol:, quantity:, new_stop:)
    open_orders(symbol).select { |o| o["side"] == "sell" && o["type"].to_s.include?("stop") }
                       .each { |o| cancel_order(o["id"] || o["order_id"]) }
    place_stop(symbol: symbol, quantity: quantity, stop_price: new_stop)
  end

  private

  def entry_params(order)
    base = {
      account_number: account_number,
      symbol: order.symbol,
      side: "buy",
      time_in_force: "gfd",
      market_hours: "regular_hours"
    }
    if order.order_type == "market"
      base.merge(type: "market", dollar_amount: fmt(order.dollar_amount))
    else
      base.merge(type: "limit", limit_price: fmt(order.limit_price), quantity: qty_str(order.quantity))
    end
  end

  def dry(kind, params)
    @log.("DRYRUN #{kind}: #{params.reject { |k, _| k == :account_number }.to_json}")
    { dry_run: true, kind: kind, would: params }
  end

  def discover_account
    accounts = list(@mcp.call("get_accounts"))
    agentic = accounts.find { |a| a["agentic_allowed"] == true }
    raise NotAgentic, "no agentic_allowed account found" unless agentic

    agentic["account_number"] || agentic["account_id"]
  end

  # "cash-only" is enforced by ALWAYS sizing off settled_cash / unleveraged buying power
  # (see #portfolio and guardrails.rb), not by the account's Robinhood type label - Robinhood's
  # Agentic accounts are provisioned as type=limited_margin (confirmed live), which mainly
  # grants same-day settlement rather than borrowing. This check exists only to reject a
  # genuinely different account type slipping in (e.g. full "margin").
  ALLOWED_ACCOUNT_TYPES = %w[cash limited_margin].freeze

  def assert_cash_account(number)
    accounts = list(@mcp.call("get_accounts"))
    acct = accounts.find { |a| (a["account_number"] || a["account_id"]) == number } || {}
    type = acct["type"].to_s
    @log.("account #{number} type=#{type}")
    return if ALLOWED_ACCOUNT_TYPES.include?(type)

    raise NotAgentic, "account #{number} has type=#{type.inspect}, not in #{ALLOWED_ACCOUNT_TYPES}"
  end

  # Robinhood MCP tool results commonly arrive as {"data" => {...}, "guide" => "..."} - the
  # "guide" text is display advice for a chat agent, not part of the payload, so unwrap "data"
  # first and look for a named array inside (or at the top level as a fallback).
  def list(result)
    return result if result.is_a?(Array)
    return [] unless result.is_a?(Hash)

    payload = result["data"].is_a?(Hash) || result["data"].is_a?(Array) ? result["data"] : result
    return payload if payload.is_a?(Array)

    %w[results positions orders accounts].each { |k| return payload[k] if payload[k].is_a?(Array) }
    [payload]
  end

  # Every tool result is {"data" => {...}, "guide" => "..."}; return the "data" payload.
  def data(result)
    return {} unless result.is_a?(Hash)

    result["data"].is_a?(Hash) ? result["data"] : result
  end

  def num(value)
    return 0.0 if value.nil? || value == ""

    Float(value)
  rescue ArgumentError, TypeError
    0.0
  end

  def fmt(number)
    format("%.2f", number)
  end

  # Whole numbers as plain integers; otherwise up to 6 dp (Robinhood's fractional precision).
  def qty_str(q)
    f = q.to_f
    f == f.to_i ? f.to_i.to_s : format("%.6f", f)
  end
end
