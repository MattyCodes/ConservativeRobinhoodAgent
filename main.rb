#!/usr/bin/env ruby
# frozen_string_literal: true

# Entrypoint for one scheduled pass. Safe by default: with DRYRUN unset and APPROVAL_MODE unset
# this screens, asks Claude, evaluates guardrails, and texts you — but places no orders.
#
#   ruby main.rb                                    # dry run, confirm mode
#   DRYRUN=false ruby main.rb                       # live; every order needs an SMS reply
#   DRYRUN=false APPROVAL_MODE=notify ruby main.rb  # fully autonomous (deliberate)

if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.1")
  abort "Ruby >= 3.1 required (found #{RUBY_VERSION}). Install a current Ruby; the macOS system Ruby will not work."
end

require_relative "lib/agent"

ROOT = File.expand_path(__dir__)

# Kill switch: presence of a HALT file stops the agent before it does anything.
if File.exist?(File.join(ROOT, "HALT"))
  warn "HALT file present — exiting without action."
  exit 3
end

config = Config.new

puts "ConservativeRobinhoodAgent — #{config.dry_run? ? 'DRYRUN' : 'LIVE'} / #{config.approval_mode} mode"

begin
  Agent.new(config).run
  exit 0
rescue Config::Error => e
  warn "config error: #{e.message}"
  exit 2
rescue StandardError => e
  warn "run failed: #{e.class}: #{e.message}"
  exit 1
end
