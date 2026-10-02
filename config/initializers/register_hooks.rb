# frozen_string_literal: true

Rails.application.config.after_initialize do
  require "manyfold/provider_menu"
  Manyfold::ProviderMenu.register(Components::ManyfoldMyminifactory::ProviderMenuItem)
  PluginManager.register(:model_menu, Components::ManyfoldMyminifactory::ModelMenu)
  PluginManager.register(:creator_menu, Components::ManyfoldMyminifactory::CreatorMenu)
end

Rails.application.config.to_prepare do
  require "manyfold_myminifactory/creator_menu"
  require "manyfold_myminifactory/creator_links"
  ManyfoldMyminifactory::CreatorMenu.install!
  ManyfoldMyminifactory::CreatorLinks.install!
end
