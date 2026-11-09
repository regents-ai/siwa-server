defmodule SiwaServer.Siwa.Challenge do
  @moduledoc """
  A single-use message a wallet signs to prove itself: wallet sign-in
  (`SiwaServer.Siwa.Wallet`) and accepting a World ID person
  (`SiwaServer.AgentBook`).

  `cast/2` checks the request once. `issue/3` stores a challenge in
  `siwa_nonces` for the challenge lifetime; `fetch/2` finds it again by the
  same scope and its nonce; `signed/3` checks the wallet's signature over it;
  `consume/1` uses it up, at most once. A scope is a list whose head names the
  kind of challenge, followed by what it is bound to; the challenge is found
  by a digest of the whole list, so it always names what the scope names.
  """

  use Ecto.Schema

  import Ecto.Changeset,
    only: [
      apply_action: 2,
      update_change: 3,
      validate_format: 3,
      validate_inclusion: 3,
      validate_length: 3,
      validate_required: 2
    ]

  alias SiwaServer.{Config, Ethereum, Repo}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "siwa_nonces" do
    field :chain_id, :integer
    field :canonical_message, :string
    field :nonce_key, :string
    field :nonce, :string
    field :address, :string
    field :audience, :string
    field :issued_at, :utc_datetime
    field :expiration_time, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
  @type error :: {:error, {pos_integer(), String.t(), String.t()}}

  # The chain id is taken as sent, so only a JSON number that names a sign-in
  # chain passes.
  @types %{
    wallet_address: :string,
    chain_id: :any,
    audience: :string,
    nonce: :string,
    message: :string,
    signature: :string
  }

  @doc """
  The request when it has exactly `fields`, each in the contract's shape, with
  the wallet address in lower case; otherwise `:error`.
  """
  @spec cast(map(), [atom()]) :: {:ok, map()} | :error
  def cast(params, fields) do
    changeset =
      {%{}, @types}
      |> Ecto.Changeset.cast(params, fields, empty_values: [])
      |> validate_required(fields)
      |> validate_inclusion(:chain_id, Ethereum.wallet_chain_ids())
      |> validate_format(:wallet_address, ~r/^0x[0-9a-fA-F]{40}$/)
      |> validate_length(:audience, min: 1, max: 200, count: :bytes)
      |> validate_format(:nonce, ~r/^[a-f0-9]{32}$/)
      |> validate_length(:message, min: 1, max: 2048, count: :bytes)
      |> validate_length(:signature,
        max: 2 + 2 * Siwa.WalletSignature.max_bytes(),
        count: :bytes
      )
      |> validate_format(:signature, ~r/^0x(?:[0-9a-fA-F]{2})+$/)
      |> update_change(:wallet_address, &String.downcase/1)

    with [] <- Map.keys(params) -- Enum.map(fields, &Atom.to_string/1),
         {:ok, request} <- apply_action(changeset, :cast) do
      {:ok, request}
    else
      _invalid -> :error
    end
  end

  @doc """
  Stores a new challenge in `scope` for the wallet `address` on `chain_id`,
  for `audience`, valid for the challenge lifetime. `message` writes the text
  to sign from the challenge.
  """
  @spec issue(
          list(),
          %{address: String.t(), chain_id: pos_integer(), audience: String.t()},
          (t() -> String.t())
        ) :: t()
  def issue(scope, attrs, message) do
    issued_at = DateTime.utc_now() |> DateTime.truncate(:second)

    challenge =
      struct!(
        __MODULE__,
        Map.merge(attrs, %{
          nonce_key: key(scope),
          nonce: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
          issued_at: issued_at,
          expiration_time: DateTime.add(issued_at, Config.nonce_ttl_seconds())
        })
      )

    Repo.insert!(%{challenge | canonical_message: message.(challenge)}, log: false)
  end

  @doc "The challenge in `scope` with `nonce`, until it is used up or removed."
  @spec fetch(list(), String.t()) :: {:ok, t()} | error()
  def fetch(scope, nonce) do
    case Repo.get_by(__MODULE__, [nonce_key: key(scope), nonce: nonce], log: false) do
      nil -> not_found()
      challenge -> {:ok, challenge}
    end
  end

  @doc """
  How the challenge's wallet signed `message`, on the chain it signed in on
  (`SiwaServer.Ethereum.verify_signature/4`).
  """
  @spec signed(t(), String.t(), String.t()) :: {:ok, Siwa.WalletSignature.method()} | error()
  def signed(challenge, message, signature) do
    case Ethereum.verify_signature(challenge.address, message, signature, challenge.chain_id) do
      {:ok, method} ->
        {:ok, method}

      {:error, :signature_invalid} ->
        {:error, {401, "signature_invalid", "signature does not match wallet"}}

      {:error, {:lookup_failed, reason}} ->
        {:error,
         {502, "signature_lookup_failed",
          "could not check the wallet signature on #{Ethereum.chain_name(challenge.chain_id)}: #{reason}"}}
    end
  end

  @doc """
  Uses the challenge up. Only one caller succeeds, and only while it has not
  ended by the database clock.
  """
  # Fixed SQL text; every value, including both expiry checks around the row-lock
  # wait, is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  @spec consume(t()) :: :ok | error() | {:error, Exception.t()}
  def consume(challenge) do
    # The outer SELECT re-checks `expiration_time` after the DELETE has waited
    # on any row lock: a nonce that expires while a contender is blocked on the
    # lock is never consumed successfully. The DELETE's own WHERE alone is not
    # re-evaluated after the wait when the row was locked but not modified.
    query = """
    WITH consumed AS (
      DELETE FROM siwa_nonces
      WHERE nonce_key = $1 AND nonce = $2
        AND address = $3 AND chain_id = $4 AND audience = $5 AND canonical_message = $6
        AND issued_at = $7 AND expiration_time = $8
        AND expiration_time > (clock_timestamp() AT TIME ZONE 'UTC')
      RETURNING id, expiration_time
    )
    SELECT id FROM consumed
    WHERE expiration_time > (clock_timestamp() AT TIME ZONE 'UTC')
    """

    case Repo.query(
           query,
           [
             challenge.nonce_key,
             challenge.nonce,
             challenge.address,
             challenge.chain_id,
             challenge.audience,
             challenge.canonical_message,
             challenge.issued_at,
             challenge.expiration_time
           ],
           log: false
         ) do
      {:ok, %{rows: [[_id]]}} -> :ok
      {:ok, %{rows: []}} -> not_found()
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes up to `limit` ended challenges. They are judged by the database
  clock, the one `consume/1` checks with: by the app's clock running ahead, a
  challenge could go while it can still be used, and a valid sign-in would be
  refused. `statement_timestamp()` is read once, so the `expiration_time` index
  finds the rows.
  """
  @spec cleanup_expired(pos_integer()) :: {:ok, non_neg_integer()} | {:error, Exception.t()}
  def cleanup_expired(limit) do
    case Repo.query(
           """
           DELETE FROM siwa_nonces
           WHERE id IN (
             SELECT id
             FROM siwa_nonces
             WHERE expiration_time <= (statement_timestamp() AT TIME ZONE 'UTC')
             ORDER BY expiration_time
             LIMIT $1
           )
           """,
           [limit],
           log: false
         ) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp key([kind | _bound] = scope),
    do: kind <> ":" <> Base.encode16(:crypto.hash(:sha256, Jason.encode!(scope)), case: :lower)

  defp not_found,
    do: {:error, {404, "nonce_not_found", "challenge absent, expired or consumed"}}
end
