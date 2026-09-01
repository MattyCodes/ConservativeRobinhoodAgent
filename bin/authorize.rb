#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time OAuth authorization for the Robinhood Trading MCP, following the MCP Authorization
# spec: discover the protected-resource + authorization-server metadata, register a client
# dynamically (RFC 7591) if the server supports it, then run an authorization-code + PKCE flow
# with a loopback redirect. Writes ~/.config/conservative-robinhood-agent/token.json (chmod 600),
# which lib/mcp_client.rb reads and refreshes.
#
# Re-run this if the refresh token is ever rejected.

require "net/http"
require "json"
require "uri"
require "securerandom"
require "digest"
require "base64"
require "socket"
require "fileutils"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

MCP_URL = ENV["ROBINHOOD_MCP_URL"] || "https://agent.robinhood.com/mcp/trading"
TOKEN_PATH = File.expand_path("~/.config/conservative-robinhood-agent/token.json")
REDIRECT_PORT = (ENV["OAUTH_CALLBACK_PORT"] || "8765").to_i
REDIRECT_URI = "http://127.0.0.1:#{REDIRECT_PORT}/callback"

def get_json(url)
  res = Net::HTTP.get_response(URI(url))
  res.code.to_i == 200 ? JSON.parse(res.body) : nil
rescue StandardError
  nil
end

def b64url(bytes)
  Base64.urlsafe_encode64(bytes, padding: false)
end

# RFC 8414 well-known construction: the .well-known segment is INSERTED right after the
# host, not appended after the full issuer URL (e.g. issuer https://host/mcp/trading ->
# https://host/.well-known/oauth-authorization-server/mcp/trading). Several real servers
# don't follow that rule, so try the correct form first and fall back to the naive one.
def well_known_candidates(base_url, name)
  u = URI(base_url)
  [
    "#{u.scheme}://#{u.host}/.well-known/#{name}#{u.path}",
    "#{base_url.chomp('/')}/.well-known/#{name}",
    "#{u.scheme}://#{u.host}/.well-known/#{name}"
  ].uniq
end

# Preferred discovery path: an unauthenticated request to the MCP endpoint itself returns
# 401 with a WWW-Authenticate: Bearer resource_metadata="..." header pointing at the
# protected-resource metadata. Falls back to guessing the well-known path.
def discover_protected_resource(mcp_url)
  uri = URI(mcp_url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json, text/event-stream"
    req.body = JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize", params: {})
    http.request(req)
  end
  header = res["WWW-Authenticate"]
  meta_url = header && header[/resource_metadata="([^"]+)"/, 1]
  meta_url ||= well_known_candidates(mcp_url, "oauth-protected-resource").first
  get_json(meta_url)
rescue StandardError
  well_known_candidates(mcp_url, "oauth-protected-resource").each do |url|
    meta = get_json(url)
    return meta if meta
  end
  nil
end

def discover_as_metadata(issuer)
  %w[oauth-authorization-server openid-configuration].each do |name|
    well_known_candidates(issuer, name).each do |url|
      meta = get_json(url)
      return meta if meta && meta["authorization_endpoint"] && meta["token_endpoint"]
    end
  end
  nil
end

# 1. discovery ---------------------------------------------------------------
prm = discover_protected_resource(MCP_URL) || {}
issuer = (prm["authorization_servers"] || []).first || "#{URI(MCP_URL).scheme}://#{URI(MCP_URL).host}"

meta = discover_as_metadata(issuer)
abort "could not discover OAuth metadata from #{issuer}" unless meta

authorize_endpoint = meta.fetch("authorization_endpoint")
token_endpoint = meta.fetch("token_endpoint")
scopes = ENV["OAUTH_SCOPE"] || (meta["scopes_supported"] || %w[trade read]).join(" ")

# 2. client registration ---------------------------------------------------
client_id = ENV["OAUTH_CLIENT_ID"]
client_secret = ENV["OAUTH_CLIENT_SECRET"]

if client_id.nil? && meta["registration_endpoint"]
  reg = Net::HTTP.post(
    URI(meta["registration_endpoint"]),
    JSON.generate(
      client_name: "ConservativeRobinhoodAgent",
      redirect_uris: [REDIRECT_URI],
      grant_types: %w[authorization_code refresh_token],
      response_types: %w[code],
      token_endpoint_auth_method: "none",
      scope: scopes
    ),
    "Content-Type" => "application/json"
  )
  abort "dynamic registration failed HTTP #{reg.code}: #{reg.body}" unless reg.code.to_i.between?(200, 201)

  body = JSON.parse(reg.body)
  client_id = body.fetch("client_id")
  client_secret = body["client_secret"]
  puts "registered client_id=#{client_id}"
end

abort "no client_id: set OAUTH_CLIENT_ID (server has no registration endpoint)" unless client_id

# 3. authorization request (PKCE S256) -----------------------------------
verifier = b64url(SecureRandom.random_bytes(64))
challenge = b64url(Digest::SHA256.digest(verifier))
state = SecureRandom.hex(16)

auth_uri = URI(authorize_endpoint)
auth_uri.query = URI.encode_www_form(
  response_type: "code",
  client_id: client_id,
  redirect_uri: REDIRECT_URI,
  scope: scopes,
  state: state,
  code_challenge: challenge,
  code_challenge_method: "S256",
  resource: MCP_URL # RFC 8707 - bind the token to this MCP resource
)

puts "\nOpen this URL, sign in to Robinhood, and approve access to the Agentic account:\n\n#{auth_uri}\n\n"
system("open", auth_uri.to_s) if RUBY_PLATFORM.include?("darwin")

# 4. wait for the loopback redirect ------------------------------------
server = TCPServer.new("127.0.0.1", REDIRECT_PORT)
puts "listening on #{REDIRECT_URI} ..."
conn = server.accept
request_line = conn.gets.to_s
params = URI.decode_www_form(URI(request_line.split(" ")[1].to_s).query.to_s).to_h
conn.print "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nAuthorization received. You can close this tab."
conn.close
server.close

abort "state mismatch - aborting" unless params["state"] == state
abort "authorization error: #{params['error']} #{params['error_description']}" if params["error"]
code = params.fetch("code")

# 5. token exchange --------------------------------------------------
form = {
  "grant_type" => "authorization_code",
  "code" => code,
  "redirect_uri" => REDIRECT_URI,
  "client_id" => client_id,
  "code_verifier" => verifier,
  "resource" => MCP_URL
}
form["client_secret"] = client_secret if client_secret

res = Net::HTTP.post_form(URI(token_endpoint), form)
abort "token exchange failed HTTP #{res.code}: #{res.body}" unless res.code.to_i == 200
tok = JSON.parse(res.body)

record = {
  "access_token" => tok.fetch("access_token"),
  "refresh_token" => tok["refresh_token"],
  "expires_at" => Time.now.to_i + tok.fetch("expires_in", 3600).to_i,
  "token_endpoint" => token_endpoint,
  "client_id" => client_id,
  "client_secret" => client_secret,
  "scope" => tok["scope"] || scopes,
  "resource" => MCP_URL
}.compact

FileUtils.mkdir_p(File.dirname(TOKEN_PATH))
File.open(TOKEN_PATH, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.pretty_generate(record)) }

puts "\nwrote #{TOKEN_PATH}"
puts record["refresh_token"] ? "refresh token stored; the agent can run unattended." : "WARNING: no refresh_token returned - you may need to re-authorize periodically."
