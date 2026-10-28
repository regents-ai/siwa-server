defmodule SiwaServer.SiteKeys do
  @moduledoc """
  The one shape behind every per-site key setting (`SIWA_ACTIVITY_READERS`,
  `SIWA_HOSTED_SIGNERS`, `SIWA_SITE_VERIFY_KEYS`): a comma-separated list of
  `site=key` entries, for example `regents=<key>,patchbay=<key>`.

  Each site name is lowercase, each key is at least 32 letters, digits, `-` or
  `_`, and no two entries share a site or a key, so a presented key names
  exactly one site. Replacing one site's key leaves the others untouched.
  """

  @site_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @key_regex ~r/^[A-Za-z0-9_-]{32,}$/

  @doc "Parses `value`, read from the setting `name`; an empty value lists no site."
  @spec parse!(String.t(), String.t()) :: %{String.t() => String.t()}
  def parse!(value, name) when is_binary(value) and is_binary(name) do
    keys =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(%{}, fn entry, keys ->
        {site, key} = parse_entry!(entry, name)

        if Map.has_key?(keys, site) do
          raise ArgumentError, "#{name} lists the site #{site} twice"
        end

        Map.put(keys, site, key)
      end)

    if keys |> Map.values() |> Enum.uniq() |> length() != map_size(keys) do
      raise ArgumentError, "#{name} gives two sites the same key"
    end

    keys
  end

  @doc "The site whose key the Authorization header presents, compared in constant time."
  @spec site(%{String.t() => String.t()}, String.t()) :: {:ok, String.t()} | :error
  def site(keys, authorization) do
    Enum.find_value(keys, :error, fn {site, key} ->
      if Plug.Crypto.secure_compare(authorization, "Bearer " <> key), do: {:ok, site}
    end)
  end

  defp parse_entry!(entry, name) do
    with [site, key] <- String.split(entry, "=", parts: 2),
         site = String.trim(site),
         key = String.trim(key),
         true <- Regex.match?(@site_regex, site),
         true <- Regex.match?(@key_regex, key) do
      {site, key}
    else
      _invalid ->
        raise ArgumentError,
              "#{name} entries must look like site=key, with a key of at least 32 letters, digits, - or _"
    end
  end
end
