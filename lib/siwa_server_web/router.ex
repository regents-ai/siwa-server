defmodule SiwaServerWeb.Router do
  use SiwaServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # One pipeline per SIWA endpoint; they differ only in which rate-limit
  # bucket they apply (limits are configured per name in :rate_limits).
  for name <- [
        :siwa_nonce,
        :siwa_verify,
        :siwa_http_verify,
        :siwa_activity,
        :siwa_register,
        :agent_profile
      ] do
    pipeline name do
      plug :accepts, ["json"]
      plug SiwaServerWeb.Plugs.RateLimit, name: name
    end
  end

  scope "/", SiwaServerWeb do
    get "/", DiscoveryController, :root
    get "/healthz", DiscoveryController, :healthz
    get "/readyz", DiscoveryController, :readyz
    get "/metrics", DiscoveryController, :metrics
    get "/regent-services-contract.openapiv3.yaml", DiscoveryController, :services_contract
    get "/api/shared/siwa/audiences", DiscoveryController, :audiences
  end

  scope "/api/shared/siwa", SiwaServerWeb do
    pipe_through :siwa_nonce
    post "/wallet/nonce", WalletSiwaController, :nonce
  end

  scope "/api/shared/siwa", SiwaServerWeb do
    pipe_through :siwa_verify
    post "/wallet/verify", WalletSiwaController, :verify
  end

  scope "/api/shared/siwa", SiwaServerWeb do
    pipe_through :siwa_http_verify
    post "/http-verify", AgentSiwaController, :http_verify
  end

  scope "/api/shared/siwa", SiwaServerWeb do
    pipe_through :siwa_activity
    post "/activity", ActivityController, :read
  end

  scope "/api/shared/siwa/agent", SiwaServerWeb do
    pipe_through :siwa_register
    post "/register-step", AgentRegistrationController, :register_step
    post "/registered", AgentRegistrationController, :registered
  end

  scope "/", SiwaServerWeb do
    pipe_through :agent_profile
    get "/agent-profiles/:profile_id", AgentRegistrationController, :profile
  end

  forward "/api/shared/keyring", SiwaServerWeb.KeyringForwarder
end
