defmodule SiwaServer.SharedIdentity do
  @moduledoc false

  import Ecto.Query

  alias SiwaServer.SharedIdentity.{IdentityRecord, RegistrationIntent, SiwaNonce}
  alias SiwaServer.{Ethereum, Repo, RuntimeConfig, Text}

  @provider "coinbase-cdp"
  @networks %{"base" => 8453, "base-sepolia" => 84_532}
  @registry_addresses %{
    "base" => "0x2222222222222222222222222222222222222222",
    "base-sepolia" => "0x3333333333333333333333333333333333333333"
  }
  @address_regex ~r/^0x[a-fA-F0-9]{40}$/
  @signature_regex ~r/^0x[0-9a-fA-F]+$/
  @intent_ttl_seconds 300
  @nonce_ttl_seconds 300
  @cleanup_default_limit 1_000
  @max_token_id 9_223_372_036_854_775_807

  def status(params) when is_map(params) do
    with {:ok, request} <- cast_identity_request(params),
         record <- get_record(request) do
      data =
        case record do
          nil ->
            %{
              "network" => request.network,
              "address" => request.address,
              "provider" => request.provider,
              "registered" => false,
              "verified" => "unregistered"
            }

          %IdentityRecord{} = record ->
            token_id = token_id(record)

            %{
              "network" => record.network,
              "address" => record.address,
              "provider" => record.provider,
              "registered" => true,
              "verified" => record.verified,
              "agent_id" => agent_id(record.agent_registry, token_id),
              "token_id" => token_id,
              "agent_registry" => record.agent_registry
            }
        end

      {:ok, ok("identity_status_resolved", data)}
    end
  end

  def create_registration_intent(params) when is_map(params) do
    with {:ok, request} <- cast_identity_request(params),
         now <- now(),
         expires_at <- DateTime.add(now, @intent_ttl_seconds, :second),
         intent_id <- Ecto.UUID.generate(),
         message <- registration_message(request, intent_id, now, expires_at),
         {:ok, intent} <-
           %RegistrationIntent{}
           |> RegistrationIntent.changeset(%{
             id: intent_id,
             network: request.network,
             address: request.address,
             provider: request.provider,
             message: message,
             expires_at: expires_at
           })
           |> Repo.insert() do
      {:ok,
       ok("identity_registration_intent_created", %{
         "intent_id" => intent.id,
         "intent_kind" => "regent_identity_registration",
         "signing_payload" => %{"message" => intent.message}
       })}
    else
      {:error, %Ecto.Changeset{}} -> invalid_request()
      {:error, reason} -> {:error, {500, "registration_failed", inspect(reason)}}
    end
  end

  def complete_registration(params) when is_map(params) do
    with {:ok, request} <- cast_registration_completion(params),
         {:ok, intent} <- usable_intent(request.intent_id),
         :ok <- ensure_same_address(intent.address, request.address),
         :ok <- ensure_message_matches(intent.message, request.message),
         :ok <- verify_signature(intent.address, intent.message, request.signature),
         {:ok, record} <- finish_registration(intent) do
      {:ok,
       ok("identity_registration_completed", %{
         "registered" => true,
         "agent_id" => agent_id(record.agent_registry, token_id(record)),
         "token_id" => token_id(record),
         "agent_registry" => record.agent_registry
       })}
    end
  end

  def create_siwa_nonce(params) when is_map(params) do
    with {:ok, request} <- cast_siwa_nonce_request(params),
         {:ok, record} <- identity_record_for_claims(request),
         true <- record.agent_registry == request.agent_registry || registration_mismatch(),
         now <- now(),
         expires_at <- DateTime.add(now, @nonce_ttl_seconds, :second),
         nonce_token <- nonce_token(),
         message <- siwa_message(request, nonce_token),
         {:ok, nonce} <-
           %SiwaNonce{}
           |> SiwaNonce.changeset(%{
             id: Ecto.UUID.generate(),
             nonce_token: nonce_token,
             network: request.network,
             address: request.address,
             agent_id: request.agent_id,
             agent_registry: request.agent_registry,
             message: message,
             expires_at: expires_at
           })
           |> Repo.insert() do
      {:ok,
       ok("identity_siwa_nonce_issued", %{
         "nonce_token" => nonce.nonce_token,
         "message" => nonce.message,
         "address" => nonce.address,
         "agent_id" => agent_id(nonce.agent_registry, token_id(nonce)),
         "token_id" => token_id(nonce),
         "agent_registry" => nonce.agent_registry,
         "expires_at" => DateTime.to_iso8601(nonce.expires_at)
       })}
    else
      {:error, %Ecto.Changeset{}} -> invalid_request()
      {:error, _reason} = error -> error
    end
  end

  def verify_siwa(params) when is_map(params) do
    with {:ok, request} <- cast_siwa_verify_request(params),
         {:ok, nonce} <- usable_nonce(request.nonce_token),
         :ok <- ensure_network_matches(nonce.network, request.network),
         :ok <- ensure_message_matches(nonce.message, request.message),
         :ok <- ensure_optional_claims_match(nonce, request),
         :ok <- verify_siwa_signature(nonce.address, nonce.message, request.signature),
         :ok <- consume_nonce(nonce),
         {:ok, receipt, receipt_issued_at, receipt_expires_at} <- issue_receipt(nonce) do
      {:ok,
       ok("identity_siwa_verified", %{
         "verified" => "onchain",
         "network" => nonce.network,
         "address" => nonce.address,
         "agent_id" => agent_id(nonce.agent_registry, token_id(nonce)),
         "token_id" => token_id(nonce),
         "agent_registry" => nonce.agent_registry,
         "signer_type" => "evm_personal_sign",
         "receipt" => receipt,
         "receipt_issued_at" => DateTime.to_iso8601(receipt_issued_at),
         "receipt_expires_at" => DateTime.to_iso8601(receipt_expires_at)
       })}
    end
  end

  def cleanup_expired(now \\ DateTime.utc_now(), limit \\ @cleanup_default_limit) do
    now = DateTime.truncate(now, :second)

    with {:ok, intent_count} <-
           cleanup_table(:shared_identity_registration_intents, :expires_at, now, limit),
         {:ok, nonce_count} <-
           cleanup_table(:shared_identity_siwa_nonces, :expires_at, now, limit) do
      {:ok, %{identity_intent_count: intent_count, identity_nonce_count: nonce_count}}
    end
  end

  defp cast_identity_request(params) do
    with :ok <- no_extra_fields(params, ~w(network address provider wallet_hint)),
         {:ok, network} <- required_network(params),
         {:ok, address} <- required_address(params, "address"),
         {:ok, provider} <- required_provider(params) do
      {:ok, %{network: network, address: address, provider: provider}}
    end
  end

  defp cast_registration_completion(params) do
    with :ok <- no_extra_fields(params, ~w(intent_id address signature message)),
         {:ok, intent_id} <- required_uuid(params, "intent_id"),
         {:ok, address} <- required_address(params, "address"),
         {:ok, signature} <- required_signature(params, "signature"),
         {:ok, message} <- optional_string(params, "message") do
      {:ok, %{intent_id: intent_id, address: address, signature: signature, message: message}}
    end
  end

  defp cast_siwa_nonce_request(params) do
    with :ok <- no_extra_fields(params, ~w(network address token_id agent_registry)),
         {:ok, network} <- required_network(params),
         {:ok, address} <- required_address(params, "address"),
         {:ok, token_id} <- required_token_id(params, "token_id"),
         {:ok, agent_registry} <- required_agent_registry(params, "agent_registry") do
      {:ok,
       %{
         network: network,
         address: address,
         agent_id: token_id,
         agent_registry: agent_registry
       }}
    end
  end

  defp cast_siwa_verify_request(params) do
    with :ok <-
           no_extra_fields(
             params,
             ~w(network message signature nonce_token address token_id agent_registry)
           ),
         {:ok, network} <- required_network(params),
         {:ok, message} <- required_string(params, "message"),
         {:ok, signature} <- required_signature(params, "signature"),
         {:ok, nonce_token} <- required_string(params, "nonce_token"),
         {:ok, address} <- optional_address(params, "address"),
         {:ok, token_id} <- optional_token_id(params, "token_id"),
         {:ok, agent_registry} <- optional_agent_registry(params, "agent_registry") do
      {:ok,
       %{
         network: network,
         message: message,
         signature: signature,
         nonce_token: nonce_token,
         address: address,
         agent_id: token_id,
         agent_registry: agent_registry
       }}
    end
  end

  defp get_record(%{network: network, address: address, provider: provider}) do
    Repo.get_by(IdentityRecord, network: network, address: address, provider: provider)
  end

  defp usable_intent(intent_id) do
    case Repo.get(RegistrationIntent, intent_id) do
      nil ->
        registration_failed()

      %RegistrationIntent{used_at: used_at} when not is_nil(used_at) ->
        registration_failed()

      %RegistrationIntent{expires_at: expires_at} = intent ->
        if DateTime.compare(expires_at, now()) == :gt,
          do: {:ok, intent},
          else: registration_failed()
    end
  end

  defp finish_registration(intent) do
    Repo.transaction(fn ->
      now = now()

      case mark_intent_used(intent, now) do
        :ok ->
          upsert_identity_record(intent, now)

        {:error, _reason} = error ->
          Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, {:ok, record}} -> {:ok, record}
      {:ok, {:error, %Ecto.Changeset{}}} -> registration_failed()
      {:ok, {:error, reason}} -> {:error, {500, "registration_failed", inspect(reason)}}
      {:error, {:error, _reason}} -> registration_failed()
      {:error, reason} -> {:error, {500, "registration_failed", inspect(reason)}}
    end
  end

  defp mark_intent_used(intent, now) do
    query =
      from intent in RegistrationIntent,
        where: intent.id == ^intent.id and is_nil(intent.used_at)

    case Repo.update_all(query, set: [used_at: now, updated_at: now]) do
      {1, _records} -> :ok
      {0, _records} -> registration_failed()
    end
  end

  defp upsert_identity_record(intent, now) do
    attrs = %{
      network: intent.network,
      address: intent.address,
      provider: intent.provider,
      agent_registry: agent_registry(intent.network),
      verified: "onchain",
      registered_at: now
    }

    %IdentityRecord{}
    |> IdentityRecord.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:network, :provider, :address],
      returning: true
    )
  end

  defp identity_record_for_claims(%{network: network, address: address, agent_id: agent_id}) do
    case Repo.get(IdentityRecord, agent_id) do
      %IdentityRecord{network: ^network, address: ^address, provider: @provider} = record ->
        {:ok, record}

      _record ->
        registration_mismatch()
    end
  end

  defp usable_nonce(nonce_token) do
    case Repo.get_by(SiwaNonce, nonce_token: nonce_token) do
      nil ->
        siwa_verify_failed()

      %SiwaNonce{used_at: used_at} when not is_nil(used_at) ->
        siwa_verify_failed()

      %SiwaNonce{expires_at: expires_at} = nonce ->
        if DateTime.compare(expires_at, now()) == :gt,
          do: {:ok, nonce},
          else: siwa_verify_failed()
    end
  end

  defp consume_nonce(nonce) do
    now = now()

    query =
      from nonce in SiwaNonce,
        where: nonce.id == ^nonce.id and is_nil(nonce.used_at)

    case Repo.update_all(query, set: [used_at: now, updated_at: now]) do
      {1, _records} -> :ok
      {0, _records} -> siwa_verify_failed()
    end
  end

  defp issue_receipt(nonce) do
    issued_at = now()

    with {:ok, secret} <- RuntimeConfig.siwa_receipt_secret(),
         {:ok, receipt} <-
           Siwa.create_receipt(
             %{
               "typ" => "siwa_receipt",
               "jti" => Ecto.UUID.generate(),
               "sub" => nonce.address,
               "aud" => "regent-services",
               "chain_id" => Map.fetch!(@networks, nonce.network),
               "nonce" => nonce.nonce_token,
               "key_id" => nonce.address,
               "agent_id" => agent_id(nonce.agent_registry, token_id(nonce)),
               "registry_address" => registry_address(nonce.agent_registry),
               "token_id" => token_id(nonce)
             },
             receipt_secret: secret,
             now: issued_at,
             ttl_ms: RuntimeConfig.siwa_receipt_ttl_seconds() * 1_000
           ) do
      {:ok, receipt.token, issued_at, receipt.expires_at}
    end
  end

  defp verify_signature(address, message, signature) do
    case Ethereum.verify_signature(address, message, signature) do
      :ok -> :ok
      {:error, _reason} -> registration_failed()
    end
  end

  defp verify_siwa_signature(address, message, signature) do
    case Ethereum.verify_signature(address, message, signature) do
      :ok -> :ok
      {:error, _reason} -> siwa_verify_failed()
    end
  end

  defp ensure_same_address(address, address), do: :ok
  defp ensure_same_address(_expected, _actual), do: registration_failed()

  defp ensure_network_matches(network, network), do: :ok
  defp ensure_network_matches(_expected, _actual), do: siwa_verify_failed()

  defp ensure_message_matches(message, nil), do: ensure_message_matches(message, message)
  defp ensure_message_matches(message, message), do: :ok
  defp ensure_message_matches(_expected, _actual), do: siwa_verify_failed()

  defp ensure_optional_claims_match(nonce, request) do
    cond do
      request.address && request.address != nonce.address ->
        siwa_verify_failed()

      request.agent_id && request.agent_id != nonce.agent_id ->
        siwa_verify_failed()

      request.agent_registry && request.agent_registry != nonce.agent_registry ->
        siwa_verify_failed()

      true ->
        :ok
    end
  end

  defp registration_message(request, intent_id, issued_at, expires_at) do
    """
    Register Regent identity
    Address: #{request.address}
    Network: #{request.network}
    Provider: #{request.provider}
    Intent: #{intent_id}
    Issued At: #{DateTime.to_iso8601(issued_at)}
    Expires At: #{DateTime.to_iso8601(expires_at)}
    """
    |> String.trim()
  end

  defp siwa_message(request, nonce_token) do
    """
    Sign in with Regent
    Address: #{request.address}
    Network: #{request.network}
    Token ID: #{request.agent_id}
    Agent Registry: #{request.agent_registry}
    Nonce: #{nonce_token}
    """
    |> String.trim()
  end

  defp no_extra_fields(params, allowed_fields) do
    extras = params |> Map.keys() |> Enum.reject(&(&1 in allowed_fields))

    if extras == [], do: :ok, else: invalid_request()
  end

  defp required_network(params) do
    case Text.normalize_optional_text(Map.get(params, "network")) do
      network when is_map_key(@networks, network) -> {:ok, network}
      _value -> {:error, {400, "unsupported_network", "network is not supported"}}
    end
  end

  defp required_provider(params) do
    case Text.normalize_optional_text(Map.get(params, "provider")) do
      @provider -> {:ok, @provider}
      _value -> invalid_request()
    end
  end

  defp required_address(params, key) do
    params
    |> Map.get(key)
    |> normalize_address()
    |> case do
      nil -> invalid_request()
      address -> {:ok, address}
    end
  end

  defp optional_address(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      _value -> required_address(params, key)
    end
  end

  defp required_signature(params, key) do
    case Text.normalize_optional_text(Map.get(params, key)) do
      value when is_binary(value) ->
        if Regex.match?(@signature_regex, value), do: {:ok, value}, else: invalid_request()

      _value ->
        invalid_request()
    end
  end

  defp required_agent_registry(params, key) do
    case Text.normalize_optional_text(Map.get(params, key)) do
      value when is_binary(value) ->
        if registry_address(value), do: {:ok, value}, else: invalid_request()

      _value ->
        invalid_request()
    end
  end

  defp optional_agent_registry(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      _value -> required_agent_registry(params, key)
    end
  end

  defp required_token_id(params, key) do
    case Text.normalize_optional_text(Map.get(params, key)) do
      value when is_binary(value) ->
        with true <- Regex.match?(~r/^(0|[1-9][0-9]{0,18})$/u, value),
             {token_id, ""} <- Integer.parse(value),
             true <- token_id <= @max_token_id do
          {:ok, token_id}
        else
          _value -> invalid_request()
        end

      _value ->
        invalid_request()
    end
  end

  defp optional_token_id(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      _value -> required_token_id(params, key)
    end
  end

  defp required_uuid(params, key) do
    case Text.normalize_optional_text(Map.get(params, key)) do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> invalid_request()
        end

      _value ->
        invalid_request()
    end
  end

  defp required_string(params, key) do
    case Text.normalize_optional_text(Map.get(params, key)) do
      nil -> invalid_request()
      value -> {:ok, value}
    end
  end

  defp optional_string(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      _value -> required_string(params, key)
    end
  end

  defp normalize_address(value) do
    with value when is_binary(value) <- Text.normalize_optional_text(value),
         true <- Regex.match?(@address_regex, value) do
      String.downcase(value)
    else
      _value -> nil
    end
  end

  defp agent_registry(network),
    do: "eip155:#{Map.fetch!(@networks, network)}:#{Map.fetch!(@registry_addresses, network)}"

  defp agent_id(agent_registry, token_id), do: "#{agent_registry}:#{token_id}"

  defp token_id(%IdentityRecord{id: id}), do: Integer.to_string(id)
  defp token_id(%SiwaNonce{agent_id: agent_id}), do: Integer.to_string(agent_id)

  defp registry_address(agent_registry) do
    case Regex.run(~r/0x[a-fA-F0-9]{40}$/u, agent_registry) do
      [address] -> String.downcase(address)
      _match -> nil
    end
  end

  defp cleanup_table(table, column, now, limit) do
    table = Atom.to_string(table)
    column = Atom.to_string(column)

    case Repo.query(
           """
           DELETE FROM #{table}
           WHERE id IN (
             SELECT id
             FROM #{table}
             WHERE #{column} <= $1
             ORDER BY #{column}
             LIMIT $2
           )
           """,
           [now, limit],
           log: false
         ) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp nonce_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ok(code, data), do: %{"ok" => true, "code" => code, "data" => data}

  defp invalid_request,
    do: {:error, {400, "invalid_request", "request body does not match the identity contract"}}

  defp registration_failed,
    do: {:error, {422, "registration_failed", "identity registration could not be completed"}}

  defp registration_mismatch,
    do: {:error, {422, "registration_failed", "registered identity does not match the request"}}

  defp siwa_verify_failed,
    do: {:error, {401, "siwa_verify_failed", "identity sign-in could not be verified"}}
end
