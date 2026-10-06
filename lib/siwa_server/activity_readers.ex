defmodule SiwaServer.ActivityReaders do
  @moduledoc """
  Parses `SIWA_ACTIVITY_READERS`, the sites allowed to read wallet activity and
  each site's own read key.

  The value is a comma-separated list of `site=key` entries, for example
  `regents=<key>,patchbay=<key>`. Each key is at least 32 characters, and no two
  sites share a name or a key, so every read names exactly one site. Replacing
  one site's key leaves the others untouched.
  """

  @site_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @key_regex ~r/^[A-Za-z0-9_-]{32,}$/

  @spec parse!(String.t()) :: %{String.t() => String.t()}
  def parse!(value) when is_binary(value) do
    readers =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(%{}, fn entry, readers ->
        {site, key} = parse_entry!(entry)

        if Map.has_key?(readers, site) do
          raise ArgumentError, "SIWA_ACTIVITY_READERS lists the site #{site} twice"
        end

        Map.put(readers, site, key)
      end)

    cond do
      readers == %{} ->
        raise ArgumentError, "SIWA_ACTIVITY_READERS must name at least one site"

      readers |> Map.values() |> Enum.uniq() |> length() != map_size(readers) ->
        raise ArgumentError, "SIWA_ACTIVITY_READERS gives two sites the same key"

      true ->
        readers
    end
  end

  @doc "The site whose key the Authorization header presents, compared in constant time."
  @spec reader(%{String.t() => String.t()}, String.t()) :: {:ok, String.t()} | :error
  def reader(readers, authorization) do
    Enum.find_value(readers, :error, fn {site, key} ->
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
              "SIWA_ACTIVITY_READERS entries must look like site=key, with a key of at least 32 letters, digits, - or _"
    end
  end
end
