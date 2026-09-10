defmodule SiwaServerWeb.AgentSiwaRequest do
  @moduledoc false

  import Ecto.Changeset

  alias SiwaServerWeb.AgentSiwaRequest.{HttpVerify, Nonce, Verify}

  @type error :: {:error, {400, String.t(), String.t()}}

  @spec cast_nonce(map()) :: {:ok, Nonce.t()} | error()
  def cast_nonce(params), do: cast(params, Nonce)

  @spec cast_verify(map()) :: {:ok, Verify.t()} | error()
  def cast_verify(params), do: cast(params, Verify)

  @spec cast_http_verify(map()) :: {:ok, HttpVerify.t()} | error()
  def cast_http_verify(params), do: cast(params, HttpVerify)

  @spec to_params(Nonce.t() | Verify.t() | HttpVerify.t()) :: %{String.t() => term()}
  def to_params(%_{} = request) do
    request
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  # Request schemas use this to reject blank-but-present strings exactly as the
  # contract requires; `cast/3` only guarantees the field is a binary.
  def validate_nonblank(changeset, fields) do
    Enum.reduce(fields, changeset, &apply_nonblank(&2, &1))
  end

  defp apply_nonblank(changeset, field) do
    validate_change(changeset, field, fn _field, value -> nonblank_error(field, value) end)
  end

  defp nonblank_error(field, value) do
    if is_binary(value) and String.trim(value) != "",
      do: [],
      else: [{field, "can't be blank"}]
  end

  # `:integer` fields accept numeric strings through `cast/3`; the contract
  # requires a JSON integer, so check the raw params before coercion.
  def ensure_integer_param(changeset, params, field) do
    case Map.get(params, Atom.to_string(field)) do
      nil -> changeset
      value when is_integer(value) -> changeset
      _value -> add_error(changeset, field, "must be an integer")
    end
  end

  defp cast(params, module) when is_map(params) do
    allowed = module.__schema__(:fields) |> Enum.map(&Atom.to_string/1)

    with :ok <- ensure_no_extra_fields(params, allowed),
         %Ecto.Changeset{valid?: true} = changeset <- module.changeset(params) do
      {:ok, apply_changes(changeset)}
    else
      _ -> invalid_request()
    end
  end

  defp cast(_params, _module), do: invalid_request()

  defp ensure_no_extra_fields(params, allowed_fields) do
    extras = params |> Map.keys() |> Enum.reject(&(&1 in allowed_fields))

    if extras == [], do: :ok, else: invalid_request()
  end

  defp invalid_request,
    do: {:error, {400, "invalid_request", "request body does not match the SIWA contract"}}
end
