defmodule SiwaServerWeb.AgentSiwaRequest.Link do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServer.WalletChallenge
  alias SiwaServerWeb.AgentSiwaRequest

  @fields [:wallet_address, :chain_id, :token_id, :nonce, :message, :signature]

  @primary_key false
  embedded_schema do
    field :wallet_address, :string
    field :chain_id, :integer
    field :token_id, :string
    field :nonce, :string
    field :message, :string
    field :signature, :string
  end

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          chain_id: pos_integer(),
          token_id: String.t(),
          nonce: String.t(),
          message: String.t(),
          signature: String.t()
        }

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, @fields, empty_values: [])
    |> validate_required(@fields)
    |> AgentSiwaRequest.validate_link()
    |> validate_proof()
  end

  defp validate_proof(changeset) do
    if changeset.valid? and
         not WalletChallenge.proof?(
           get_field(changeset, :nonce),
           get_field(changeset, :message),
           get_field(changeset, :signature)
         ),
       do: add_error(changeset, :signature, "is not a signed challenge"),
       else: changeset
  end
end
