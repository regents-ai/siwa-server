defmodule SiwaServer.RuntimeConfig do
  @moduledoc false

  def base_rpc_url, do: fetch("BASE_RPC_URL") || "https://mainnet.base.org"

  def siwa_http_signature_tolerance_seconds,
    do: fetch_integer("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", 300)

  defp fetch(name) do
    System.get_env(name)
    |> case do
      nil ->
        nil

      value ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed
    end
  end

  defp fetch_integer(name, default) do
    case fetch(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end
end
