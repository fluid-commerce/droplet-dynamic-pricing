Rails.application.routes.draw do
  root "home#index"

  devise_for :users

  post "webhook", to: "webhooks#create", as: :webhook
  post "callback/:callback_name", to: "callbacks#create", as: :callback

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
