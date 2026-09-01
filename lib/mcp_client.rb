# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "time"
require "fileutils"

# Minimal Model Context Protocol client over Streamable HTTP (JSON-RPC 2.0). Implements only
# what this agent needs: the `initialize` handshake and `tools/call`. OAuth tokens are read
# from the file written by bin/authorize.rb and refreshed transparently on a 401.
#
# Not a general MCP implementation - no notifications, no server-initiated requests, no
# resource or prompt APIs.
class McpClient
  class Error < StandardError; end
  class AuthError < Error; end
  class RateLimited < Error; end

  PROTOCOL_VERSION = "2025-06-18"
  TOKEN_PATH = File.expand_path("~/.config/conservative-robinhood-agent/token.json")

  def initialize(url:, token_path: TOKEN_PATH, logger: nil)
    @uri = URI(url)
    @token_path = token_path
    @logger = logger
    @id = 0
    @session_id = nil
    @initialized = false
  end

  RATE_LIMIT_RE = /rate.?limit|too many requests|\b429\b/i
  RETRY_BACKOFF = [2, 5, 12].freeze # seconds; also used for a 429 HTTP response
  MIN_REQUEST_GAP = 0.35            # seconds between requests, to stay under the limit

  # Calls an MCP tool and returns its structured result. Retries transparently on rate-limit
  # (both an isError tool result and an HTTP 429). Raises McpClient::Error for any other
  # tool-level error so callers can treat a normal return as success.
  def call(tool_name, arguments = {})
    ensure_initialized

    attempt = 0
    begin
      result = rpc("tools/call", { name: tool_name, arguments: arguments })
      content = result["content"]

      if result["isError"]
        text = extract_text(content)
        raise RateLimited, text if text =~ RATE_LIMIT_RE

        raise Error, "MCP tool #{tool_name} error: #{text}"
      end

      result.key?("structuredContent") ? result["structuredContent"] : parse_content(content)
    rescue RateLimited => e
      wait = RETRY_BACKOFF[attempt]
      raise Error, "MCP tool #{tool_name} rate-limited after #{RETRY_BACKOFF.size} retries" unless wait

      attempt += 1
      @logger&.call("#{tool_name} rate-limited; retry #{attempt} in #{wait}s")
      sleep(wait)
      retry
    end
  end

  private

  def ensure_initialized
    return if @initialized

    rpc("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "ConservativeRobinhoodAgent", version: "0.1.0" }
    })
    notify("notifications/initialized")
    @initialized = true
  end

  def rpc(method, params)
    body = { jsonrpc: "2.0", id: (@id += 1), method: method, params: params }
    resp = post(JSON.generate(body), allow_refresh: true)
    message = decode(resp)

    raise Error, "JSON-RPC error on #{method}: #{message['error'].inspect}" if message["error"]

    message["result"]
  end

  def notify(method, params = {})
    post(JSON.generate({ jsonrpc: "2.0", method: method, params: params }), allow_refresh: false)
  end

  def post(payload, allow_refresh:)
    throttle

    request = Net::HTTP::Post.new(@uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json, text/event-stream"
    request["MCP-Protocol-Version"] = PROTOCOL_VERSION
    request["Authorization"] = "Bearer #{access_token}"
    request["Mcp-Session-Id"] = @session_id if @session_id
    request.body = payload

    response = http.request(request)
    @session_id ||= response["Mcp-Session-Id"]

    case response.code.to_i
    when 200, 202
      response
    when 401
      raise AuthError, "unauthorized" unless allow_refresh

      refresh_access_token!
      post(payload, allow_refresh: false)
    when 429
      raise RateLimited, "HTTP 429"
    else
      raise Error, "MCP HTTP #{response.code}: #{response.body}"
    end
  end

  # Keep at least MIN_REQUEST_GAP between outbound requests.
  def throttle
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if @last_request_at
      gap = now - @last_request_at
      sleep(MIN_REQUEST_GAP - gap) if gap < MIN_REQUEST_GAP
    end
    @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def http
    @http ||= Net::HTTP.new(@uri.host, @uri.port).tap do |h|
      h.use_ssl = @uri.scheme == "https"
      h.open_timeout = 15
      h.read_timeout = 60
    end
  end

  # A Streamable HTTP response is either a single JSON object or an SSE stream whose last
  # `data:` line carries the JSON-RPC response.
  def decode(response)
    content_type = response["Content-Type"].to_s
    raw = response.body.to_s

    if content_type.include?("text/event-stream")
      data = raw.each_line.select { |l| l.start_with?("data:") }
                .map { |l| l.sub(/\Adata:\s?/, "").chomp }.join
      raise Error, "empty SSE response" if data.empty?

      JSON.parse(data)
    elsif raw.empty?
      {}
    else
      JSON.parse(raw)
    end
  end

  def parse_content(content)
    text = extract_text(content)
    return content if text.nil? || text.empty?

    begin
      JSON.parse(text)
    rescue JSON::ParserError
      text
    end
  end

  def extract_text(content)
    Array(content).map { |part| part["text"] if part.is_a?(Hash) }.compact.join("\n")
  end

  # --- OAuth token handling ------------------------------------------------

  def token
    @token ||= begin
      raise AuthError, "no token file at #{@token_path} - run: ruby bin/authorize.rb" unless File.exist?(@token_path)

      JSON.parse(File.read(@token_path))
    end
  end

  def access_token
    refresh_access_token! if expired?
    token.fetch("access_token")
  end

  def expired?
    exp = token["expires_at"]
    exp.nil? || Time.now.to_i >= (exp.to_i - 60)
  end

  def refresh_access_token!
    rt = token["refresh_token"]
    raise AuthError, "token expired and no refresh_token - run: ruby bin/authorize.rb" unless rt

    endpoint = URI(token.fetch("token_endpoint"))
    form = {
      "grant_type" => "refresh_token",
      "refresh_token" => rt,
      "client_id" => token.fetch("client_id")
    }
    form["client_secret"] = token["client_secret"] if token["client_secret"]

    res = Net::HTTP.post_form(endpoint, form)
    raise AuthError, "refresh failed HTTP #{res.code}: #{res.body}" unless res.code.to_i == 200

    payload = JSON.parse(res.body)
    @token = token.merge(
      "access_token" => payload.fetch("access_token"),
      "refresh_token" => payload["refresh_token"] || rt,
      "expires_at" => Time.now.to_i + payload.fetch("expires_in", 3600).to_i
    )
    persist_token
    @logger&.call("refreshed Robinhood access token")
  end

  def persist_token
    FileUtils.mkdir_p(File.dirname(@token_path))
    File.open(@token_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.pretty_generate(@token))
    end
  end
end
