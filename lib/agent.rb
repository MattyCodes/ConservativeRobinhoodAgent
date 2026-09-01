# frozen_string_literal: true

require "date"
require "json"
require "set"

require_relative "config"
require_relative "journal"
require_relative "mcp_client"
require_relative "market_data"
require_relative "universe"
require_relative "strategy"
require_relative "guardrails"
require_relative "broker"
require_relative "notifier"
require_relative "approval"

# One scheduled pass:
#   1. manage every open position (ensure a stop, ratchet the trailing stop, honor the time exit)
#   2. look for AT MOST ONE new entry that the strategy proposes and the guardrails allow
#
# Claude proposes; Guardrails is the authority; Broker is the only writer and is a no-op in
# dry run. Every meaningful step is journaled and (in most cases) texted.
class Agent
  MAX_ANALYZE = 30      # how many pre-ranked candidates get full technicals + go to Claude
  PULLBACK_TARGET = 0.10 # rank names ~10% below their 52-wk high first (typical healthy pullback)

  # The list of human-readable things that happened this run (also the digest SMS body).
  # Readable by bin/watch.rb after #run, even if #run raised.
  attr_reader :summary

  def initialize(config)
    @c = config
    @journal = Journal.new(File.join(Config::ROOT, "log", "journal.jsonl"))
    @log = method(:log)

    @mcp = McpClient.new(url: @c.mcp_url, logger: @log)
    @md = MarketData.new(@mcp)
    @broker = Broker.new(@c, @mcp, logger: @log)
    @universe = Universe.new(@c, @md, @journal, logger: @log)
    @strategy = Strategy.new(@c, logger: @log)
    @guardrails = Guardrails.new(@c)
    @notifier = Notifier.new(@c, logger: @log)
    @approval = Approval.new(@c, logger: @log)
  end

  def run
    @summary = []
    @journal.record("scan_started", dry_run: @c.dry_run?, approval_mode: @c.approval_mode, fractional: fractional?)

    @broker.account_number # resolve + log (with type) once, up front
    manage_open_positions
    consider_new_entry

    @journal.record("scan_finished")
  rescue StandardError => e
    @journal.record("error", klass: e.class.to_s, message: e.message, backtrace: e.backtrace&.first(5))
    (@summary ||= []) << "ERROR: #{e.class}: #{e.message}"
    raise
  ensure
    send_digest
  end

  # One SMS per run (the chosen cadence is once daily) summarising everything that happened.
  # Immediate SMS is reserved for the approval request (confirm mode), sent from Approval.
  def note(text)
    @log.(text)
    (@summary ||= []) << text
  end

  def send_digest
    lines = @summary || []
    body = lines.empty? ? "run complete — no positions changed, no new entry" : "run complete:\n- #{lines.join("\n- ")}"
    notify(body)
  end

  private

  # --- position management ------------------------------------------------

  def manage_open_positions
    positions = @broker.positions
    @log.("open positions: #{positions.size}")

    positions.each do |pos|
      symbol = pos["symbol"] || pos.dig("instrument", "symbol")
      next unless symbol

      # Prefer the sellable amount when Robinhood reports it separately (e.g. very recent
      # partial fills); fall back to total quantity.
      qty = num(pos["shares_available_for_sells"]) || pos["quantity"].to_f
      entry = num(pos["average_buy_price"] || pos["average_cost"]) || journ_entry_price(symbol)
      opened = date_of(pos["created_at"] || pos["updated_at"]) || journ_entry_date(symbol)
      price = @md.quote(symbol)[:price]
      next unless entry && price && qty.positive?

      next if handle_time_exit(symbol, qty, opened)

      if fractional?
        enforce_script_stop(symbol, qty, entry, price)
      else
        ensure_and_ratchet_stop(symbol, qty, entry, price)
      end
    end
  end

  def handle_time_exit(symbol, qty, opened)
    return false unless opened

    age = (Date.today - opened).to_i
    return false if age < @c.s(:exit, :time_exit_days)

    @log.("time exit #{symbol} (age #{age}d)")
    cancel_sell_orders(symbol)
    result = @broker.close_position(symbol, qty)
    @journal.record("position_closed", symbol: symbol, reason: "time_exit", age_days: age, result: result)
    note("time exit: sell #{qfmt(qty)} #{symbol} (held #{age}d)#{' [dry]' if @c.dry_run?}")
    true
  end

  # The stop level for a position: the fixed stop, or - once up profit_trigger_pct - a
  # trailing stop trail_pct below the high-water mark, whichever is higher. Never lowered.
  def stop_level(symbol, entry, price)
    hard = round2(entry * (1 - pct(@c.s(:exit, :stop_loss_pct))))
    return hard if (price - entry) / entry < pct(@c.s(:exit, :profit_trigger_pct))

    high_water = [journ_high_water(symbol), price].compact.max
    @journal.record("high_water", symbol: symbol, high_water: high_water) if high_water == price
    [hard, round2(high_water * (1 - pct(@c.s(:exit, :trail_pct))))].max
  end

  # Whole-share mode: keep a native GTC stop order in place and ratchet it upward.
  def ensure_and_ratchet_stop(symbol, qty, entry, price)
    desired = stop_level(symbol, entry, price)
    resting = current_stop_price(symbol)

    if resting.nil?
      out = @broker.place_stop(symbol: symbol, quantity: qty.to_i, stop_price: desired)
      @journal.record("stop_placed", symbol: symbol, stop_price: desired, result: out)
      note("placed missing stop #{symbol} @ #{fmt(desired)}#{' [dry]' if @c.dry_run?}")
    elsif desired > resting + 0.01
      out = @broker.replace_stop(symbol: symbol, quantity: qty.to_i, new_stop: desired)
      @journal.record("stop_replaced", symbol: symbol, from: resting, to: desired, result: out)
      note("ratcheted stop #{symbol} #{fmt(resting)} -> #{fmt(desired)}#{' [dry]' if @c.dry_run?}")
    end
  end

  # Fractional mode: no native stop is possible, so check the level HERE and market-sell if
  # breached. Only as timely as the run cadence - a gap down between runs is not caught until
  # the next run.
  def enforce_script_stop(symbol, qty, entry, price)
    level = stop_level(symbol, entry, price)
    hard = round2(entry * (1 - pct(@c.s(:exit, :stop_loss_pct))))

    if price <= level
      cancel_sell_orders(symbol)
      result = @broker.close_position(symbol, qty)
      reason = price <= hard ? "stop_loss" : "trailing_stop"
      @journal.record("position_closed", symbol: symbol, reason: reason, price: price,
                                         stop_level: level, result: result)
      note("SCRIPT STOP #{symbol}: #{fmt(price)} <= #{fmt(level)} (#{reason}) - closing #{qfmt(qty)}#{' [dry]' if @c.dry_run?}")
    else
      @journal.record("stop_tracked", symbol: symbol, stop_level: level, price: price)
      @log.("#{symbol} script stop #{fmt(level)}, price #{fmt(price)} (#{(((price - level) / price) * 100).round(1)}% above)")
    end
  end

  def cancel_sell_orders(symbol)
    @broker.open_orders(symbol).select { |o| o["side"] == "sell" }
           .each { |o| @broker.cancel_order(o["id"] || o["order_id"]) }
  end

  def current_stop_price(symbol)
    stop = @broker.open_orders(symbol).find { |o| o["side"] == "sell" && o["type"].to_s.include?("stop") }
    stop && num(stop["stop_price"])
  end

  # --- new entry --------------------------------------------------------

  def consider_new_entry
    portfolio = build_portfolio_state
    if portfolio[:entries_today] >= @c.s(:pacing, :max_new_positions_per_day)
      @log.("daily entry cap reached; no new entry")
      return
    end
    if portfolio[:positions_count] >= @c.s(:sizing, :max_concurrent_positions)
      @log.("at max concurrent positions; no new entry")
      return
    end

    candidates = screened_candidates(portfolio)
    if candidates.empty?
      @journal.record("no_trade", why: "no candidates after screen/exclusions")
      note("no eligible candidates this run")
      return
    end

    outcome = @strategy.propose(candidates: candidates.map { |c| present(c) }, portfolio: portfolio)
    unless outcome.enter?
      miss = outcome.closest_miss.to_s.strip
      @journal.record("no_trade", why: "strategy returned no_trade", closest_miss: miss,
                                  confidence: outcome.confidence, considered: candidates.map { |c| c[:symbol] })
      note("no trade (#{candidates.size} considered)#{" — closest: #{miss}" unless miss.empty?}")
      return
    end
    proposal = outcome.proposal

    picked = candidates.find { |c| c[:symbol] == proposal.symbol }
    unless picked
      @journal.record("proposal_rejected", symbol: proposal.symbol, why: "not in candidate set")
      note("rejected #{proposal.symbol}: off-list proposal")
      return
    end

    decision = @guardrails.evaluate(
      candidate: { symbol: picked[:symbol], sector: picked[:sector], technicals: picked[:technicals] },
      quote: { ask: @md.quote(picked[:symbol])[:ask] },
      portfolio: portfolio
    )

    unless decision.ok?
      @journal.record("guardrail_block", symbol: proposal.symbol, violations: decision.violations,
                                          rationale: proposal.rationale)
      note("blocked #{proposal.symbol}: #{decision.violations.join('; ')}")
      return
    end

    execute(decision.order, proposal)
  end

  def execute(order, proposal)
    review = safe_review(order)
    summary = order_summary(order, proposal, review)
    @journal.record("proposal_passed", order: order.to_h, rationale: proposal.rationale,
                                       confidence: proposal.confidence, review: review)

    if @c.approval_mode == "confirm"
      unless @approval.request_and_wait(summary, timeout_seconds: @c.approval_timeout_seconds)
        @journal.record("approval_denied", symbol: order.symbol)
        note("not approved in time — #{order.symbol} skipped")
        return
      end
    else
      note("AUTO-PLACING (notify mode):\n#{summary}")
    end

    entry_result = @broker.place_entry(order)

    # Whole-share entries get a native stop right away; fractional entries can't, so the stop
    # is tracked script-side starting on the next run (once the fill price is known).
    stop_result =
      if order.order_type == "market"
        { script_monitored: true, level: order.stop_price }
      else
        @broker.place_stop(symbol: order.symbol, quantity: order.quantity, stop_price: order.stop_price)
      end

    # Reference entry price for later stop math if Robinhood doesn't report average_buy_price.
    entry_price = order.limit_price || (order.quantity.to_f.positive? ? (order.notional / order.quantity).round(2) : nil)

    @journal.record("order_placed", role: "entry", symbol: order.symbol, order_type: order.order_type,
                                    quantity: order.quantity, dollar_amount: order.dollar_amount,
                                    limit_price: order.limit_price, entry_price: entry_price,
                                    stop_price: order.stop_price, notional: order.notional, sector: order.sector,
                                    dry_run: @c.dry_run?, entry_result: entry_result, stop_result: stop_result)

    verb = @c.dry_run? ? "DRYRUN would place" : "PLACED"
    size = order.order_type == "market" ? "$#{fmt(order.dollar_amount)}" : "#{order.quantity} sh @#{fmt(order.limit_price)}"
    stop_note = order.order_type == "market" ? "script-stop ~#{fmt(order.stop_price)}" : "stop #{fmt(order.stop_price)}"
    note("#{verb}: buy #{size} #{order.symbol} (#{stop_note})")
  end

  # --- state assembly --------------------------------------------------

  def build_portfolio_state
    pf = @broker.portfolio
    positions = @broker.positions
    sector_map = universe_sector_map
    open_symbols = positions.map { |p| p["symbol"] }.compact

    sector_exposure = Hash.new(0.0)
    positions.each do |p|
      mv = num(p["market_value"]) || (num(p["quantity"]).to_f * (@md.quote(p["symbol"])[:price] || 0))
      sector_exposure[sector_map[p["symbol"]] || "Unknown"] += mv
    end

    funded = pf[:equity].positive? ? pf[:equity] : (pf[:settled_cash] + sector_exposure.values.sum)
    today = Date.today.iso8601

    {
      funded_balance: funded.round(2),
      settled_cash: pf[:settled_cash].round(2),
      buying_power: pf[:buying_power].round(2),
      positions_count: positions.size,
      open_symbols: open_symbols,
      sector_exposure: sector_exposure.transform_values { |v| v.round(2) },
      entries_today: @journal.entries_on(today),
      deployed_today: @journal.deployed_on(today).round(2),
      cooldown_symbols: cooldown_symbols
    }
  end

  def screened_candidates(portfolio)
    excluded = (portfolio[:open_symbols] + portfolio[:cooldown_symbols]).to_set
    full = @c.s(:sizing, :max_sector_pct)
    capped_sectors = portfolio[:sector_exposure]
                     .select { |_, v| v >= portfolio[:funded_balance] * full / 100.0 }.keys.to_set

    eligible = @universe.eligible.reject do |cand|
      excluded.include?(cand.symbol) || capped_sectors.include?(cand.sector)
    end

    # Cheap pre-rank (uses fundamentals already fetched for the whole screen) so the expensive
    # technical analysis and Claude see the names most likely to be in a pullback - not just the
    # alphabetically-first ones. Both entry styles want a pullback; extended names and broken
    # names both rank low. Down-trends among these are filtered later by the EMA-cross rule.
    ranked = eligible.sort_by { |cand| pullback_rank(cand.fundamentals) }
    @log.("analysing top #{[MAX_ANALYZE, ranked.size].min} of #{ranked.size} by pullback depth")
    ranked.first(MAX_ANALYZE).map { |cand| attach_technicals(cand) }.compact
  end

  # Distance of the 52-week drawdown from PULLBACK_TARGET; lower = closer to a healthy pullback.
  def pullback_rank(f)
    hi = f[:week_52_high]
    px = f[:price]
    return 1.0 unless hi && px && hi.positive?

    ((hi - px) / hi - PULLBACK_TARGET).abs
  end

  def attach_technicals(cand)
    q = @md.quote(cand.symbol)
    price = q[:price] || cand.fundamentals[:price]
    return nil unless price

    earnings = @md.nearest_earnings_date(cand.symbol)
    {
      symbol: cand.symbol,
      name: cand.name,
      sector: cand.sector,
      technicals: {
        price: price,
        ema_fast: @md.moving_average(cand.symbol, period: @c.s(:entry, :ma_fast_period), type: @c.s(:entry, :ma_type)),
        ema_slow: @md.moving_average(cand.symbol, period: @c.s(:entry, :ma_slow_period), type: @c.s(:entry, :ma_type)),
        rsi: @md.rsi(cand.symbol, period: @c.s(:entry, :rsi_period)),
        week_52_high: cand.fundamentals[:week_52_high],
        week_52_low: cand.fundamentals[:week_52_low],
        pct_below_52w_high: pct_below_high(cand.fundamentals[:week_52_high], price),
        nearest_earnings_days: earnings && (earnings - Date.today).to_i
      }
    }
  rescue McpClient::Error => e
    @log.("technicals #{cand.symbol} failed: #{e.message}")
    nil
  end

  def present(cand)
    cand.slice(:symbol, :name, :sector, :technicals)
  end

  def pct_below_high(hi, px)
    return nil unless hi && px && hi.positive?

    (((hi - px) / hi) * 100).round(1)
  end

  # --- journal-derived helpers ---------------------------------------

  def cooldown_symbols
    cd = @c.s(:pacing, :stopout_cooldown_days)
    universe_sector_map.keys.select { |sym| @journal.in_cooldown?(sym, cd) }
  end

  def journ_entry_price(symbol)
    ev = @journal.events.reverse.find { |e| e["event"] == "order_placed" && e["symbol"] == symbol && e["role"] == "entry" }
    ev && (num(ev["entry_price"]) || num(ev["limit_price"]))
  end

  def journ_entry_date(symbol)
    ev = @journal.events.reverse.find { |e| e["event"] == "order_placed" && e["symbol"] == symbol && e["role"] == "entry" }
    ev && date_of(ev["at"])
  end

  def journ_high_water(symbol)
    ev = @journal.events.reverse.find { |e| e["event"] == "high_water" && e["symbol"] == symbol }
    ev && num(ev["high_water"])
  end

  # --- misc ------------------------------------------------------------

  def universe_sector_map
    @universe_sector_map ||= begin
      path = File.join(Config::ROOT, @c.s(:universe, :constituents_file))
      require "csv"
      CSV.foreach(path, headers: true, skip_lines: /\A\s*#/, encoding: "bom|utf-8").each_with_object({}) do |r, h|
        h[r["symbol"].to_s.strip] = r["sector"].to_s.strip unless r["symbol"].to_s.strip.empty?
      end
    end
  end

  def safe_review(order)
    res = @broker.review_entry(order)
    res.is_a?(Hash) && res["data"].is_a?(Hash) ? res["data"] : res
  rescue McpClient::Error => e
    { "review_error" => e.message }
  end

  def order_summary(order, proposal, review)
    line =
      if order.order_type == "market"
        "market $#{fmt(order.dollar_amount)}  (~#{qfmt(order.quantity)} sh)  script-stop ~#{fmt(order.stop_price)}"
      else
        "limit #{fmt(order.limit_price)} x#{order.quantity}  stop #{fmt(order.stop_price)}  notional #{fmt(order.notional)}"
      end

    checks = review.is_a?(Hash) ? review["order_checks"] : nil
    alerts = checks.is_a?(Hash) && !checks.empty? ? "\nALERTS: #{checks.inspect}" : ""
    disclosure = review.is_a?(Hash) ? review["market_data_disclosure"] : nil

    <<~TXT.strip
      BUY #{order.symbol} (#{order.sector})
      #{line}#{alerts}
      why: #{proposal.rationale}
      confidence #{proposal.confidence}#{"\n#{disclosure}" if disclosure}
    TXT
  end

  def fractional?
    @c.s(:sizing, :fractional_shares) == true
  end

  def qfmt(q)
    f = q.to_f
    f == f.to_i ? f.to_i.to_s : format("%.6f", f).sub(/0+\z/, "")
  end

  def mode_label
    "#{@c.dry_run? ? 'DRYRUN' : 'LIVE'}/#{@c.approval_mode}#{'/frac' if fractional?}"
  end

  def notify(text)
    @notifier.notify("[CRA #{mode_label}] #{text}")
  end

  def log(msg)
    line = "#{Time.now.strftime('%H:%M:%S')} #{msg}"
    puts line
    File.open(File.join(Config::ROOT, "log", "run.log"), "a") { |f| f.puts(line) }
  end

  def num(v)
    return nil if v.nil? || v == ""

    Float(v)
  rescue ArgumentError, TypeError
    nil
  end

  def date_of(v)
    return nil if v.nil?

    Date.parse(v.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def pct(whole)
    whole.to_f / 100.0
  end

  def round2(n)
    (n * 100).round / 100.0
  end

  def fmt(n)
    format("%.2f", n)
  end
end
