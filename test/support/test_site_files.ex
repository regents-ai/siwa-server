defmodule SiwaServer.TestSiteFiles do
  @moduledoc """
  Stands in for `SiwaServer.Customers.SiteFile` in tests (config/test.exs): each
  origin answers what the `:site_files` setting names for it, `{:ok, body}` or
  `{:error, reason}`, and any other origin cannot be reached.
  """

  def fetch(origin) do
    :siwa_server
    |> Application.get_env(:site_files, %{})
    |> Map.get(origin, {:error, :unreachable})
  end
end
