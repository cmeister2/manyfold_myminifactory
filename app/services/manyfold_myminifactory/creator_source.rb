# frozen_string_literal: true

require "uri"

module ManyfoldMyminifactory
  class CreatorSource
    MAX_USERNAME_BYTES = 512
    PROFILE_PATH = %r{\A/(?:users|profile)/([^/]+)(?:/store)?/?\z}
    MESSAGE = "Enter a MyMiniFactory creator profile URL."

    class Invalid < StandardError; end

    attr_reader :uri, :username

    def initialize(value)
      text = value.to_s
      unless text.valid_encoding? && text.bytesize.between?(1, 4096) && !text.match?(/[[:cntrl:]]/)
        raise Invalid, MESSAGE
      end

      parsed = URI.parse(text.strip)
      raise Invalid, MESSAGE unless self.class.valid_uri?(parsed)
      match = parsed.path.match(PROFILE_PATH)
      raise Invalid, MESSAGE unless match

      @username = URI::DEFAULT_PARSER.unescape(match[1]).force_encoding(Encoding::UTF_8)
      raise Invalid, MESSAGE unless self.class.valid_username?(@username)

      @uri = self.class.profile_url(@username)
    rescue URI::InvalidURIError, URI::InvalidComponentError, ArgumentError
      raise Invalid, MESSAGE, cause: nil
    end

    def matches?(payload)
      other = self.class.from_payload(payload)
      username.casecmp?(other.username)
    rescue Invalid
      false
    end

    def self.from_payload(payload)
      unless payload.is_a?(Hash) && valid_username?(payload["username"])
        raise Invalid, "MyMiniFactory returned an incomplete creator profile."
      end

      username = payload["username"]
      profile = payload["profile_url"]
      unless profile.nil?
        unless profile.is_a?(String) && new(profile).username.casecmp?(username)
          raise Invalid, "MyMiniFactory returned an unexpected creator profile."
        end
      end
      new(profile_url(username))
    end

    def self.linked?(creator)
      creator.links.any? do |link|
        new(link.url)
        true
      rescue Invalid
        false
      end
    end

    def self.valid_username?(value)
      value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, MAX_USERNAME_BYTES) &&
        value.match?(/\A[[:alnum:] _-]+\z/) && value == value.strip && value.parameterize.present?
    end

    def self.valid_uri?(value)
      (value.is_a?(URI::HTTPS) && value.port == 443 || value.is_a?(URI::HTTP) && value.scheme == "http" && value.port == 80) &&
        !value.userinfo && Source::HOSTS.include?(value.host&.downcase)
    end

    def self.profile_url(username)
      "https://www.myminifactory.com/users/#{URI.encode_www_form_component(username).gsub('+', '%20')}"
    end
  end
end
