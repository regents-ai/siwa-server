defmodule SiwaServer.ActivityReaders do
  @moduledoc """
  Parses `SIWA_ACTIVITY_READERS`, the sites allowed to read wallet activity and
  each site's own read key, in the `SiwaServer.SiteKeys` shape. At least one
  site is listed, so every read names exactly one site.
  """

  alias SiwaServer.SiteKeys

  @spec parse!(String.t()) :: %{String.t() => String.t()}
  def parse!(value) when is_binary(value) do
    case SiteKeys.parse!(value, "SIWA_ACTIVITY_READERS") do
      readers when readers == %{} ->
        raise ArgumentError, "SIWA_ACTIVITY_READERS must name at least one site"

      readers ->
        readers
    end
  end

  @doc "The site whose key the Authorization header presents, compared in constant time."
  @spec reader(%{String.t() => String.t()}, String.t()) :: {:ok, String.t()} | :error
  defdelegate reader(readers, authorization), to: SiteKeys, as: :site
end
