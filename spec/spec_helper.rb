# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require "config"
require "journal"
require "agent"

require_relative "support/fake_mcp_client"
require_relative "support/builders"

# Mixed into every spec's top-level `describe` block with `include SpecHelpers`. Keeps every
# spec off the real log/ files and real .env/network - everything here is either an in-memory
# fake or a per-test tmp directory that gets removed in teardown.
module SpecHelpers
  include Builders

  ROOT = File.expand_path("..", __dir__)

  def tmp_dir
    @tmp_dir ||= Dir.mktmpdir("cra-spec")
  end

  def tmp_journal(name)
    Journal.new(File.join(tmp_dir, "#{name}.jsonl"))
  end

  def tmp_log_path
    File.join(tmp_dir, "run.log")
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir
  end

  # A real Config against the real config/strategy.yml (the actual file guardrails.rb enforces
  # live), with a fake .env hash so no real credentials or network config are ever touched.
  def build_config(env_overrides = {})
    env = {
      "ANTHROPIC_API_KEY" => "test-key",
      "CLAUDE_MODEL" => "claude-sonnet-5",
      "ROBINHOOD_MCP_URL" => "https://example.invalid/mcp",
      "TWILIO_ACCOUNT_SID" => "AC_test",
      "TWILIO_AUTH_TOKEN" => "test-token",
      "TWILIO_FROM_NUMBER" => "+10000000000",
      "TWILIO_TO_NUMBER" => "+10000000000",
      "DRYRUN" => "true",
      "APPROVAL_MODE" => "notify",
      "PAPER_START_USD" => "1000"
    }.merge(env_overrides)
    Config.new(env: env, strategy_path: File.join(ROOT, "config", "strategy.yml"))
  end

  # Stubs Strategy#request (the private method that makes the actual Anthropic HTTP call) to
  # return each of `raw_responses` in turn - one real API round-trip simulated per array entry,
  # letting a test drive the exact retry sequence (malformed, malformed, clean; or malformed
  # persisting through every attempt) that MAX_ATTEMPTS governs in lib/strategy.rb.
  def stub_strategy_requests(strategy, *raw_responses, &block)
    queue = raw_responses.dup
    fake_request = lambda do |_body|
      raise "test setup error: ran out of stubbed Claude responses" if queue.empty?

      [queue.shift, { "input_tokens" => 100, "output_tokens" => 200 }, "claude-sonnet-5-test"]
    end
    strategy.stub(:request, fake_request, &block)
  end

  def default_portfolio_state(overrides = {})
    {
      funded_balance: 1000.0, settled_cash: 1000.0, buying_power: 1000.0,
      open_symbols: [], positions_count: 0, sector_exposure: {},
      entries_today: 0, deployed_today: 0.0, cooldown_symbols: []
    }.merge(overrides)
  end

  def candidate(symbol: "TEST", sector: "Information Technology", technicals: {})
    { symbol: symbol, sector: sector, technicals: technicals }
  end
end

# Notifier makes a real Twilio HTTP call - specs must never trigger that. Every Agent spec
# injects this instead of a real Notifier.
class NullNotifier
  def notify(_text)
    true
  end
end
