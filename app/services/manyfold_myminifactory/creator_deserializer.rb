# frozen_string_literal: true

require "faraday"
require "reverse_markdown"
require "uri"

module ManyfoldMyminifactory
  class CreatorDeserializer < ::Integrations::BaseDeserializer
    def initialize(uri:, payload: nil)
      @payload = payload
      @source = CreatorSource.new(uri)
      @uri = @source.uri
    rescue CreatorSource::Invalid
      @source = @uri = nil
    end

    def deserialize
      return {} unless valid?

      payload = @payload.nil? ? ApiClient.new.creator(@source.username) : @payload
      unless @source.matches?(payload)
        raise ApiClient::InvalidResponse, "MyMiniFactory returned an unexpected creator profile."
      end
      source = CreatorSource.from_payload(payload)
      attributes = {
        name: text(payload["name"]) || source.username,
        slug: source.username.parameterize,
        links_attributes: [{url: source.uri}]
      }
      bio = payload["bio"]
      if bio.is_a?(String) && bio.valid_encoding?
        attributes[:notes] = ReverseMarkdown.convert(bio.strip).strip
      end
      avatar = image_uri(payload["avatar_url"])
      banner = image_uri(payload["cover_url"])
      attributes[:avatar_remote_url] = avatar.to_s if avatar
      attributes[:banner_remote_url] = banner.to_s if banner
      attributes
    rescue ApiClient::Error => error
      raise unless @payload.nil?

      # Native Manyfold sync jobs report Faraday errors against the profile link.
      raise Faraday::Error, error.message, cause: nil
    end

    def valid?(for_class: nil)
      ApiClient.configured? && @source.present? && (for_class.nil? || for_class == ::Creator)
    end

    def capabilities
      {class: ::Creator, name: true, slug: true, notes: true}
    end

    private

    def text(value)
      return unless value.is_a?(String) && value.valid_encoding?
      normalized = value.strip
      normalized unless normalized.empty?
    end

    def image_uri(value)
      return unless value.is_a?(String) && value.valid_encoding?
      uri = URI.parse(value.strip)
      uri if uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && uri.port == 443
    rescue URI::InvalidURIError, URI::InvalidComponentError
      nil
    end
  end
end
