#!/usr/bin/env ruby
# frozen_string_literal: true

# Foreground supervisor. Keep this running in a terminal window and glance at it whenever.
# It runs one agent pass per weekday at RUN_AT (local time), sleeping in between and printing
# a readable line for every pass plus a periodic "still waiting" heartbeat.
#
#   ruby bin/watch.rb
#
# Ctrl-C stops it. Drop a file named HALT in the project root to pause passes without killing
# the watcher; delete it to resume. Env:
#   RUN_AT=10:30       local time of the daily pass (default 10:30)
#   RUN_ON_START=false skip the immediate pass on startup (default: run once right away)
#   DEBUG=1            verbose per-symbol screen logging

if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.1")
  abort "Ruby >= 3.1 required (found #{RUBY_VERSION})."
end

require_relative "../lib/agent"

RUN_DAYS = (1..5).to_a          # Mon-Fri (Time#wday: 0 = Sunday)
POLL_SECONDS = 30
HEARTBEAT_SECONDS = 1800

# Config.new populates ENV from .env, so build it before reading the watcher's own settings.
config = Config.new

RUN_AT = (ENV["RUN_AT"].to_s.strip.empty? ? "10:30" : ENV["RUN_AT"].strip)
target_h, target_m = RUN_AT.split(":").map { |n| Integer(n, 10) rescue nil }
abort "RUN_AT must be HH:MM (got #{RUN_AT.inspect})" if target_h.nil? || target_m.nil?

def stamp
  Time.now.strftime("%Y-%m-%d %H:%M:%S")
end

def say(msg)
  puts "#{stamp}  #{msg}"
  $stdout.flush
end

def next_run_time(hour, minute)
  t = Time.now
  c = Time.new(t.year, t.month, t.day, hour, minute, 0)
  c += 86_400 while c <= t || !RUN_DAYS.include?(c.wday)
  c
end

def humanize(seconds)
  s = seconds.to_i
  h = s / 3600
  m = (s % 3600) / 60
  h.positive? ? "#{h}h #{m}m" : "#{m}m"
end

trap("INT")  { puts; say "stopping (Ctrl-C)."; exit 0 }
trap("TERM") { exit 0 }

say "watcher up - #{config.dry_run? ? 'DRYRUN' : 'LIVE'}/#{config.approval_mode}" \
    "#{'/frac' if config.s(:sizing, :fractional_shares)} - daily pass at #{RUN_AT} Mon-Fri"
say "next scheduled pass: #{next_run_time(target_h, target_m).strftime('%a %Y-%m-%d %H:%M')}"

last_run_date = nil
pending_first = ENV["RUN_ON_START"] != "false"
last_heartbeat = Time.now - HEARTBEAT_SECONDS

loop do
  now = Time.now
  halted = File.exist?(File.join(Config::ROOT, "HALT"))

  due = RUN_DAYS.include?(now.wday) &&
        (now.hour > target_h || (now.hour == target_h && now.min >= target_m)) &&
        last_run_date != now.to_date

  if pending_first || due
    if halted
      say "HALT file present - skipping this pass"
    else
      say "---- pass start (#{pending_first ? 'startup' : 'scheduled'}) ----"
      agent = Agent.new(config)
      begin
        agent.run
      rescue StandardError => e
        say "   PASS ERROR: #{e.class}: #{e.message}"
      end
      lines = agent.summary
      (lines.nil? || lines.empty? ? ["no positions changed, no new entry"] : lines).each { |l| say "   #{l}" }
      say "---- pass done ----"
    end
    last_run_date = now.to_date
    pending_first = false
    say "next scheduled pass: #{next_run_time(target_h, target_m).strftime('%a %Y-%m-%d %H:%M')}"
    last_heartbeat = Time.now
  elsif Time.now - last_heartbeat >= HEARTBEAT_SECONDS
    nxt = next_run_time(target_h, target_m)
    say "waiting - next pass #{nxt.strftime('%a %H:%M')} (in #{humanize(nxt - Time.now)})#{' [HALT set]' if halted}"
    last_heartbeat = Time.now
  end

  sleep POLL_SECONDS
end
