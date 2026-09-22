defmodule SiwaServer.WalletOrigins do
  @moduledoc """
  Parses `SIWA_WALLET_ORIGINS`, the approved audience-to-origin table for
  EOA wallet sign-in.

  The value is a comma-separated list of `audience=origin` entries, for example
  `patchbay=https://patchbay.help,keyfleet=https://keyfleet.example`. Each
  origin must be a bare HTTPS origin on port 443 without credentials, path,
  query or fragment. An empty or missing value disables wallet sign-in for
  every audience. Callers never supply origins; only this table does.
  """

  @audience_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  @spec parse!(String.t() | nil) :: %{String.t() => String.t()}
  def parse!(value) when value in [nil, ""], do: %{}

  def parse!(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn entry, origins ->
      {audience, origin} = parse_entry!(entry)

      if Map.has_key?(origins, audience) do
        raise ArgumentError, "SIWA_WALLET_ORIGINS lists the audience #{audience} twice"
      end

      Map.put(origins, audience, origin)
    end)
  end

  defp parse_entry!(entry) do
    case String.split(entry, "=", parts: 2) do
      [audience, origin] ->
        {validate_audience!(String.trim(audience)), validate_origin!(String.trim(origin))}

      _ ->
        raise ArgumentError,
              "SIWA_WALLET_ORIGINS entries must look like audience=https://origin, got #{inspect(entry)}"
    end
  end

  defp validate_audience!(audience) do
    if Regex.match?(@audience_regex, audience) do
      audience
    else
      raise ArgumentError, "SIWA_WALLET_ORIGINS audience #{inspect(audience)} is not a valid name"
    end
  end

  defp validate_origin!(origin) do
    with {:ok, uri} <- URI.new(origin),
         true <- bare_https_origin?(uri) do
      String.trim_trailing(origin, "/")
    else
      _ ->
        raise ArgumentError,
              "SIWA_WALLET_ORIGINS origin #{inspect(origin)} must be an HTTPS origin without credentials, path or query"
    end
  end

  defp bare_https_origin?(%URI{scheme: "https", host: host, port: 443, path: path} = uri)
       when is_binary(host) and host != "" and path in [nil, "/"],
       do: is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)

  defp bare_https_origin?(_uri), do: false
end
