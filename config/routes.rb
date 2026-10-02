# frozen_string_literal: true

ManyfoldMyminifactory::Engine.routes.draw do
  root to: "manyfold_myminifactory/status#index"
  get "import", to: "manyfold_myminifactory/imports#new", as: :import
  post "import", to: "manyfold_myminifactory/imports#create"
  post "library_models/:id/create_model", to: "manyfold_myminifactory/library_models#create_model", as: :create_model
  get "link", to: "manyfold_myminifactory/links#new", as: :link
  post "link", to: "manyfold_myminifactory/links#create"
  get "creator_link", to: "manyfold_myminifactory/creator_links#new", as: :creator_link
  post "creator_link", to: "manyfold_myminifactory/creator_links#create"
end
