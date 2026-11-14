defmodule SiwaServer.Customers.Site do
  @moduledoc """
  One of a customer's sites: its name, the audience its agents sign in for and
  the origins its requests come from.

  The audience follows the site-name rule (`SiwaServer.Config.site_name?/1`),
  is unique over every site ever made, archived ones included, and is never one
  `SIWA_WALLET_ORIGINS` names: those belong to the Regent sites already served.
  A site lists 1 to 10 origins, none twice. A `sandbox` site lists only local
  origins (`SiwaServer.Config.local_origin?/1`) and needs no proof that it
  controls them; a `production` site lists only public `https://` origins
  (`SiwaServer.Config.https_origin?/1`), and its origin proof is `unverified`
  when it is made and again whenever its origins change. The audience and the
  environment never change. An archived site is kept and hidden.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServer.Config
  alias SiwaServer.Customers.Customer

  @type t :: %__MODULE__{}

  # The audiences this service signs its own challenges for (`SiwaServer.AgentBook`,
  # `SiwaServer.AgentRegistration`); no site may take them.
  @service_audiences ~w(agent-book agent-link)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sites" do
    belongs_to :customer, Customer
    field :name, :string
    field :audience, :string
    field :environment, Ecto.Enum, values: [:sandbox, :production]
    field :origins, {:array, :string}
    field :origin_proof, Ecto.Enum, values: [:unverified, :verified]
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "A new site from its name, audience, environment and origins."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(site, params) do
    site
    |> cast(params, [:name, :audience, :environment, :origins])
    |> validate_required([:name, :audience, :environment, :origins])
    |> validate_change(:audience, &audience/2)
    |> unique_constraint(:audience)
    |> check_constraint(:environment, name: :environment_is_sandbox_or_production)
    |> validate_name_and_origins()
  end

  @doc "A new name or new origins for a site."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(site, params) do
    site
    |> cast(params, [:name, :origins])
    |> validate_required([:name, :origins])
    |> validate_name_and_origins()
  end

  defp validate_name_and_origins(changeset) do
    changeset
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: 100, count: :codepoints)
    |> validate_length(:origins, min: 1, max: 10)
    |> validate_origins()
    |> check_constraint(:name, name: :name_length)
    |> check_constraint(:origins, name: :origins_count)
    |> check_constraint(:origins, name: :origins_distinct)
    |> unverified_when_origins_change()
  end

  defp audience(:audience, audience) do
    cond do
      not Config.site_name?(audience) ->
        [
          audience:
            "must be 1 to 64 lowercase letters, digits, - or _, starting with a letter or digit"
        ]

      audience in @service_audiences or Map.has_key?(Config.wallet_origins(), audience) ->
        [audience: "has already been taken"]

      true ->
        []
    end
  end

  # An environment that did not cast has its own error, and no origin rule.
  defp validate_origins(changeset) do
    case get_field(changeset, :environment) do
      nil -> changeset
      environment -> validate_change(changeset, :origins, &origins(environment, &1, &2))
    end
  end

  defp origins(environment, :origins, origins) do
    cond do
      Enum.uniq(origins) != origins -> [origins: "lists an origin twice"]
      Enum.all?(origins, origin_rule(environment)) -> []
      true -> [origins: origin_message(environment)]
    end
  end

  defp origin_rule(:production), do: &Config.https_origin?/1
  defp origin_rule(:sandbox), do: &Config.local_origin?/1

  defp origin_message(:production),
    do: "must each be https:// and a lowercase host, with nothing else"

  defp origin_message(:sandbox), do: "must each be http://localhost and a port, with nothing else"

  defp unverified_when_origins_change(changeset) do
    if get_field(changeset, :environment) == :production and changed?(changeset, :origins),
      do: put_change(changeset, :origin_proof, :unverified),
      else: changeset
  end
end
