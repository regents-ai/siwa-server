defmodule SiwaServerWeb.Router do
  use SiwaServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SiwaServerWeb do
    get "/", DiscoveryController, :root
    get "/healthz", DiscoveryController, :healthz
    get "/readyz", DiscoveryController, :readyz
    get "/metrics", DiscoveryController, :metrics
    get "/regent-services-contract.openapiv3.yaml", DiscoveryController, :services_contract
  end

  scope "/v1/agent/siwa", SiwaServerWeb do
    pipe_through :api

    post "/nonce", AgentSiwaController, :nonce
    post "/verify", AgentSiwaController, :verify
    post "/http-verify", AgentSiwaController, :http_verify
  end

  forward "/internal/keyring", SiwaServerWeb.KeyringForwarder
end
