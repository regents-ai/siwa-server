defmodule SiwaServer.HostedSigners do
  @moduledoc """
  Parses `SIWA_HOSTED_SIGNERS`, the sites allowed to ask for hosted signing and
  each site's own key for it, in the `SiwaServer.SiteKeys` shape.

  The site name is the audience every request it signs is bound to, and its key
  works only for hosted signing. An empty or missing value lets no site sign.
  """

  alias SiwaServer.SiteKeys

  @spec parse!(String.t() | nil) :: %{String.t() => String.t()}
  def parse!(value) when value in [nil, ""], do: %{}
  def parse!(value) when is_binary(value), do: SiteKeys.parse!(value, "SIWA_HOSTED_SIGNERS")

  @doc "The site whose key the Authorization header presents, compared in constant time."
  @spec site(%{String.t() => String.t()}, String.t()) :: {:ok, String.t()} | :error
  defdelegate site(signers, authorization), to: SiteKeys
end
