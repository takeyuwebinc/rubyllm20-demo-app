Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  root "demos#index"

  resources :demos, only: %i[index show], param: :key do
    resources :runs, only: :create, module: :demos
  end

  resources :runs, only: %i[index show] do
    resource :status, only: :show, module: :runs
    resource :decision, only: :create, module: :runs
  end
end
