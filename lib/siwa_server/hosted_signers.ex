defmodule SiwaServer.HostedSigners do
  @moduledoc """
  Parses `SIWA_HOSTED_SIGNERS`, the sites allowed to ask for hosted signing and
  each site's own key for it.

  The value is a comma-separated list of `site=key` entries, for example
  `patchbay=<key>`. The site name is the audience every request it signs is
  bound to. Each key is at least 32 characters, works only for hosted signing,
  and no two sites share a name or a key. An empty or missing value lets no site
  sign.
  """

  @site_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @key_regex ~r/^[A-Za-z0-9_-]{32,}$/

  @spec parse!(String.t() | nil) :: %{String.t() => String.t()}
  def parse!(value) when value in [nil, ""], do: %{}

  def parse!(value) when is_binary(value) do
    signers =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(%{}, fn entry, signers ->
        {site, key} = parse_entry!(entry)

        if Map.has_key?(signers, site) do
          raise ArgumentError, "SIWA_HOSTED_SIGNERS lists the site #{site} twice"
        end

        Map.put(signers, site, key)
      end)

    if signers |> Map.values() |> Enum.uniq() |> length() != map_size(signers) do
      raise ArgumentError, "SIWA_HOSTED_SIGNERS gives two sites the same key"
    end

    signers
  end

  @doc "The site whose key the Authorization header presents, compared in constant time."
  @spec site(%{String.t() => String.t()}, String.t()) :: {:ok, String.t()} | :error
  def site(signers, authorization) do
    Enum.find_value(signers, :error, fn {site, key} ->
      if Plug.Crypto.secure_compare(authorization, "Bearer " <> key), do: {:ok, site}
    end)
  end

  defp parse_entry!(entry) do
    with [site, key] <- String.split(entry, "=", parts: 2),
         site = String.trim(site),
         key = String.trim(key),
         true <- Regex.match?(@site_regex, site),
         true <- Regex.match?(@key_regex, key) do
      {site, key}
    else
      _invalid ->
        raise ArgumentError,
              "SIWA_HOSTED_SIGNERS entries must look like site=key, with a key of at least 32 letters, digits, - or _"
    end
  end
end
