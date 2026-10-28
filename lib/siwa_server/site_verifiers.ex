defmodule SiwaServer.SiteVerifiers do
  @moduledoc """
  Parses `SIWA_SITE_VERIFY_KEYS`, the sites allowed to ask this server to verify
  an agent's signed request and each site's own key for it, in the
  `SiwaServer.SiteKeys` shape.

  The site name is the one audience that key verifies for: a request checked
  with it must carry a sign-in made for that site, and the key cannot name any
  other. In production every wallet sign-in audience has exactly one verify key
  and no key names an audience wallet sign-in does not know, and a verify key is
  never also an activity-read or hosted-signing key.
  """

  alias SiwaServer.SiteKeys

  @spec parse!(String.t()) :: %{String.t() => String.t()}
  def parse!(value) when is_binary(value) do
    case SiteKeys.parse!(value, "SIWA_SITE_VERIFY_KEYS") do
      verifiers when verifiers == %{} ->
        raise ArgumentError, "SIWA_SITE_VERIFY_KEYS must name at least one site"

      verifiers ->
        verifiers
    end
  end

  @doc """
  Raises unless the verify keys name exactly the audiences in
  `SIWA_WALLET_ORIGINS`, so no site is left without a key and no key names a
  site that cannot sign in.
  """
  @spec ensure_every_audience!(%{String.t() => String.t()}, %{String.t() => [String.t()]}) :: :ok
  def ensure_every_audience!(verifiers, wallet_origins) do
    sites = verifiers |> Map.keys() |> MapSet.new()
    audiences = wallet_origins |> Map.keys() |> MapSet.new()

    missing = MapSet.difference(audiences, sites)
    unknown = MapSet.difference(sites, audiences)

    if MapSet.size(missing) > 0 or MapSet.size(unknown) > 0 do
      raise ArgumentError,
            "SIWA_SITE_VERIFY_KEYS must name each SIWA_WALLET_ORIGINS audience once; " <>
              "missing #{inspect(Enum.sort(missing))}, unknown #{inspect(Enum.sort(unknown))}"
    end

    :ok
  end

  @doc """
  Raises when a verify key is also an activity-read or hosted-signing key, so
  each key keeps exactly one kind of authority.
  """
  @spec ensure_own_keys!(%{String.t() => String.t()}, [%{String.t() => String.t()}]) :: :ok
  def ensure_own_keys!(verifiers, other_keys) do
    shared =
      other_keys
      |> Enum.flat_map(&Map.values/1)
      |> MapSet.new()
      |> MapSet.intersection(verifiers |> Map.values() |> MapSet.new())

    if MapSet.size(shared) > 0 do
      raise ArgumentError,
            "SIWA_SITE_VERIFY_KEYS reuses a key from SIWA_ACTIVITY_READERS or SIWA_HOSTED_SIGNERS"
    end

    :ok
  end

  @doc "The site whose key the Authorization header presents, compared in constant time."
  @spec site(%{String.t() => String.t()}, String.t()) :: {:ok, String.t()} | :error
  defdelegate site(verifiers, authorization), to: SiteKeys
end
