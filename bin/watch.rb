#!/usr/bin/env ruby
# frozen_string_literal: true

# Foreground supervisor. Keep this running in a terminal window and glance at it whenever.
#   - a FULL pass (screen + Claude + position management) at each RUN_AT time on weekdays
#   - a lightweight STOP-CHECK (position management only, no Claude) every STOP_CHECK_MINUTES
#     while the market is open
# Sleeps in between, prints a line for every pass, and a "still waiting" heartbeat.
#
#   ruby bin/watch.rb
#
# Ctrl-C stops it. Drop a file named HALT in the project root to pause ALL passes (including
# stop-checks) without killing the watcher; delete it to resume. Env:
#   RUN_AT=10:30,15:30    one or more local HH:MM times for the full pass (default 10:30)
#   STOP_CHECK_MINUTES=60 interval for the stop-only check; 0 disables it (default 60)
#   MARKET_HOURS=09:30-16:00  local window the stop-check runs in (default 09:30-16:00)
#   RUN_ON_START=false    skip the immediate full pass on startup (default: run once right away)
#   DEBUG=1               verbose per-symbol screen logging

if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.1")
  abort "Ruby >= 3.1 required (found #{RUBY_VERSION})."
end

# UTF-8 regardless of the ambient locale (see main.rb).
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require_relative "../lib/agent"

RUN_DAYS = (1..5).to_a          # Mon-Fri (Time#wday: 0 = Sunday)
POLL_SECONDS = 30
HEARTBEAT_SECONDS = 1800

def hm_to_min(str)
  h, m = str.to_s.split(":", 2).map { |n| Integer(n, 10) rescue nil }
  return nil if h.nil? || m.nil? || !h.between?(0, 23) || !m.between?(0, 59)

  (h * 60) + m
end

def parse_slots(raw)
  spec = raw.to_s.strip.empty? ? "10:30" : raw.strip
  slots = spec.split(",").map(&:strip).reject(&:empty?).map do |s|
    mins = hm_to_min(s)
    abort "RUN_AT entries must be HH:MM (got #{s.inspect})" if mins.nil?

    [mins / 60, mins % 60]
  end
  abort "RUN_AT is empty" if slots.empty?
  slots.sort.uniq
end

def parse_window(raw)
  spec = raw.to_s.strip.empty? ? "09:30-16:00" : raw.strip
  a, b = spec.split("-", 2).map { |x| hm_to_min(x&.strip) }
  abort "MARKET_HOURS must be HH:MM-HH:MM (got #{spec.inspect})" if a.nil? || b.nil? || b <= a

  [a, b]
end

def fmt_slots(slots)
  slots.map { |h, m| format("%02d:%02d", h, m) }.join(", ")
end

def fmt_window(win)
  win.map { |mins| format("%02d:%02d", mins / 60, mins % 60) }.join("-")
end

# The earliest RUN_AT slot today that has already come due but hasn't been run since `after`.
def due_slot(slots, after:, now:)
  return nil unless RUN_DAYS.include?(now.wday)

  slots.each do |h, m|
    slot_t = Time.new(now.year, now.month, now.day, h, m, 0)
    return slot_t if slot_t > after && slot_t <= now
  end
  nil
end

def next_slot_time(slots)
  t = Time.now
  (0..8).flat_map do |d|
    day = t + (d * 86_400)
    next [] unless RUN_DAYS.include?(day.wday)

    slots.map { |h, m| Time.new(day.year, day.month, day.day, h, m, 0) }
  end.select { |c| c > t }.min
end

def in_window?(now, win)
  mins = (now.hour * 60) + now.min
  RUN_DAYS.include?(now.wday) && mins >= win[0] && mins < win[1]
end

def humanize(seconds)
  s = [seconds.to_i, 0].max
  h = s / 3600
  m = (s % 3600) / 60
  h.positive? ? "#{h}h #{m}m" : "#{m}m"
end

def stamp
  Time.now.strftime("%Y-%m-%d %H:%M:%S")
end

def say(msg)
  puts "#{stamp}  #{msg}"
  $stdout.flush
end

# Single-instance guard: a stray second watcher doubles the API load and corrupts the logs
# (concurrent passes). Refuse to start if another live watcher holds the pid file.
def claim_singleton!(pid_file)
  if File.exist?(pid_file)
    other = File.read(pid_file).to_i
    if other.positive? && other != Process.pid
      begin
        Process.kill(0, other)
        running = `ps -p #{other} -o command= 2>/dev/null`.include?("watch.rb")
      rescue Errno::ESRCH
        running = false
      rescue Errno::EPERM
        running = true
      end
      abort "another watcher is already running (PID #{other}). Stop it (pkill -f bin/watch.rb) or rm #{pid_file}" if running
    end
  end
  File.write(pid_file, Process.pid.to_s)
  at_exit { File.delete(pid_file) if File.exist?(pid_file) && File.read(pid_file).to_i == Process.pid }
end

def run_pass(config, scan_for_entry:, label:)
  say "---- #{label} start ----"
  agent = Agent.new(config)
  begin
    agent.run(scan_for_entry: scan_for_entry)
  rescue StandardError => e
    say "   PASS ERROR: #{e.class}: #{e.message}"
  end
  lines = agent.summary
  if scan_for_entry
    (lines.nil? || lines.empty? ? ["no positions changed, no new entry"] : lines).each { |l| say "   #{l}" }
  elsif lines && !lines.empty?
    lines.each { |l| say "   #{l}" }
  end
  say "---- #{label} done ----"
end

# Config.new populates ENV from .env, so build it before reading the watcher's own settings.
config = Config.new
SLOTS = parse_slots(ENV["RUN_AT"])
STOP_CHECK_SECONDS = (ENV["STOP_CHECK_MINUTES"].to_s.strip.empty? ? 60 : ENV["STOP_CHECK_MINUTES"].to_i) * 60
MARKET_WINDOW = parse_window(ENV["MARKET_HOURS"])

claim_singleton!(File.join(Config::ROOT, "log", "watch.pid"))

trap("INT")  { puts; say "stopping (Ctrl-C)."; exit 0 }
trap("TERM") { exit 0 }

say "watcher up - #{config.dry_run? ? 'DRYRUN' : 'LIVE'}/#{config.approval_mode}" \
    "#{'/frac' if config.s(:sizing, :fractional_shares)} - full pass at #{fmt_slots(SLOTS)} Mon-Fri" \
    "#{STOP_CHECK_SECONDS.positive? ? ", stop-check every #{STOP_CHECK_SECONDS / 60}m in #{fmt_window(MARKET_WINDOW)}" : ", stop-check disabled"}"
say "next full pass: #{next_slot_time(SLOTS).strftime('%a %Y-%m-%d %H:%M')}"

# Set to now so slots earlier today (already handled by a prior process) don't re-fire.
last_full_run_at = Time.now
last_stop_check_at = Time.now
pending_first = ENV["RUN_ON_START"] != "false"
last_heartbeat = Time.now - HEARTBEAT_SECONDS

loop do
  now = Time.now
  halted = File.exist?(File.join(Config::ROOT, "HALT"))
  slot = due_slot(SLOTS, after: last_full_run_at, now: now)
  stop_due = STOP_CHECK_SECONDS.positive? && in_window?(now, MARKET_WINDOW) &&
             (now - last_stop_check_at) >= STOP_CHECK_SECONDS

  if pending_first || slot
    if halted
      say "HALT file present - skipping full pass"
    else
      run_pass(config, scan_for_entry: true, label: "full pass (#{pending_first ? 'startup' : 'scheduled'})")
    end
    # Re-read the clock: run_pass can take a minute+, so `now` (captured at loop top) is stale.
    done = Time.now
    last_full_run_at = done
    last_stop_check_at = done # a full pass already managed positions
    pending_first = false
    last_heartbeat = done
    say "next full pass: #{next_slot_time(SLOTS).strftime('%a %Y-%m-%d %H:%M')}"
  elsif stop_due
    if halted
      say "HALT file present - skipping stop-check"
    else
      run_pass(config, scan_for_entry: false, label: "stop-check")
    end
    last_stop_check_at = Time.now
    last_heartbeat = Time.now
  elsif Time.now - last_heartbeat >= HEARTBEAT_SECONDS
    nxt = next_slot_time(SLOTS)
    extra =
      if !STOP_CHECK_SECONDS.positive?
        ""
      elsif in_window?(Time.now, MARKET_WINDOW)
        ", stop-check ~#{humanize(STOP_CHECK_SECONDS - (Time.now - last_stop_check_at))}"
      else
        ", stop-check idle until #{fmt_window(MARKET_WINDOW).split('-').first}"
      end
    say "waiting - next full pass #{nxt.strftime('%a %H:%M')} (in #{humanize(nxt - Time.now)})#{extra}#{' [HALT set]' if halted}"
    last_heartbeat = Time.now
  end

  sleep POLL_SECONDS
end
