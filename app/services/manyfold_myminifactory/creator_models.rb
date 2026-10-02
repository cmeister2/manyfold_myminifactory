# frozen_string_literal: true

module ManyfoldMyminifactory
  class CreatorModels
    def self.linked?(creator, models:)
      links(creator, models: models).find_each(batch_size: 100).any? { |link| valid_source?(link.url) }
    end

    def self.links_for(creator, models:)
      links(creator, models: models).includes(:linkable).order(:id)
        .select { |link| valid_source?(link.url) }.uniq { |link| source(link.url).id }
    end

    def self.source(url)
      Source.new(url)
    end

    def self.links(creator, models:)
      ::Link.where(linkable_type: "Model", linkable_id: models.where(creator_id: creator.id).select(:id))
        .where(::Link.arel_table[:url].matches("%myminifactory.com%"))
    end
    private_class_method :links

    def self.valid_source?(url)
      source(url)
      true
    rescue Source::Invalid
      false
    end
    private_class_method :valid_source?
  end
end
