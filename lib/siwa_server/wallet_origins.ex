defmodule SiwaServer.WalletOrigins do
  @moduledoc """
  Parses `SIWA_WALLET_ORIGINS`, the approved audience-to-origin table for
  wallet sign-in.

  The value is a comma-separated list of `audience=origin` entries, for example
  `patchbay=https://patchbay.help,keyfleet=https://keyfleet.example`. An audience
  may list several origins, one entry each; its first entry is the origin the
  sign-in challenge names. No origin appears twice, so every origin belongs to
  exactly one audience. Each origin is written in its one spelling: `https://`
  and a lowercase host, with no port, trailing dot, credentials, path, query or
  fragment (one trailing slash is dropped). An empty or missing value
  disables wallet sign-in for every audience. Callers never supply origins; only
  this table does.
  """

  @audience_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @origin_regex ~r/\Ahttps:\/\/[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\z/

  @spec parse!(String.t() | nil) :: %{String.t() => [String.t(), ...]}
  def parse!(value) when value in [nil, ""], do: %{}

  def parse!(value) when is_binary(value) do
    entries =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_entry!/1)

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

  defp parse_entry!(entry) do
    case String.split(entry, "=", parts: 2) do
      [audience, origin] ->
        {validate_audience!(String.trim(audience)), validate_origin!(String.trim(origin))}

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

  defp validate_origin!(origin) do
    origin = String.replace_suffix(origin, "/", "")

    if Regex.match?(@origin_regex, origin) do
      origin
    else
      raise ArgumentError,
            "SIWA_WALLET_ORIGINS origin #{inspect(origin)} must be https:// and a lowercase host, with nothing else"
    end
  end
end
