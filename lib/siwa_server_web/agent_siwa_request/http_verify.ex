defmodule SiwaServerWeb.AgentSiwaRequest.HttpVerify do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SiwaServerWeb.AgentSiwaRequest

  @fields [:method, :path, :headers, :body]
  @required @fields -- [:body]

  @primary_key false
  embedded_schema do
    field :method, :string
    field :path, :string
    field :headers, :map
    field :body, :string
  end

  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t(),
          headers: %{String.t() => String.t()},
          body: String.t() | nil
        }

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, @fields, empty_values: [])
    |> validate_required(@required)
    |> validate_headers()
    |> AgentSiwaRequest.validate_nonblank([:method, :path])
  end

  defp validate_headers(changeset) do
    validate_change(changeset, :headers, fn :headers, headers ->
      if string_map?(headers),
        do: [],
        else: [headers: "must be an object of string headers"]
    end)
  end

  defp string_map?(headers) do
    is_map(headers) and
      Enum.all?(headers, fn {name, value} -> is_binary(name) and is_binary(value) end)
  end
end
