defmodule SiwaServer.PostQuantum.Credentials do
  @moduledoc """
  SIWA v3 Stage 2 post-quantum credential enrollment and lookup.

  Agents bind a local FIPS 204 `ML-DSA-65` public key to their existing EVM
  identity (`eip155:<chain_id>:<wallet_address>`) through a single-use
  5-minute challenge that requires dual Proof-of-Possession:
    1. Classical wallet signature (EOA EIP-191 or ERC-1271 smart wallet) over
       the canonical enrollment challenge message.
    2. Native OTP 29 `ML-DSA-65` signature over the domain-separated payload
       `"siwa-v3-enroll\\n" <> message`.

  Every check fails closed on unsupported runtime crypto, length mismatches,
  replayed or expired challenges, or invalid signatures.
  """

  import Ecto.Query

  alias SiwaServer.{Ethereum, Repo}
  alias SiwaServer.PostQuantum.{Credential, EnrollmentChallenge}

  @algorithm "mldsa65"
  @public_key_bytes 1_952
  @signature_bytes 3_309
  @enrollment_ttl_seconds 300
  @enrollment_domain_prefix "siwa-v3-enroll\n"
  @address_regex ~r/\A0x[0-9a-fA-F]{40}\z/
  @nonce_regex ~r/\A[a-f0-9]{32}\z/
  @ecc_sig_regex ~r/\A0x(?:[0-9a-fA-F]{2})+\z/

  @type refusal :: {:error, {pos_integer(), String.t(), String.t()}}

  @doc "True when this Erlang/OTP runtime exposes native FIPS 204 ML-DSA-65."
  @spec runtime_supported?() :: boolean()
  def runtime_supported?, do: :mldsa65 in :crypto.supports(:public_keys)

  @doc "Derive the canonical `pq_key_id` (`mldsa65:<lowercase_sha256_hex>`) from raw public key bytes."
  @spec pq_key_id(binary()) :: String.t()
  def pq_key_id(public_key)
      when is_binary(public_key) and byte_size(public_key) == @public_key_bytes do
    digest = :crypto.hash(:sha256, public_key) |> Base.encode16(case: :lower)
    "#{@algorithm}:#{digest}"
  end

  @doc "Format the canonical CAIP-10 subject for `(chain_id, lowercase_wallet_address)`."
  @spec subject_for(pos_integer(), String.t()) :: String.t()
  def subject_for(chain_id, wallet_address),
    do: "eip155:#{chain_id}:#{String.downcase(wallet_address)}"

  @doc "Domain-separated binary signed by the ML-DSA-65 private key during enrollment."
  @spec enrollment_signing_payload(String.t()) :: binary()
  def enrollment_signing_payload(message) when is_binary(message),
    do: @enrollment_domain_prefix <> message

  @doc """
  Verify the ML-DSA-65 Proof-of-Possession signature over `message`.
  Pure and offline-checkable; fails closed on any length or runtime error.
  """
  @spec verify_enrollment_pop(String.t(), binary(), binary()) :: :ok | refusal()
  def verify_enrollment_pop(message, signature, public_key)
      when is_binary(message) and is_binary(signature) and is_binary(public_key) do
    cond do
      not runtime_supported?() ->
        {:error,
         {503, "pq_algorithm_unsupported",
          "post-quantum ML-DSA-65 verification is unavailable on this runtime"}}

      byte_size(public_key) != @public_key_bytes ->
        {:error,
         {400, "invalid_pq_public_key", "ML-DSA-65 public key must be exactly 1952 raw bytes"}}

      byte_size(signature) != @signature_bytes ->
        {:error,
         {401, "pq_signature_invalid", "ML-DSA-65 proof-of-possession signature is invalid"}}

      :crypto.verify(:mldsa65, :none, enrollment_signing_payload(message), signature, public_key) ->
        :ok

      true ->
        {:error,
         {401, "pq_signature_invalid", "ML-DSA-65 proof-of-possession signature did not verify"}}
    end
  rescue
    _ ->
      {:error,
       {401, "pq_signature_invalid", "ML-DSA-65 proof-of-possession signature did not verify"}}
  end

  @doc """
  Issue a single-use 5-minute enrollment challenge binding `(wallet_address, chain_id)`
  to a candidate `ML-DSA-65` public key.
  """
  @spec issue_enrollment_challenge(map()) :: {:ok, map()} | refusal()
  def issue_enrollment_challenge(params) when is_map(params) do
    with :ok <- ensure_runtime_ready(),
         {:ok, req} <- cast_challenge_request(params),
         :ok <- ensure_key_not_enrolled(req.pq_key_id) do
      issued_at = DateTime.utc_now() |> DateTime.truncate(:second)
      expires_at = DateTime.add(issued_at, @enrollment_ttl_seconds)
      nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      message = build_enrollment_message(req, nonce, issued_at, expires_at)

      challenge =
        Repo.insert!(
          %EnrollmentChallenge{
            subject: req.subject,
            wallet_address: req.wallet_address,
            chain_id: req.chain_id,
            pq_key_id: req.pq_key_id,
            algorithm: @algorithm,
            public_key: req.public_key,
            nonce: nonce,
            canonical_message: message,
            issued_at: issued_at,
            expiration_time: expires_at
          },
          log: false
        )

      {:ok,
       %{
         "code" => "pq_enroll_challenge_issued",
         "data" => %{
           "subject" => challenge.subject,
           "walletAddress" => challenge.wallet_address,
           "chainId" => challenge.chain_id,
           "algorithm" => challenge.algorithm,
           "pqKeyId" => challenge.pq_key_id,
           "nonce" => challenge.nonce,
           "message" => challenge.canonical_message,
           "pqSigningPrefix" => @enrollment_domain_prefix,
           "issuedAt" => DateTime.to_iso8601(challenge.issued_at),
           "expiresAt" => DateTime.to_iso8601(challenge.expiration_time)
         }
       }}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> unavailable()
  end

  def issue_enrollment_challenge(_other),
    do:
      {:error, {400, "invalid_request", "request body does not match the PQ challenge contract"}}

  @doc """
  Complete dual Proof-of-Possession enrollment for an issued challenge.

  Verifies BOTH the classical wallet signature (EIP-191 / ERC-1271) AND the
  native FIPS 204 `ML-DSA-65` signature before consuming the challenge once and
  storing the enrolled credential under `policy: "hybrid_both"`.
  """
  @spec enroll(map()) :: {:ok, map()} | refusal()
  def enroll(params) when is_map(params) do
    with :ok <- ensure_runtime_ready(),
         {:ok, req} <- cast_enroll_request(params),
         {:ok, challenge} <- fetch_challenge(req),
         :ok <- ensure_challenge_current(challenge, req.message),
         :ok <- verify_enrollment_pop(req.message, req.pq_signature, challenge.public_key),
         {:ok, ecc_method} <- verify_wallet_sig(challenge, req.message, req.ecc_signature),
         :ok <- consume_challenge(challenge),
         {:ok, credential} <- insert_credential(challenge) do
      {:ok,
       %{
         "code" => "pq_credential_enrolled",
         "data" => %{
           "id" => credential.id,
           "subject" => credential.subject,
           "walletAddress" => credential.wallet_address,
           "chainId" => credential.chain_id,
           "pqKeyId" => credential.pq_key_id,
           "algorithm" => credential.algorithm,
           "algVersion" => credential.alg_version,
           "policy" => credential.policy,
           "eccVerificationMethod" => Atom.to_string(ecc_method),
           "enrolledAt" => DateTime.to_iso8601(credential.enrolled_at)
         }
       }}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> unavailable()
  end

  def enroll(_other),
    do: {:error, {400, "invalid_request", "request body does not match the PQ enroll contract"}}

  @doc "Return all non-revoked post-quantum credentials enrolled for `subject`."
  @spec active_for_subject(String.t()) :: [Credential.t()]
  def active_for_subject(subject) when is_binary(subject) do
    from(c in Credential,
      where: c.subject == ^subject and is_nil(c.revoked_at),
      order_by: [desc: c.enrolled_at]
    )
    |> Repo.all(log: false)
  end

  @doc "Delete up to `limit` expired PQ enrollment challenges."
  # Fixed SQL text with one bound limit parameter, matching Challenge.cleanup_expired/1.
  # sobelow_skip ["SQL.Query"]
  @spec cleanup_expired_challenges(pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired_challenges(limit) when is_integer(limit) and limit > 0 do
    with {:ok, %{num_rows: count}} <-
           Repo.query(
             """
             DELETE FROM pq_enrollment_challenges
             WHERE id IN (
               SELECT id FROM pq_enrollment_challenges
               WHERE expiration_time <= (statement_timestamp() AT TIME ZONE 'UTC')
               ORDER BY expiration_time
               LIMIT $1
             )
             """,
             [limit],
             log: false
           ) do
      {:ok, count}
    end
  end

  # --- Validation helpers ---

  defp ensure_runtime_ready do
    if runtime_supported?() do
      :ok
    else
      {:error,
       {503, "pq_algorithm_unsupported",
        "post-quantum ML-DSA-65 enrollment requires OTP 28.1+ with OpenSSL 3.5+"}}
    end
  end

  defp cast_challenge_request(params) do
    allowed = ~w(wallet_address chain_id algorithm public_key)

    with [] <- Map.keys(params) -- allowed,
         {:ok, wallet} <- parse_address(params["wallet_address"]),
         {:ok, chain_id} <- parse_chain_id(params["chain_id"]),
         :ok <- parse_algorithm(params["algorithm"]),
         {:ok, pub_bytes} <- decode_exact_b64(params["public_key"], @public_key_bytes) do
      {:ok,
       %{
         wallet_address: wallet,
         chain_id: chain_id,
         subject: subject_for(chain_id, wallet),
         public_key: pub_bytes,
         pq_key_id: pq_key_id(pub_bytes)
       }}
    else
      {:error, _} = err ->
        err

      _ ->
        {:error,
         {400, "invalid_request",
          "provide wallet_address, chain_id, algorithm (mldsa65), and base64 public_key (1952 bytes)"}}
    end
  end

  defp cast_enroll_request(params) do
    allowed = ~w(wallet_address chain_id pq_key_id nonce message ecc_signature pq_signature)

    with [] <- Map.keys(params) -- allowed,
         {:ok, wallet} <- parse_address(params["wallet_address"]),
         {:ok, chain_id} <- parse_chain_id(params["chain_id"]),
         {:ok, key_id} <- parse_pq_key_id(params["pq_key_id"]),
         {:ok, nonce} <- parse_nonce(params["nonce"]),
         {:ok, message} <- parse_message(params["message"]),
         {:ok, ecc_sig} <- parse_ecc_signature(params["ecc_signature"]),
         {:ok, pq_sig} <- decode_exact_b64(params["pq_signature"], @signature_bytes) do
      {:ok,
       %{
         wallet_address: wallet,
         chain_id: chain_id,
         subject: subject_for(chain_id, wallet),
         pq_key_id: key_id,
         nonce: nonce,
         message: message,
         ecc_signature: ecc_sig,
         pq_signature: pq_sig
       }}
    else
      {:error, _} = err ->
        err

      _ ->
        {:error,
         {400, "invalid_request",
          "provide wallet_address, chain_id, pq_key_id, nonce, message, ecc_signature, and pq_signature"}}
    end
  end

  defp parse_address(addr) when is_binary(addr) do
    if Regex.match?(@address_regex, addr),
      do: {:ok, String.downcase(addr)},
      else:
        {:error,
         {400, "invalid_request", "wallet_address must be a 0x-prefixed 20-byte hex address"}}
  end

  defp parse_address(_), do: :error

  defp parse_chain_id(chain_id) when is_integer(chain_id) do
    if chain_id in Ethereum.wallet_chain_ids(),
      do: {:ok, chain_id},
      else: {:error, {400, "invalid_request", "unsupported chain_id for wallet proof"}}
  end

  defp parse_chain_id(_), do: :error

  defp parse_algorithm("mldsa65"), do: :ok
  defp parse_algorithm(nil), do: :ok

  defp parse_algorithm(_),
    do: {:error, {400, "pq_algorithm_unsupported", "only algorithm mldsa65 is supported"}}

  defp parse_pq_key_id("mldsa65:" <> hex = full) when byte_size(hex) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, hex), do: {:ok, full}, else: :error
  end

  defp parse_pq_key_id(_), do: :error

  defp parse_nonce(nonce) when is_binary(nonce) do
    if Regex.match?(@nonce_regex, nonce), do: {:ok, nonce}, else: :error
  end

  defp parse_nonce(_), do: :error

  defp parse_message(msg) when is_binary(msg) and byte_size(msg) in 1..2_048, do: {:ok, msg}
  defp parse_message(_), do: :error

  defp parse_ecc_signature(sig) when is_binary(sig) do
    max_len = 2 + 2 * Siwa.WalletSignature.max_bytes()

    if byte_size(sig) <= max_len and Regex.match?(@ecc_sig_regex, sig),
      do: {:ok, sig},
      else: :error
  end

  defp parse_ecc_signature(_), do: :error

  defp decode_exact_b64(encoded, expected_bytes) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, raw} when byte_size(raw) == expected_bytes -> {:ok, raw}
      _ -> :error
    end
  end

  defp decode_exact_b64(_other, _expected), do: :error

  # --- Persistence helpers ---

  defp ensure_key_not_enrolled(key_id) do
    case Repo.get_by(Credential, [pq_key_id: key_id], log: false) do
      nil ->
        :ok

      _existing ->
        {:error, {409, "pq_key_already_enrolled", "this ML-DSA-65 key is already enrolled"}}
    end
  end

  defp fetch_challenge(req) do
    case Repo.get_by(
           EnrollmentChallenge,
           [subject: req.subject, pq_key_id: req.pq_key_id, nonce: req.nonce],
           log: false
         ) do
      nil ->
        {:error,
         {404, "pq_challenge_not_found", "enrollment challenge not found or already used"}}

      challenge ->
        {:ok, challenge}
    end
  end

  defp ensure_challenge_current(challenge, message) do
    cond do
      DateTime.compare(challenge.expiration_time, DateTime.utc_now()) != :gt ->
        {:error, {401, "pq_challenge_expired", "enrollment challenge expired"}}

      message != challenge.canonical_message ->
        {:error,
         {401, "message_invalid", "sign the exact current server-issued enrollment message"}}

      true ->
        :ok
    end
  end

  defp verify_wallet_sig(challenge, message, ecc_signature) do
    case Ethereum.verify_signature(
           challenge.wallet_address,
           message,
           ecc_signature,
           challenge.chain_id
         ) do
      {:ok, method} ->
        {:ok, method}

      {:error, :signature_invalid} ->
        {:error, {401, "signature_invalid", "classical wallet signature does not match wallet"}}

      {:error, {:lookup_failed, reason}} ->
        {:error,
         {502, "signature_lookup_failed",
          "could not check wallet signature on #{Ethereum.chain_name(challenge.chain_id)}: #{reason}"}}
    end
  end

  # Fixed SQL text with bound parameters; re-checks expiry via clock_timestamp().
  # sobelow_skip ["SQL.Query"]
  defp consume_challenge(challenge) do
    query = """
    WITH consumed AS (
      DELETE FROM pq_enrollment_challenges
      WHERE id = $1 AND nonce = $2 AND subject = $3 AND pq_key_id = $4
        AND expiration_time > (clock_timestamp() AT TIME ZONE 'UTC')
      RETURNING expiration_time
    )
    SELECT expiration_time > (clock_timestamp() AT TIME ZONE 'UTC') FROM consumed
    """

    case Repo.query(
           query,
           [challenge.id, challenge.nonce, challenge.subject, challenge.pq_key_id],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} ->
        :ok

      {:ok, %{rows: _}} ->
        {:error,
         {401, "pq_challenge_expired", "enrollment challenge expired or already consumed"}}

      {:error, _} ->
        unavailable()
    end
  end

  defp insert_credential(challenge) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      subject: challenge.subject,
      wallet_address: challenge.wallet_address,
      chain_id: challenge.chain_id,
      pq_key_id: challenge.pq_key_id,
      algorithm: challenge.algorithm,
      alg_version: 1,
      public_key: challenge.public_key,
      policy: "hybrid_both",
      enrolled_at: now
    }

    case Credential.create_changeset(attrs) |> Repo.insert(log: false) do
      {:ok, credential} ->
        {:ok, credential}

      {:error, %Ecto.Changeset{}} ->
        {:error, {409, "pq_key_already_enrolled", "this ML-DSA-65 key is already enrolled"}}
    end
  end

  defp build_enrollment_message(req, nonce, issued_at, expires_at) do
    Enum.join(
      [
        "SIWA v3 Post-Quantum Credential Enrollment",
        "",
        "Bind FIPS 204 ML-DSA-65 credential to agent identity:",
        "Subject: #{req.subject}",
        "Algorithm: #{@algorithm}",
        "PQ Key ID: #{req.pq_key_id}",
        "Nonce: #{nonce}",
        "Issued At: #{DateTime.to_iso8601(issued_at)}",
        "Expiration Time: #{DateTime.to_iso8601(expires_at)}"
      ],
      "\n"
    )
  end

  defp unavailable,
    do:
      {:error,
       {500, "pq_enrollment_unavailable", "post-quantum credential enrollment is unavailable"}}
end
