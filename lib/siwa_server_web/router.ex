defmodule SiwaServerWeb.Router do
  use SiwaServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # One pipeline per SIWA endpoint; they differ only in which rate-limit
  # bucket they apply (limits are set per name in SiwaServer.RateLimiter).
  for name <- [
        :siwa_nonce,
        :siwa_verify,
        :siwa_http_verify,
        :siwa_activity,
        :siwa_hosted,
        :siwa_register,
        :agent_book,
        :agent_profile,
        :siwa_audience,
        :siwa_hello_card
      ] do
    pipeline name do
      plug :accepts, ["json"]
      plug SiwaServerWeb.Plugs.RateLimit, name: name
    end
  end

  # The control API, for Regent sites acting for their signed-in person. Without
  # its Privy settings every route answers 503 and the rest of the server is unchanged.
  pipeline :control_session do
    plug :accepts, ["json"]
    plug SiwaServerWeb.Plugs.ControlConfigured
    plug SiwaServerWeb.Plugs.RateLimit, name: :siwa_control_session
  end

  pipeline :control do
    plug :accepts, ["json"]
    plug SiwaServerWeb.Plugs.ControlConfigured
    plug SiwaServerWeb.Plugs.ControlPerson
  end

  # Billing through Stripe. Without its Stripe settings each of these answers 503.
  pipeline :control_billing do
    plug :accepts, ["json"]
    plug SiwaServerWeb.Plugs.ControlConfigured
    plug SiwaServerWeb.Plugs.BillingConfigured
    plug SiwaServerWeb.Plugs.ControlPerson
  end

  pipeline :stripe_webhook do
    plug SiwaServerWeb.Plugs.BillingConfigured
  end

  scope "/", SiwaServerWeb do
    get "/", DiscoveryController, :root
    get "/healthz", DiscoveryController, :healthz
    get "/readyz", DiscoveryController, :readyz
    get "/regent-services-contract.openapiv3.yaml", DiscoveryController, :services_contract
    get "/api/shared/siwa/audiences", DiscoveryController, :audiences
    get "/.well-known/jwks.json", HelloCardController, :jwks
  end

  scope "/api/shared/siwa", SiwaServerWeb do
    pipe_through :siwa_audience
    get "/audience", DiscoveryController, :audience
  end

  scope "/api/shared/siwa", SiwaServerWeb do
    pipe_through :siwa_hello_card
    post "/hello-card", HelloCardController, :create
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

  scope "/api/shared/siwa", SiwaServerWeb do
    pipe_through :siwa_hosted
    post "/hosted", HostedController, :handle
  end

  scope "/api/shared/siwa/agent", SiwaServerWeb do
    pipe_through :siwa_register
    post "/register-step", AgentRegistrationController, :register_step
    post "/registered", AgentRegistrationController, :registered
    post "/link-challenge", AgentRegistrationController, :link_challenge
    post "/link", AgentRegistrationController, :link
  end

  scope "/api/shared/siwa/agent-book", SiwaServerWeb do
    pipe_through :agent_book
    post "/challenge", AgentBookController, :challenge
    post "/accept", AgentBookController, :accept
  end

  scope "/", SiwaServerWeb do
    pipe_through :agent_profile
    get "/agent-profiles/:profile_id", AgentRegistrationController, :profile
  end

  scope "/api/control/v1", SiwaServerWeb do
    pipe_through :control_session
    post "/session", ControlSessionController, :create
  end

  scope "/api/control/v1", SiwaServerWeb do
    pipe_through :control
    get "/account", ControlController, :account
    post "/customer", ControlController, :create_customer
    patch "/customer", ControlController, :update_customer
    put "/cap", ControlController, :put_cap
    get "/agents", ControlController, :agents
    get "/sites", ControlController, :sites
    post "/sites", ControlController, :create_site
    get "/sites/:id", ControlController, :site
    patch "/sites/:id", ControlController, :update_site
    delete "/sites/:id", ControlController, :archive_site
    post "/sites/:id/proof", ControlController, :check_site_proof
    get "/sites/:id/keys", ControlController, :keys
    post "/sites/:id/keys", ControlController, :create_key
    delete "/sites/:id/keys/:key_id", ControlController, :revoke_key
  end

  scope "/api/control/v1/billing", SiwaServerWeb do
    pipe_through :control_billing
    post "/checkout", ControlController, :checkout
    post "/portal", ControlController, :portal
    get "/invoices", ControlController, :invoices
  end

  scope "/api/stripe", SiwaServerWeb do
    pipe_through :stripe_webhook
    post "/webhook", StripeWebhookController, :notice
  end
end
