# frozen_string_literal: true

require "csv"
require "date"

# Loads the constituent list (data/sp500.csv) and applies the section 1 eligibility screen:
# large-cap, liquid, not a recent IPO, not sub-$5. Sector comes from the CSV, not the API, so
# the concentration cap has a stable label to group on.
#
# Returns Candidate structs; the strategy layer only ever sees names that passed here.
class Universe
  Candidate = Struct.new(:symbol, :name, :sector, :fundamentals, keyword_init: true)

  def initialize(config, market_data, journal, logger: ->(_) {})
    @config = config
    @md = market_data
    @journal = journal
    @log = logger
  end

  def eligible
    rows = load_csv
    fundamentals = @md.fundamentals_batch(rows.map { |r| r[:symbol] })

    tally = Hash.new(0)
    passed = rows.map do |row|
      f = fundamentals[row[:symbol]] || {}
      reason = rejection_reason(f)

      if reason
        tally[reason.split.first] += 1
        @log.("screen: #{row[:symbol]} rejected (#{reason})") if ENV["DEBUG"]
        next
      end

      Candidate.new(symbol: row[:symbol], name: row[:name], sector: row[:sector], fundamentals: f)
    end.compact

    breakdown = tally.map { |k, n| "#{n} #{k}" }.join(", ")
    @log.("screen: #{passed.size}/#{rows.size} eligible#{" (rejected: #{breakdown})" unless breakdown.empty?}")
    passed
  end

  private

  def rejection_reason(f)
    u = ->(k) { @config.s(:universe, k) }

    return "no fundamentals" if f.empty? || f[:market_cap].nil? || f[:price].nil?
    return "market_cap #{f[:market_cap].to_i} < #{u.('min_market_cap_usd')}" if f[:market_cap] < u.("min_market_cap_usd")
    return "avg_volume #{f[:avg_volume].to_i} < #{u.('min_avg_daily_volume')}" if f[:avg_volume].nil? || f[:avg_volume] < u.("min_avg_daily_volume")
    return "price #{f[:price]} < #{u.('min_price')}" if f[:price] < u.("min_price")

    # get_equity_fundamentals does not expose a listing/IPO date, so this can only fire if a
    # future data source populates fundamentals[:ipo_date]. The S&P 500 restriction in
    # data/sp500.csv is the real mitigation against recent-IPO names today.
    if f[:ipo_date] && (Date.today - f[:ipo_date]).to_i < u.("min_listing_age_days")
      return "IPO #{f[:ipo_date]} within #{u.('min_listing_age_days')}d"
    end

    nil
  end

  def load_csv
    path = File.join(Config::ROOT, @config.s(:universe, :constituents_file))
    raise "constituents file not found: #{path}" unless File.exist?(path)

    CSV.foreach(path, headers: true, skip_lines: /\A\s*#/, encoding: "bom|utf-8").map do |r|
      symbol = r["symbol"] && r["symbol"].strip
      next if symbol.nil? || symbol.empty?

      { symbol: symbol, name: r["name"].to_s.strip, sector: r["sector"].to_s.strip }
    end.compact
  end
end
