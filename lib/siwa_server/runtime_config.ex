defmodule SiwaServer.RuntimeConfig do
  @moduledoc false

  alias SiwaServer.Config
  alias SiwaServer.Text

  def base_rpc_url, do: fetch("BASE_RPC_URL")
  def ethereum_rpc_url, do: fetch("ETHEREUM_RPC_URL")
  def world_rpc_url, do: fetch("WORLD_RPC_URL")

  def siwa_receipt_secret do
    case fetch_siwa(:receipt_secret) do
      secret when is_binary(secret) ->
        {:ok, secret}

      _ ->
        {:error, {500, "siwa_not_configured", "SIWA receipt secret is not configured"}}
    end
  end

  def siwa_activity_readers, do: Keyword.fetch!(Config.siwa(), :activity_readers)

  def siwa_hosted_signers, do: Keyword.fetch!(Config.siwa(), :hosted_signers)

  def siwa_keystore_password, do: Keyword.fetch!(Config.siwa(), :keystore_password)

  def siwa_wallet_origins, do: Keyword.get(Config.siwa(), :wallet_origins, %{})

  def siwa_nonce_ttl_seconds, do: fetch_siwa_integer(:nonce_ttl_seconds, 300)

  def siwa_receipt_ttl_seconds, do: fetch_siwa_integer(:receipt_ttl_seconds, 3_600)

  # How long a site may check an agent's requests that read itself after this
  # server verified one (`SiwaServer.Siwa.HttpVerifier`).
  def siwa_lease_seconds, do: fetch_siwa_integer(:lease_seconds, 600)

  # A signed request may last no longer than the tolerance, so the tolerance is
  # at least the contract's signing lifetime, the one every helper signs for.
  def siwa_http_signature_tolerance_seconds do
    lifetime = Siwa.Contract.lifetime_seconds()

    case fetch_integer("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", 300) do
      seconds when seconds >= lifetime ->
        seconds

      _seconds ->
        raise ArgumentError,
              "SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS must be at least #{lifetime}, the contract's signing lifetime"
    end
  end

  defp fetch_siwa(key) do
    Config.siwa()
    |> Keyword.get(key)
    |> Text.normalize_optional_text()
  end

  defp fetch_siwa_integer(key, default) do
    case Config.siwa() |> Keyword.get(key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> raise ArgumentError, ":siwa #{key} must be a positive integer"
    end
  end

  defp fetch(name) do
    System.get_env(name)
    |> Text.normalize_optional_text()
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
end
