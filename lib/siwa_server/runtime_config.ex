defmodule SiwaServer.RuntimeConfig do
  @moduledoc false

  def base_rpc_url, do: fetch("BASE_RPC_URL")

  def siwa_receipt_secret do
    case fetch_siwa(:receipt_secret) do
      secret when is_binary(secret) ->
        {:ok, secret}

      _ ->
        {:error, {500, "siwa_not_configured", "SIWA receipt secret is not configured"}}
    end
  end

  def siwa_nonce_ttl_seconds, do: fetch_siwa_integer(:nonce_ttl_seconds, 300)

  def siwa_receipt_ttl_seconds, do: fetch_siwa_integer(:receipt_ttl_seconds, 3_600)

  def siwa_http_signature_tolerance_seconds,
    do: fetch_integer("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", 300)

  defp fetch_siwa(key) do
    :siwa_server
    |> Application.get_env(:siwa, [])
    |> Keyword.get(key)
    |> normalize_optional_text()
  end

  defp fetch_siwa_integer(key, default) do
    case :siwa_server |> Application.get_env(:siwa, []) |> Keyword.get(key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> raise ArgumentError, ":siwa #{key} must be a positive integer"
    end
  end

  defp fetch(name) do
    System.get_env(name)
    |> normalize_optional_text()
  end

  defp fetch_integer(name, default) do
    case fetch(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> raise ArgumentError, "#{name} must be a positive integer"
        end
    end
  end

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(_value), do: nil
end
