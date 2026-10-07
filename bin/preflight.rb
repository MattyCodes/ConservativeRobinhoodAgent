#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares what the agent sends to / reads from the Robinhood MCP server with the server's own
# published tool schemas, and reports any drift. Read-only: it fetches tools/list and nothing else
# (the agent's calls are only simulated locally, see lib/preflight.rb). bin/watch.rb runs this at
# startup; run it by hand any time:
#
#   ruby bin/preflight.rb        # exit 0 = matches, 1 = drift found, 2 = server unreachable

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require_relative "../lib/preflight"

config = Config.new
result = Preflight.check(McpClient.new(url: config.mcp_url))

if result.unreachable
  warn "preflight: could not fetch the server's tool schemas (#{result.unreachable})"
  exit 2
elsif result.ok?
  puts "preflight OK: #{result.calls_checked} simulated calls and the response fields of #{result.tools_checked} tools match the server's schemas"
else
  warn "preflight FOUND DRIFT (#{result.problems.size}):"
  result.problems.each { |p| warn "  - #{p}" }
  exit 1
end
