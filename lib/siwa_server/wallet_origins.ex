defmodule SiwaServer.WalletOrigins do
  @moduledoc """
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

  @audience_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  # Labels of at most 63 characters; the last starts with a letter, so no host is a number.
  @origin_regex ~r/\Ahttps:\/\/(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  @local_origin_regex ~r/\Ahttp:\/\/localhost:[1-9][0-9]{0,4}\z/

  @spec parse!(String.t() | nil, keyword()) :: %{String.t() => [String.t(), ...]}
  def parse!(value, opts \\ [])
  def parse!(value, _opts) when value in [nil, ""], do: %{}

  def parse!(value, opts) when is_binary(value) do
    local = Keyword.get(opts, :local, false)

    entries =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_entry!(&1, local))

    case entries |> Enum.map(&elem(&1, 1)) |> duplicate() do
      nil -> :ok
      origin -> raise ArgumentError, "SIWA_WALLET_ORIGINS lists the origin #{origin} twice"
    end

    entries
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp duplicate(origins) do
    origins
    |> Enum.frequencies()
    |> Enum.find_value(fn {origin, count} -> if count > 1, do: origin end)
  end

  defp parse_entry!(entry, local) do
    case String.split(entry, "=", parts: 2) do
      [audience, origin] ->
        {validate_audience!(String.trim(audience)), validate_origin!(String.trim(origin), local)}

      _ ->
        raise ArgumentError,
              "SIWA_WALLET_ORIGINS entries must look like audience=https://origin, got #{inspect(entry)}"
    end
  end

  defp validate_audience!(audience) do
    if Regex.match?(@audience_regex, audience) do
      audience
    else
      raise ArgumentError, "SIWA_WALLET_ORIGINS audience #{inspect(audience)} is not a valid name"
    end
  end

  defp validate_origin!(origin, local) do
    origin = String.replace_suffix(origin, "/", "")

    if Regex.match?(@origin_regex, origin) or
         (local and Regex.match?(@local_origin_regex, origin)) do
      origin
    else
      raise ArgumentError,
            "SIWA_WALLET_ORIGINS origin #{inspect(origin)} must be https:// and a lowercase host, with nothing else"
    end
  end
end
