defmodule SiwaServer.Customers.SiteCredential do
  @moduledoc """
  A site's server key. The key is shown once, when it is made, and only its
  SHA-256 is kept: the key carries 32 random bytes, so a plain hash is enough
  to find it by and never gives it back. `prefix` is the start of the key,
  enough to tell a person's keys apart and too little to use.

  A key looks like `siwa_sk_test_<random>` for a sandbox site and
  `siwa_sk_live_<random>` for a production one, the random part being 32 bytes
  in URL-safe base64.
  """

  use Ecto.Schema

  alias SiwaServer.Customers.Site

  @type t :: %__MODULE__{}

  # "siwa_sk_test_" or "siwa_sk_live_" and the first six random characters.
  @prefix_length 19

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "site_credentials" do
    belongs_to :site, Site
    field :key_hash, :binary, redact: true
    field :prefix, :string
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "A new key for `site`, and the record that keeps its hash."
  @spec new(Site.t()) :: {String.t(), t()}
  def new(site) do
    key =
      "siwa_sk_#{label(site.environment)}_" <>
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {key,
     %__MODULE__{
       site_id: site.id,
       key_hash: hash(key),
       prefix: binary_part(key, 0, @prefix_length)
     }}
  end

  @doc "The SHA-256 a key is kept and found by."
  @spec hash(String.t()) :: binary()
  def hash(key), do: :crypto.hash(:sha256, key)

  defp label(:sandbox), do: "test"
  defp label(:production), do: "live"
end
