Rails.application.routes.draw do
  root "analyses#new"
  get "analysis", to: "analyses#show", as: :report
end