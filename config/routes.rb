Rails.application.routes.draw do
  root "home#index"

  devise_for :users

  post "webhook", to: "webhooks#create", as: :webhook
  post "webhook/subscription_started", to: "webhooks/subscription_started#create"
  post "webhook/subscription_paused", to: "webhooks/subscription_paused#create"
  post "webhook/subscription_cancelled", to: "webhooks/subscription_cancelled#create"
  post "webhook/subscription_resumed", to: "webhooks/subscription_resumed#create"

  namespace :callbacks do
    resources :subscription_added, only: :create
    resources :subscription_removed, only: :create
    resources :cart_item_added, only: :create
    resources :verify_email_success, only: :create
    resources :cart_email_on_create, only: :create
  end

  namespace :admin do
    get "dashboard/index"
    resource :droplet, only: %i[ create update ]
    resources :settings, only: %i[ index edit update ]
    resources :users
    resources :callbacks, only: %i[ index show edit update ] do
      post :sync, on: :collection
    end
  end

  resources :price_types, except: %i[ show ]
  resources :customers, only: %i[index update]

  get "up" => "rails/health#show", as: :rails_health_check
end
