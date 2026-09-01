# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# Fire-and-forget status SMS via Twilio. A notification failure is logged but never aborts a
# run - losing a text must not leave an order half-managed.
class Notifier
  def initialize(config, logger: ->(_) {})
    @t = config.twilio
    @log = logger
  end

  def notify(text)
    uri = URI("https://api.twilio.com/2010-04-01/Accounts/#{@t[:sid]}/Messages.json")
    req = Net::HTTP::Post.new(uri)
    req.basic_auth(@t[:sid], @t[:token])
    req.set_form_data("From" => @t[:from], "To" => @t[:to], "Body" => text)

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
      http.request(req)
    end

    @log.("twilio send HTTP #{res.code}") unless res.code.to_i.between?(200, 299)
    res.code.to_i.between?(200, 299)
  rescue StandardError => e
    @log.("twilio send failed: #{e.class}: #{e.message}")
    false
  end
end
