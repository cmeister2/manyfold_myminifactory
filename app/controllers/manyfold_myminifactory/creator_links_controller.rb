# frozen_string_literal: true

module ManyfoldMyminifactory
  class CreatorLinksController < ::ApplicationController
    before_action :load_creator
    protect_from_forgery with: :exception

    def new
      return already_linked if CreatorSource.linked?(@creator)

      prepare_form
    end

    def create
      return already_linked if CreatorSource.linked?(@creator)
      unless ApiClient.configured?
        raise ApiClient::ConfigurationError, "Set your MyMiniFactory API key in integration settings first."
      end

      prepare_form
      selected = @model_links.find { |link| link.id.to_s == params.permit(:link_id)[:link_id].to_s }
      unless selected
        @error = "Choose a MyMiniFactory-linked model belonging to this creator."
        return render :new, status: :unprocessable_content
      end

      CreatorSyncJob.perform_later(@creator.id, current_user.id, selected.id)
      redirect_to main_app.creators_path, notice: "MyMiniFactory creator sync is queued.", status: :see_other
    rescue ApiClient::Error => error
      @error = error.message
      prepare_form
      render :new, status: :unprocessable_content
    end

    private

    def load_creator
      authorize :settings, :integrations?
      @creator = policy_scope(::Creator).find_param(params.permit(:creator_id)[:creator_id])
      authorize @creator, :sync?
    end

    def prepare_form
      @configured = ApiClient.configured?
      @model_links = CreatorModels.links_for(@creator, models: policy_scope(::Model))
      @selected_link_id = params.permit(:link_id)[:link_id].presence || @model_links.first&.id
    end

    def already_linked
      redirect_to main_app.creators_path, notice: "Creator is already linked to MyMiniFactory.", status: :see_other
    end
  end
end
