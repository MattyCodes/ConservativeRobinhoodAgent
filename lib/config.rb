# frozen_string_literal: true

require "yaml"
require "bigdecimal"
require "bigdecimal/util"

# Loads environment (.env) and the strategy file, validates both, and exposes typed accessors.
# Fails loud: a missing credential or an out-of-range strategy value raises at startup rather
# than surfacing mid-run.
class Config
  class Error < StandardError; end

  ROOT = File.expand_path("..", __dir__)

  REQUIRED_ENV = %w[
    ANTHROPIC_API_KEY CLAUDE_MODEL
    ROBINHOOD_MCP_URL
    TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_FROM_NUMBER TWILIO_TO_NUMBER
  ].freeze

  attr_reader :strategy

  def initialize(env: ENV, strategy_path: File.join(ROOT, "config", "strategy.yml"))
    load_dotenv(File.join(ROOT, ".env"), env)
    @env = env
    @strategy = deep_freeze(YAML.load_file(strategy_path))
    validate!
  end

  # --- switches -------------------------------------------------------------

  # Safe default: a run with DRYRUN unset never places an order.
  def dry_run?
    v = @env["DRYRUN"]
    v.nil? || v.strip.empty? || v.strip.downcase != "false"
  end

  # Safe default: "confirm" requires a per-order SMS reply. "notify" is fully autonomous.
  def approval_mode
    v = (@env["APPROVAL_MODE"] || "").strip.downcase
    v == "notify" ? "notify" : "confirm"
  end

  def approval_timeout_seconds
    ((@env["APPROVAL_TIMEOUT_MINUTES"] || "15").to_i) * 60
  end

  # --- credentials / endpoints ------------------------------------------------

  def anthropic_api_key
    @env.fetch("ANTHROPIC_API_KEY")
  end

  def claude_model
    @env.fetch("CLAUDE_MODEL")
  end

  def mcp_url
    @env.fetch("ROBINHOOD_MCP_URL")
  end

  def account_number
    value_or_nil(@env["ROBINHOOD_ACCOUNT_NUMBER"])
  end

  def twilio
    {
      sid:  @env.fetch("TWILIO_ACCOUNT_SID"),
      token: @env.fetch("TWILIO_AUTH_TOKEN"),
      from: @env.fetch("TWILIO_FROM_NUMBER"),
      to:   @env.fetch("TWILIO_TO_NUMBER")
    }
  end

  # --- strategy shortcuts (all read-through to strategy.yml) ----------------

  def s(*path)
    path.reduce(@strategy) { |node, key| node.fetch(key.to_s) }
  end

  private

  def value_or_nil(str)
    return nil if str.nil?
    s = str.strip
    s.empty? ? nil : s
  end

  # Minimal .env reader: KEY=VALUE per line, # comments, no interpolation, no export.
  # Does not overwrite a variable already present in the real environment.
  def load_dotenv(path, env)
    return unless File.exist?(path)

    File.foreach(path, encoding: "bom|utf-8") do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, _, val = line.partition("=")
      key = key.strip
      next if key.empty? || env.key?(key)

      env[key] = val.strip.gsub(/\A["']|["']\z/, "")
    end
  end

  def validate!
    missing = REQUIRED_ENV.reject { |k| @env[k] && !@env[k].strip.empty? }
    raise Error, "missing env: #{missing.join(', ')}" unless missing.empty?

    raise Error, "strategy: account.cash_only must be true" unless s(:account, :cash_only) == true

    pct = ->(*p) { s(*p).to_s.to_d }
    check = lambda do |label, cond|
      raise Error, "strategy: #{label}" unless cond
    end

    check.("max_position_pct in (0,100]", pct.(:sizing, :max_position_pct).positive? && pct.(:sizing, :max_position_pct) <= 100.to_d)
    check.("max_risk_per_trade_pct in (0,100]", pct.(:sizing, :max_risk_per_trade_pct).positive? && pct.(:sizing, :max_risk_per_trade_pct) <= 100.to_d)
    check.("max_concurrent_positions >= 1", s(:sizing, :max_concurrent_positions).to_i >= 1)
    check.("stop_loss_pct in (0,50)", pct.(:exit, :stop_loss_pct).positive? && pct.(:exit, :stop_loss_pct) < 50.to_d)
    check.("profit_trigger_pct > 0", pct.(:exit, :profit_trigger_pct).positive?)
    check.("trail_pct in (0,50)", pct.(:exit, :trail_pct).positive? && pct.(:exit, :trail_pct) < 50.to_d)
    check.("time_exit_days >= 1", s(:exit, :time_exit_days).to_i >= 1)
    check.("max_new_positions_per_day >= 1", s(:pacing, :max_new_positions_per_day).to_i >= 1)
    check.("max_daily_deploy_pct in (0,100]", pct.(:pacing, :max_daily_deploy_pct).positive? && pct.(:pacing, :max_daily_deploy_pct) <= 100.to_d)
    check.("fractional_shares must be true or false", [true, false].include?(s(:sizing, :fractional_shares)))
    check.("min_order_usd > 0", pct.(:sizing, :min_order_usd).positive?)

    # position_pct * stop_loss_pct is the real loss if the stop fills at the stop price;
    # it must not exceed the stated per-trade risk budget.
    implied_risk = pct.(:sizing, :max_position_pct) * pct.(:exit, :stop_loss_pct) / 100.to_d
    check.(
      "max_position_pct(#{pct.(:sizing, :max_position_pct).to_f}) * stop_loss_pct" \
      "(#{pct.(:exit, :stop_loss_pct).to_f}) = #{implied_risk.to_f}%% exceeds " \
      "max_risk_per_trade_pct(#{pct.(:sizing, :max_risk_per_trade_pct).to_f}%%)",
      implied_risk <= pct.(:sizing, :max_risk_per_trade_pct)
    )
  end

  def deep_freeze(obj)
    case obj
    when Hash  then obj.each { |_, v| deep_freeze(v) }.freeze
    when Array then obj.each { |v| deep_freeze(v) }.freeze
    else obj.freeze
    end
  end
end
