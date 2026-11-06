defmodule SiwaServer.HostedIdentities do
  @moduledoc """
  The signing keys of sites' hosted connections (`SiwaServer.HostedRequests`),
  one per identity, kept in the database encrypted with the key store password,
  so every machine signs with the same key. A key is made the first time its
  identity registers and is never exported or replaced.
  """

  import Ecto.Query

  require Logger

  alias SiwaKeyring.HostedIdentity
  alias SiwaServer.Repo

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
      encrypted -> HostedIdentity.signer(encrypted, password())
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

  defp password, do: Application.fetch_env!(:siwa_keyring, :password)

  @doc false
  # Started once before the site answers, in the release that moves the keys off the
  # volume: copies each key file into the database unchanged, then logs how many of
  # the files the database holds byte for byte. The next release removes it.
  def copy_from_volume do
    dir = Application.fetch_env!(:siwa_keyring, :path) <> ".hosted"

    case File.ls(dir) do
      {:ok, names} -> copy_files(dir, names)
      {:error, :enoent} -> Logger.info("hosted keys on the volume: none")
    end

    :ignore
  end

  # The folder is the operator-configured key store's and each name read matched
  # the 64-letter identity pattern; nothing a caller sends reaches File.read!.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_files(dir, names) do
    files =
      for name <- names,
          [_, identity] <- [Regex.run(~r/\A([a-f0-9]{64})\.bin\z/, name)],
          do: {identity, File.read!(Path.join(dir, name))}

    {copied, _} =
      Repo.insert_all(
        @table,
        Enum.map(files, fn {identity, encrypted} ->
          %{identity: identity, encrypted_wallet: encrypted}
        end),
        on_conflict: :nothing
      )

    stored =
      Map.new(
        Repo.all(
          from(h in @table,
            where: h.identity in ^Enum.map(files, &elem(&1, 0)),
            select: {h.identity, h.encrypted_wallet}
          )
        )
      )

    matching = Enum.count(files, fn {identity, encrypted} -> stored[identity] == encrypted end)

    level = if matching == length(files), do: :info, else: :error

    Logger.log(
      level,
      "hosted keys on the volume: #{length(files)}, copied now: #{copied}, " <>
        "the same in the database: #{matching}"
    )
  end
end
