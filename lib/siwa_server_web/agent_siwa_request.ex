defmodule SiwaServerWeb.AgentSiwaRequest do
  @moduledoc false

  import Ecto.Changeset

  alias SiwaServerWeb.AgentSiwaRequest.{HttpVerify, Registered, RegisterStep}

  @type error :: {:error, {400, String.t(), String.t()}}

  @spec cast_http_verify(map()) :: {:ok, HttpVerify.t()} | error()
  def cast_http_verify(params), do: cast(params, HttpVerify)

  @spec cast_register_step(map()) :: {:ok, RegisterStep.t()} | error()
  def cast_register_step(params), do: cast(params, RegisterStep)

  @spec cast_registered(map()) :: {:ok, Registered.t()} | error()
  def cast_registered(params), do: cast(params, Registered)

  @spec to_params(HttpVerify.t()) :: %{String.t() => term()}
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

  def validate_address(changeset, field),
    do: validate_format(changeset, field, ~r/^0x[0-9a-fA-F]{40}$/)

  # The agent's public registry profile: the text is shown as given, so it is
  # only bounded; an image is a link anyone can open.
  def validate_profile(changeset) do
    changeset
    |> validate_required([:name, :description])
    |> validate_nonblank([:name, :description, :image])
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 1_000)
    |> validate_length(:image, max: 500)
    |> validate_format(:image, ~r{\Ahttps://\S+\z})
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
