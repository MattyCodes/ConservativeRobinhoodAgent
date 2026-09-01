# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"
require "time"

# Confirm-mode gate. Texts the proposed order plus a one-time code and blocks until the user
# replies "YES <code>" from their own number, or the timeout elapses. No reply -> not approved
# -> the proposal is dropped and logged. This is the human-in-the-loop step that keeps live
# trading from being fully unattended.
class Approval
  POLL_SECONDS = 15

  def initialize(config, logger: ->(_) {})
    @t = config.twilio
    @log = logger
  end

  # Returns true only on an explicit matching YES reply within timeout_seconds.
  def request_and_wait(summary, timeout_seconds:)
    code = SecureRandom.alphanumeric(4).upcase
    sent_at = Time.now.utc

    unless send_sms("PROPOSED ORDER\n#{summary}\n\nReply  YES #{code}  within " \
                    "#{(timeout_seconds / 60).to_i} min to place it. Any other reply or no reply = skip.")
      @log.("approval: could not send request SMS; treating as not approved")
      return false
    end

    deadline = Time.now + timeout_seconds
    while Time.now < deadline
      sleep(POLL_SECONDS)
      case latest_reply(since: sent_at, code: code)
      when :yes
        @log.("approval: granted")
        return true
      when :no
        @log.("approval: explicitly declined")
        return false
      end
    end

    @log.("approval: timed out after #{timeout_seconds}s")
    false
  end

  private

  def send_sms(body)
    uri = URI("https://api.twilio.com/2010-04-01/Accounts/#{@t[:sid]}/Messages.json")
    req = Net::HTTP::Post.new(uri)
    req.basic_auth(@t[:sid], @t[:token])
    req.set_form_data("From" => @t[:from], "To" => @t[:to], "Body" => body)
    res = http(uri).request(req)
    res.code.to_i.between?(200, 299)
  rescue StandardError => e
    @log.("approval SMS failed: #{e.message}")
    false
  end

  # Inbound messages are those sent FROM the user's phone TO the Twilio number. Returns
  # :yes only for an exact "YES <code>" match, :no for any other new message, nil for none.
  def latest_reply(since:, code:)
    uri = URI("https://api.twilio.com/2010-04-01/Accounts/#{@t[:sid]}/Messages.json")
    uri.query = URI.encode_www_form(
      "To" => @t[:from], "From" => @t[:to], "PageSize" => 5,
      "DateSent>=" => since.strftime("%Y-%m-%d")
    )
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(@t[:sid], @t[:token])
    res = http(uri).request(req)
    return nil unless res.code.to_i == 200

    messages = JSON.parse(res.body)["messages"] || []
    reply = messages
            .select { |m| (Time.parse(m["date_sent"]) > since rescue false) }
            .max_by { |m| (Time.parse(m["date_sent"]) rescue Time.at(0)) }
    return nil unless reply

    body = reply["body"].to_s.strip.upcase.gsub(/\s+/, " ")
    return :yes if body == "YES #{code}"

    :no
  rescue StandardError => e
    @log.("approval poll failed: #{e.message}")
    nil
  end

  def http(uri)
    Net::HTTP.new(uri.host, uri.port).tap do |h|
      h.use_ssl = true
      h.open_timeout = 10
      h.read_timeout = 15
    end
  end
end
