defmodule SiwaServer.WalletChallenge do
  @moduledoc """
  The checks shared by the single-use messages this server issues for a wallet
  to sign: accepting a World ID person (`SiwaServer.AgentBook`) and linking a
  registry listing (`SiwaServer.AgentRegistration`). Each issues its message
  into `SiwaServer.Siwa.NonceStore` and consumes it once these checks hold.
  """

  alias SiwaServer.Ethereum
  alias SiwaServer.Siwa.NonceRecord

  @type error :: {:error, {pos_integer(), String.t(), String.t()}}

  @doc "Whether a nonce, message and signature have the shape this server issues and accepts."
  @spec proof?(term(), term(), term()) :: boolean()
  def proof?(nonce, message, signature)
      when is_binary(nonce) and is_binary(message) and is_binary(signature),
      do:
        byte_size(message) in 1..2048 and Regex.match?(~r/^[a-f0-9]{32}$/, nonce) and
          byte_size(signature) <= 2 + 2 * Siwa.WalletSignature.max_bytes() and
          Regex.match?(~r/^0x(?:[0-9a-fA-F]{2})+$/, signature)

  def proof?(_nonce, _message, _signature), do: false

  @doc "The message is the one issued, and it has not expired."
  @spec current(NonceRecord.t(), String.t()) :: :ok | error()
  def current(record, message) do
    cond do
      DateTime.compare(record.expiration_time, DateTime.utc_now()) != :gt ->
        {:error, {401, "nonce_expired", "the challenge has expired"}}

      message != record.canonical_message ->
        {:error, {401, "message_invalid", "sign the exact current server-issued challenge"}}

      true ->
        :ok
    end
  end

  @doc "The wallet signed the message, as an ordinary wallet or a smart wallet on its chain."
  @spec signed(NonceRecord.t(), String.t(), String.t()) :: :ok | error()
  def signed(record, message, signature) do
    case Ethereum.verify_signature(record.address, message, signature, record.chain_id) do
      {:ok, _method} ->
        :ok

      {:error, :signature_invalid} ->
        {:error, {401, "signature_invalid", "signature does not match wallet"}}

      {:error, {:lookup_failed, reason}} ->
        {:error,
         {502, "signature_lookup_failed",
          "could not check the wallet signature on #{Ethereum.chain_name(record.chain_id)}: #{reason}"}}
    end
  end
end
