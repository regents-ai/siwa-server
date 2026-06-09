defmodule SiwaServer.Text do
  @moduledoc """
  Small text helpers shared across the SIWA server.
  """

  @doc """
  Trims a binary and returns it, or `nil` when the value is not a binary or
  is blank after trimming.
  """
  @spec normalize_optional_text(term()) :: String.t() | nil
  def normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_optional_text(_value), do: nil
end
