defmodule SiwaDemoWeb.Router do
  use Phoenix.Router, helpers: false

  import Phoenix.Controller

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  # Every route here needs a signed agent request, checked by the SIWA service.
  pipeline :agent do
    plug :accepts, ["json"]
    plug SiwaDemoWeb.AgentAuth
  end

  scope "/", SiwaDemoWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", SiwaDemoWeb do
    get "/healthz", PageController, :health
    get "/.well-known/siwa-site.txt", PageController, :site_file
  end

  scope "/api", SiwaDemoWeb do
    pipe_through :agent

    get "/hello", AgentController, :hello
    get "/lounge", AgentController, :lounge
  end
end
