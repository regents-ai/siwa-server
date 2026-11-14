defmodule SiwaServer.Audiences do
  @moduledoc """
  The audiences agents may sign in for, and the origins each one signs in
  from: every audience `SIWA_WALLET_ORIGINS` names
  (`SiwaServer.Config.wallet_origins/0`), then each customer's site that is not
  archived and is usable (`usable?/1`). A configured audience is answered from
  the configuration alone, so the Regent sites never wait on the database.

  Wallet sign-in and hosted signing ask here. The public audience list and the
  help text name only the configured sites: customers' sites are no public
  directory.
  """

  import Ecto.Query

  alias SiwaServer.{Config, Repo}
  alias SiwaServer.Customers.Site

  @doc """
  The origins agents sign in for `audience` from, the first one named in the
  sign-in challenge; empty when agents may not sign in for it.
  """
  @spec origins(String.t()) :: [String.t()]
  def origins(audience) do
    case Config.wallet_origins() do
      %{^audience => origins} -> origins
      _not_configured -> site_origins(audience)
    end
  end

  @doc "The hosts `audience` is served at: the authority of each of its origins."
  @spec authorities(String.t()) :: [String.t()]
  def authorities(audience), do: audience |> origins() |> Enum.map(&Siwa.Contract.authority/1)

  @doc """
  Whether agents may sign in for a customer's site: one that is not archived,
  and is a sandbox site or a production site whose origins are proven.
  """
  @spec usable?(Site.t()) :: boolean()
  def usable?(%Site{archived_at: nil, environment: :sandbox}), do: true

  def usable?(%Site{archived_at: nil, environment: :production, origin_proof: :verified}),
    do: true

  def usable?(%Site{}), do: false

  # The same rule as `usable?/1`, asked of the database.
  defp site_origins(audience) do
    Repo.one(
      from s in Site,
        where:
          s.audience == ^audience and is_nil(s.archived_at) and
            (s.environment == :sandbox or s.origin_proof == :verified),
        select: s.origins
    ) || []
  end
end
