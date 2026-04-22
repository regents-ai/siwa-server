defmodule SiwaServer.Siwa.ReplayRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "siwa_request_replays" do
    field :replay_key, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:replay_key, :expires_at])
    |> validate_required([:replay_key, :expires_at])
    |> unique_constraint(:replay_key, name: :siwa_request_replays_replay_key_index)
  end
end
