defmodule SiwaServer.HostedIdentities do
  @moduledoc """
  The signing keys of sites' hosted connections (`SiwaServer.HostedRequests`),
  one per identity, kept in the database encrypted with the key store password,
  so every machine signs with the same key. A key is made the first time its
  identity registers and is never exported or replaced.
  """

  import Ecto.Query

  alias SiwaKeyring.HostedIdentity
  alias SiwaServer.{Config, Repo}

  @table "siwa_hosted_identities"

  @doc "Makes the identity's key if it has none, and answers with its address."
  def ensure(identity) do
    with :ok <- create_once(identity),
         {:ok, signer} <- signer(identity),
         {:ok, address} <- Siwa.RemoteSigner.get_address(signer) do
      {:ok, %{address: address}}
    end
  end

  @doc "The signer of an identity that has registered."
  def signer(identity) do
    case Repo.one(from(h in @table, where: h.identity == ^identity, select: h.encrypted_wallet)) do
      nil -> {:error, :wallet_missing}
      encrypted -> open(encrypted)
    end
  end

  @doc "Whether the key store password opens the stored keys, tried on one; `:ok` when none is stored."
  def readable do
    case Repo.one(from(h in @table, select: h.encrypted_wallet, limit: 1)) do
      nil -> :ok
      encrypted -> with {:ok, _signer} <- open(encrypted), do: :ok
    end
  end

  # Every key is encrypted with the one password, so a stored key that does not
  # open means the password is not the one the keys were made with.
  defp open(encrypted) do
    case HostedIdentity.signer(encrypted, password()) do
      {:error, :keystore_decrypt_failed} -> {:error, :hosted_key_unreadable}
      opened -> opened
    end
  end

  # Two machines registering one identity at once both keep the first key stored.
  defp create_once(identity) do
    if Repo.exists?(from(h in @table, where: h.identity == ^identity)) do
      :ok
    else
      with {:ok, encrypted} <- HostedIdentity.new(password()) do
        Repo.insert_all(@table, [%{identity: identity, encrypted_wallet: encrypted}],
          on_conflict: :nothing
        )

        :ok
      end
    end
  end

  defp password, do: Config.keystore_password()
end
