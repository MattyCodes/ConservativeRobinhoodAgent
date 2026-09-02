# frozen_string_literal: true

require "json"
require "date"
require "time"
require "fileutils"

# Append-only event log (one JSON object per line) plus the small number of state questions
# the agent needs answered from history: what was opened today, how much cash was committed
# today, and which symbols are in a post-stop-out cool-down.
#
# The file is the durable record. If it is deleted the agent loses its memory of pacing and
# cool-downs (but Robinhood remains the source of truth for actual positions and cash).
class Journal
  def initialize(path)
    @path = path
    FileUtils.mkdir_p(File.dirname(path))
  end

  # Returns the recorded row as it would be read back: string keys (via a JSON round-trip),
  # so callers and the in-memory cache see the same shape #events produces.
  def record(event, **fields)
    json = JSON.generate({ at: Time.now.utc.iso8601, event: event.to_s }.merge(fields))
    File.open(@path, "a:utf-8") { |f| f.puts(json) }
    row = JSON.parse(json)
    @cache << row if @cache
    row
  end

  # Parsed once per process, then kept in sync by #record. The file only grows during a run
  # and only through this object, so an in-memory append is safe and avoids re-parsing a
  # multi-MB file on every pacing/cooldown query.
  def events
    @cache ||= load_events
  end

  # Number of new entries placed on `date` (local date).
  def entries_on(date)
    entries_for(date).size
  end

  # Total USD notional committed to new entries on `date`.
  def deployed_on(date)
    entries_for(date).sum { |e| e.fetch("notional", 0).to_f }
  end

  # Returns a Date (exclusive) before which `symbol` must not be re-entered, or nil.
  def cooldown_until(symbol, cooldown_days)
    stopout = events.reverse.find do |e|
      e["event"] == "position_closed" && e["symbol"] == symbol && e["reason"] == "stop_loss"
    end
    return nil unless stopout

    Date.parse(stopout["at"]) + cooldown_days
  end

  def in_cooldown?(symbol, cooldown_days, today: Date.today)
    until_date = cooldown_until(symbol, cooldown_days)
    !until_date.nil? && today < until_date
  end

  private

  def load_events
    return [] unless File.exist?(@path)

    File.foreach(@path, encoding: "bom|utf-8").map do |line|
      line = line.strip
      next if line.empty?

      begin
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end.compact
  end

  def entries_for(date)
    target = date.is_a?(String) ? date : date.iso8601
    events.select do |e|
      e["event"] == "order_placed" &&
        e["role"] == "entry" &&
        e["at"].to_s.start_with?(target)
    end
  end
end
