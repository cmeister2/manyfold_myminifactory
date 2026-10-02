# frozen_string_literal: true

module ManyfoldMyminifactory
  class CreatorSyncJob < ::UpdateMetadataFromLinkJob
    def perform(creator_id, user_id, model_link_id)
      return unless ApiClient.configured?

      creator = ::Creator.find_by(id: creator_id)
      user = ::User.find_by(id: user_id)
      return unless creator && user&.is_administrator? && ::CreatorPolicy.new(user, creator).sync?
      return if CreatorSource.linked?(creator)

      model_link = ::Link.find_by(id: model_link_id, linkable_type: "Model")
      return unless model_link
      model = ::ModelPolicy::Scope.new(user, ::Model).resolve
        .find_by(id: model_link.linkable_id, creator_id: creator.id)
      return unless model

      source = Source.new(model_link.url)
      payload = ApiClient.new.object(source.id)
      unless payload.is_a?(Hash) && payload["id"].to_s == source.id
        raise ApiClient::InvalidResponse, "MyMiniFactory returned an unexpected model."
      end
      profile = CreatorSource.from_payload(payload["designer"])
      deserializer = CreatorDeserializer.new(uri: profile.uri, payload: payload["designer"])
      creator.with_lock do
        return if CreatorSource.linked?(creator)

        link = creator.links.find_or_create_by!(url: deserializer.uri)
        link.define_singleton_method(:deserializer) { deserializer }
        status.update(creator_id: creator.id, model_id: model.id)
        super(link: link, organize: false)
      end
    rescue ApiClient::Error, Source::Invalid, CreatorSource::Invalid => error
      status.update(error: "manyfold_myminifactory.errors.creator_request_failed", mmf_message: error.message)
    rescue ActiveRecord::RecordInvalid => error
      status.update(error: "manyfold_myminifactory.errors.creator_sync_failed", mmf_message: error.message)
    end
  end
end
