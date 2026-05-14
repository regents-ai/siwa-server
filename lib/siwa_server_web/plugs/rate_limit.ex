defmodule SiwaServerWeb.Plugs.RateLimit do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  alias SiwaServer.RateLimiter
  alias SiwaServerWeb.ErrorJSON

  @defaults %{
    siwa_nonce: [limit: 60, window_ms: 60_000],
    siwa_verify: [limit: 60, window_ms: 60_000],
    siwa_http_verify: [limit: 600, window_ms: 60_000],
    keyring_internal: [limit: 600, window_ms: 60_000]
  }

  def init(opts), do: opts

  def call(conn, opts) do
    name = Keyword.fetch!(opts, :name)
    config = configured_limit(name)
    key = client_key(conn, name)

    case RateLimiter.check(
           name,
           key,
           Keyword.fetch!(config, :limit),
           Keyword.fetch!(config, :window_ms)
         ) do
      :ok ->
        conn

      {:error, retry_after_ms} ->
        conn
        |> put_status(:too_many_requests)
        |> put_resp_header("retry-after", retry_after_seconds(retry_after_ms))
        |> json(
          ErrorJSON.error("rate_limited", "Please wait a moment before trying again.", %{
            "retry_after_ms" => retry_after_ms
          })
        )
        |> halt()
    end
  end

  defp configured_limit(name) do
    configured =
      :siwa_server
      |> Application.get_env(:rate_limits, [])
      |> Keyword.get(name, [])

    Keyword.merge(Map.fetch!(@defaults, name), configured)
  end

  defp client_key(conn, :siwa_http_verify) do
    [
      "http-verify",
      agent_header(conn, "x-agent-wallet-address"),
      agent_header(conn, "x-agent-chain-id"),
      agent_header(conn, "x-agent-registry-address"),
      agent_header(conn, "x-agent-token-id"),
      client_ip(conn)
    ]
    |> Enum.join(":")
  end

  defp client_key(conn, :keyring_internal) do
    "keyring:#{conn.method}:#{conn.request_path}:#{client_ip(conn)}"
  end

  defp client_key(conn, _name) do
    body = conn.body_params || %{}

    [
      Map.get(body, "wallet_address"),
      Map.get(body, "chain_id"),
      Map.get(body, "registry_address"),
      Map.get(body, "token_id"),
      Map.get(body, "audience"),
      client_ip(conn)
    ]
    |> Enum.map(&normalize_part/1)
    |> Enum.join(":")
  end

  defp agent_header(conn, name) do
    conn.body_params
    |> case do
      %{"headers" => headers} when is_map(headers) -> Map.get(headers, name)
      _body -> nil
    end
    |> normalize_part()
  end

  defp normalize_part(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_part(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_part(_value), do: "unknown"

  defp client_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp retry_after_seconds(retry_after_ms) do
    retry_after_ms
    |> Kernel./(1000)
    |> Float.ceil()
    |> trunc()
    |> max(1)
    |> Integer.to_string()
  end
end
