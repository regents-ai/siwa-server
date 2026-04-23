defmodule SiwaServer.Siwa.Error do
  @moduledoc false

  @enforce_keys [:status, :code, :message]
  defstruct [:status, :code, :message]

  @type t :: %__MODULE__{status: pos_integer(), code: String.t(), message: String.t()}

  @spec new(pos_integer(), String.t(), String.t()) :: t()
  def new(status, code, message)
      when is_integer(status) and is_binary(code) and is_binary(message) do
    %__MODULE__{status: status, code: code, message: message}
  end

  @spec bad_request(String.t(), String.t()) :: t()
  def bad_request(code, message), do: new(400, code, message)

  @spec unauthorized(String.t(), String.t()) :: t()
  def unauthorized(code, message), do: new(401, code, message)

  @spec not_found(String.t(), String.t()) :: t()
  def not_found(code, message), do: new(404, code, message)

  @spec conflict(String.t(), String.t()) :: t()
  def conflict(code, message), do: new(409, code, message)

  @spec upstream(String.t(), String.t()) :: t()
  def upstream(code, message), do: new(502, code, message)

  @spec internal(String.t(), String.t()) :: t()
  def internal(code, message), do: new(500, code, message)

  @spec tuple(t()) :: {pos_integer(), String.t(), String.t()}
  def tuple(%__MODULE__{status: status, code: code, message: message}) do
    {status, code, message}
  end

  @spec error(t()) :: {:error, {pos_integer(), String.t(), String.t()}}
  def error(%__MODULE__{} = error), do: {:error, tuple(error)}
end
