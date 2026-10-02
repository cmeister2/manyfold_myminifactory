# frozen_string_literal: true

module Components::ManyfoldMyminifactory
  class CreatorMenu < Components::Base
    register_value_helper :policy_scope

    def initialize(creator:)
      @creator = creator
    end

    def view_template
      return unless ::ManyfoldMyminifactory::ApiClient.configured?
      return unless current_user && policy(:settings).integrations? && policy(@creator).sync?
      return if ::ManyfoldMyminifactory::CreatorSource.linked?(@creator)
      return unless ::ManyfoldMyminifactory::CreatorModels.linked?(@creator, models: policy_scope(::Model))

      a(href: view_context.manyfold_myminifactory.creator_link_path(creator_id: @creator.to_param),
        class: "dropdown-item", role: "menuitem", rel: "nofollow") do
        Icon(icon: "link-45deg", label: "Link to MyMiniFactory")
        whitespace
        span { "Link to MyMiniFactory" }
      end
    end
  end
end
