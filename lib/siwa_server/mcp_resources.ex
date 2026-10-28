defmodule SiwaServer.McpResources do
  @moduledoc """
  Parses `SIWA_MCP_RESOURCES`, the table from each site's exact MCP address to
  the sign-in audience an agent uses for it.

  The value is a comma-separated list of `audience=resource` entries, for
  example `patchbay=https://patchbay.help/mcp`. Each audience is one already in
  `SIWA_WALLET_ORIGINS`, and each resource is one of that audience's origins
  followed by a path, with no query or fragment, so this table never opens a new
  origin or turns a server hostname into an audience of its own. No resource
  appears twice, so every resource belongs to exactly one audience. An empty or
  missing value lists none. Callers never supply this table; a request's `Host`
  or forwarded headers never change it.
  """

  @audience_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  # Path segments of unreserved characters, none of them "." or "..", so each
  # resource has one spelling.
  @path_regex ~r/\A(?:\/(?!\.{1,2}(?:\/|\z))[A-Za-z0-9._~-]+)+\z/

  @spec parse!(String.t() | nil, %{String.t() => [String.t(), ...]}) :: %{
          String.t() => String.t()
        }
  def parse!(value, _wallet_origins) when value in [nil, ""], do: %{}

  def parse!(value, wallet_origins) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn entry, resources ->
      {audience, resource} = parse_entry!(entry, wallet_origins)

      if Map.has_key?(resources, resource) do
        raise ArgumentError, "SIWA_MCP_RESOURCES lists the resource #{resource} twice"
      end

      Map.put(resources, resource, audience)
    end)
  end

  defp parse_entry!(entry, wallet_origins) do
    with [audience, resource] <- String.split(entry, "=", parts: 2),
         audience = String.trim(audience),
         resource = String.trim(resource),
         true <- Regex.match?(@audience_regex, audience) do
      {audience, validate_resource!(audience, resource, wallet_origins)}
    else
      _invalid ->
        raise ArgumentError,
              "SIWA_MCP_RESOURCES entries must look like audience=https://origin/path, got #{inspect(entry)}"
    end
  end

  defp validate_resource!(audience, resource, wallet_origins) do
    origins = Map.get(wallet_origins, audience, [])

    with %URI{scheme: "https", host: host, path: path, query: nil, fragment: nil, userinfo: nil} <-
           URI.parse(resource),
         true <- is_binary(path) and Regex.match?(@path_regex, path),
         true <- "https://" <> host <> path == resource,
         true <- ("https://" <> host) in origins do
      resource
    else
      _invalid ->
        raise ArgumentError,
              "SIWA_MCP_RESOURCES resource #{inspect(resource)} must be one of #{audience}'s origins in SIWA_WALLET_ORIGINS followed by a path"
    end
  end
end
