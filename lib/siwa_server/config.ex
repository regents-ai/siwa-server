defmodule SiwaServer.Config do
  @moduledoc """
  The SIWA settings, checked once where they come in.

  `config/runtime.exs` reads the environment when the server starts and parses
  each list with the `!` functions here, which raise on anything outside the
  contract; every positive integer is checked there too. Everything else reads
  the values back as they are.

  The chain RPC URLs are the exception: they are read from the environment on
  every call, trimmed, and are `nil` when unset or blank.
  """

  @site_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @key_regex ~r/^[A-Za-z0-9_-]{32,}$/
  # Labels of at most 63 characters; the last starts with a letter, so no host is a number.
  @origin_regex ~r/\Ahttps:\/\/(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @local_origin_regex ~r/\Ahttp:\/\/localhost:[1-9][0-9]{0,4}\z/

  def base_rpc_url, do: env_url("BASE_RPC_URL")
  def ethereum_rpc_url, do: env_url("ETHEREUM_RPC_URL")
  def world_rpc_url, do: env_url("WORLD_RPC_URL")

  @spec receipt_secret() :: {:ok, String.t()} | {:error, {500, String.t(), String.t()}}
  def receipt_secret do
    case Keyword.get(siwa(), :receipt_secret) do
      nil -> {:error, {500, "siwa_not_configured", "SIWA receipt secret is not configured"}}
      secret -> {:ok, secret}
    end
  end

  def nonce_ttl_seconds, do: Keyword.fetch!(siwa(), :nonce_ttl_seconds)
  def receipt_ttl_seconds, do: Keyword.fetch!(siwa(), :receipt_ttl_seconds)

  @doc """
  How long a site may check an agent's requests that read itself after this
  server verified one (`SiwaServer.Siwa.HttpVerifier`).
  """
  def lease_seconds, do: Keyword.fetch!(siwa(), :lease_seconds)

  def http_signature_tolerance_seconds,
    do: Keyword.fetch!(siwa(), :http_signature_tolerance_seconds)

  @doc "Each audience that accepts wallet sign-in and its origins, first one named in the challenge."
  @spec wallet_origins() :: %{String.t() => [String.t(), ...]}
  def wallet_origins, do: Keyword.fetch!(siwa(), :wallet_origins)

  def keystore_password, do: Keyword.fetch!(siwa(), :keystore_password)

  @doc "The site whose activity read key the Authorization header presents."
  @spec activity_reader(String.t()) :: {:ok, String.t()} | :error
  def activity_reader(authorization),
    do: key_owner(Keyword.fetch!(siwa(), :activity_readers), authorization)

  @doc "The site whose hosted signing key the Authorization header presents."
  @spec hosted_signer(String.t()) :: {:ok, String.t()} | :error
  def hosted_signer(authorization),
    do: key_owner(Keyword.fetch!(siwa(), :hosted_signers), authorization)

  @doc """
  Parses `SIWA_ACTIVITY_READERS`, the sites allowed to read wallet activity, as
  a comma-separated list of `site=key` entries. It must name at least one site.
  """
  @spec activity_readers!(String.t()) :: %{String.t() => String.t()}
  def activity_readers!(value) do
    readers = site_keys!(value, "SIWA_ACTIVITY_READERS")

    if readers == %{} do
      raise ArgumentError, "SIWA_ACTIVITY_READERS must name at least one site"
    end

    readers
  end

  @doc """
  Parses `SIWA_HOSTED_SIGNERS`, the sites allowed to ask for hosted signing, as
  a comma-separated list of `site=key` entries. The site name is the audience
  every request it signs is bound to. An empty list lets no site sign.
  """
  @spec hosted_signers!(String.t()) :: %{String.t() => String.t()}
  def hosted_signers!(value), do: site_keys!(value, "SIWA_HOSTED_SIGNERS")

  @doc """
  Checks `SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS`. A signed request may last no
  longer than the tolerance, so the tolerance is at least the contract's
  signing lifetime, the one every helper signs for.
  """
  @spec http_signature_tolerance_seconds!(pos_integer()) :: pos_integer()
  def http_signature_tolerance_seconds!(seconds) do
    lifetime = Siwa.Contract.lifetime_seconds()

    if seconds < lifetime do
      raise ArgumentError,
            "SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS must be at least #{lifetime}, the contract's signing lifetime"
    end

    seconds
  end

  @doc """
  Parses `SIWA_WALLET_ORIGINS`, the approved audience-to-origin table for
  wallet sign-in.

  The value is a comma-separated list of `audience=origin` entries, for example
  `patchbay=https://patchbay.help,keyfleet=https://keyfleet.example`. An audience
  may list several origins, one entry each; its first entry is the origin the
  sign-in challenge names. No origin appears twice, so every origin belongs to
  exactly one audience. Each origin is written in its one spelling: `https://`
  and a lowercase host name, with no port, trailing dot, credentials, path, query or
  fragment (one trailing slash is dropped). A host is a name, never a number: its
  last label starts with a letter, and no label is longer than 63 characters. An empty or missing value
  disables wallet sign-in for every audience. Callers never supply origins; only
  this table does.

  A server run on a computer for local work (`local: true`, every environment
  but production) also accepts `http://localhost:<port>`, so a site run there
  can check the requests its agents sign for it.
  """
  @spec wallet_origins!(String.t() | nil, keyword()) :: %{String.t() => [String.t(), ...]}
  def wallet_origins!(value, opts \\ [])
  def wallet_origins!(nil, _opts), do: %{}

  def wallet_origins!(value, opts) do
    local = Keyword.get(opts, :local, false)
    entries = value |> entries() |> Enum.map(&origin_entry!(&1, local))

    duplicate =
      entries
      |> Enum.map(&elem(&1, 1))
      |> Enum.frequencies()
      |> Enum.find_value(fn {origin, count} -> if count > 1, do: origin end)

    if duplicate do
      raise ArgumentError, "SIWA_WALLET_ORIGINS lists the origin #{duplicate} twice"
    end

    Enum.group_by(entries, &elem(&1, 0), &elem(&1, 1))
  end

  defp siwa, do: Application.fetch_env!(:siwa_server, :siwa)

  defp env_url(name) do
    case name |> System.get_env("") |> String.trim() do
      "" -> nil
      url -> url
    end
  end

  defp key_owner(keys, authorization) do
    Enum.find_value(keys, :error, fn {site, key} ->
      if Plug.Crypto.secure_compare(authorization, "Bearer " <> key), do: {:ok, site}
    end)
  end

  # Each key is at least 32 characters, and no two sites share a name or a key,
  # so every key names exactly one site and replacing one leaves the others.
  defp site_keys!(value, env_name) do
    keys =
      value
      |> entries()
      |> Enum.reduce(%{}, fn entry, keys ->
        {site, key} = site_key!(entry, env_name)

        if Map.has_key?(keys, site) do
          raise ArgumentError, "#{env_name} lists the site #{site} twice"
        end

        Map.put(keys, site, key)
      end)

    if keys |> Map.values() |> Enum.uniq() |> length() != map_size(keys) do
      raise ArgumentError, "#{env_name} gives two sites the same key"
    end

    keys
  end

  defp site_key!(entry, env_name) do
    with [site, key] <- String.split(entry, "=", parts: 2),
         site = String.trim(site),
         key = String.trim(key),
         true <- Regex.match?(@site_regex, site),
         true <- Regex.match?(@key_regex, key) do
      {site, key}
    else
      _invalid ->
        raise ArgumentError,
              "#{env_name} entries must look like site=key, with a key of at least 32 letters, digits, - or _"
    end
  end

  defp origin_entry!(entry, local) do
    case String.split(entry, "=", parts: 2) do
      [audience, origin] ->
        audience = String.trim(audience)
        origin = origin |> String.trim() |> String.replace_suffix("/", "")

        unless Regex.match?(@site_regex, audience) do
          raise ArgumentError,
                "SIWA_WALLET_ORIGINS audience #{inspect(audience)} is not a valid name"
        end

        unless Regex.match?(@origin_regex, origin) or
                 (local and Regex.match?(@local_origin_regex, origin)) do
          raise ArgumentError,
                "SIWA_WALLET_ORIGINS origin #{inspect(origin)} must be https:// and a lowercase host, with nothing else"
        end

        {audience, origin}

      _ ->
        raise ArgumentError,
              "SIWA_WALLET_ORIGINS entries must look like audience=https://origin, got #{inspect(entry)}"
    end
  end

  defp entries(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
