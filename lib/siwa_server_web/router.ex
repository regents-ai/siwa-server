defmodule SiwaServerWeb.Router do
  use SiwaServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :siwa_nonce do
    plug :accepts, ["json"]
    plug SiwaServerWeb.Plugs.RateLimit, name: :siwa_nonce
  end

  pipeline :siwa_verify do
    plug :accepts, ["json"]
    plug SiwaServerWeb.Plugs.RateLimit, name: :siwa_verify
  end

  pipeline :siwa_http_verify do
    plug :accepts, ["json"]
    plug SiwaServerWeb.Plugs.RateLimit, name: :siwa_http_verify
  end

  scope "/", SiwaServerWeb do
    get "/", DiscoveryController, :root
    get "/healthz", DiscoveryController, :healthz
    get "/readyz", DiscoveryController, :readyz
    get "/metrics", DiscoveryController, :metrics
    get "/regent-services-contract.openapiv3.yaml", DiscoveryController, :services_contract
  end

  scope "/v1/agent/siwa", SiwaServerWeb do
    pipe_through :siwa_nonce
    post "/nonce", AgentSiwaController, :nonce
  end

  scope "/v1/agent/siwa", SiwaServerWeb do
    pipe_through :siwa_verify
    post "/verify", AgentSiwaController, :verify
  end

  scope "/v1/agent/siwa", SiwaServerWeb do
    pipe_through :siwa_http_verify
    post "/http-verify", AgentSiwaController, :http_verify
  end

  forward "/internal/keyring", SiwaServerWeb.KeyringForwarder
end
