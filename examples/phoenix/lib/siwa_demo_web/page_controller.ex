defmodule SiwaDemoWeb.PageController do
  @moduledoc "The routes anyone can open: the page, the health check and the address proof."

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  def home(conn, _params) do
    url = SiwaDemoWeb.Endpoint.url()

    render(conn, :home,
      urls: [url <> "/api/hello", url <> "/api/lounge"],
      handle: practice_handle(url)
    )
  end

  def health(conn, _params), do: text(conn, "ok")

  # A live site serves its token here, so the SIWA service can check this host is its own.
  def site_file(conn, _params) do
    case Application.get_env(:siwa_demo, :site_token) do
      nil -> send_resp(conn, :not_found, "")
      token -> text(conn, token)
    end
  end

  # A practice site lives at http://localhost:<port>, which the SIWA service cannot
  # look up by its address, so the agent names the site's handle. A live site needs none.
  defp practice_handle(url) do
    if URI.parse(url).host == "localhost", do: Application.fetch_env!(:siwa_demo, :siwa_handle)
  end
end
