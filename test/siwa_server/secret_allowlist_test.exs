defmodule SiwaServer.SecretAllowlistTest do
  use ExUnit.Case, async: true

  test "secret allowlist keeps shared SIWA secrets inside this repo boundary" do
    allowlist = File.read!("docs/secret-allowlist.yaml")

    for name <- ~w(
      DATABASE_URL
      SECRET_KEY_BASE
      SIWA_RECEIPT_SECRET
      KEYSTORE_PASSWORD
      SIWA_ACTIVITY_READERS
      BASE_RPC_URL
      ETHEREUM_RPC_URL
    ) do
      assert allowlist =~ "  - #{name}"
    end

    assert allowlist =~ "  - shared_siwa_receipt_signing"
    assert allowlist =~ "  - per_site_siwa_activity_read_keys"
    assert allowlist =~ "  - product_billing_secret"
    assert allowlist =~ "  - mobile_payment_secret"
    refute allowlist =~ "STRIPE_SECRET"
    refute allowlist =~ "PRIVY_APP_SECRET"
  end

  # The settings are the names the runtime configuration reads: config/runtime.exs
  # and SiwaServer.RuntimeConfig, which reads a few at request time.
  test "every setting the server reads is in the allowlist and the environment example" do
    read =
      ["config/runtime.exs", "lib/siwa_server/runtime_config.ex"]
      |> Enum.map_join("\n", &File.read!/1)
      |> then(&Regex.scan(~r/"([A-Z][A-Z0-9_]+)"/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    allowlist = File.read!("docs/secret-allowlist.yaml")
    env_example = File.read!(".env.example")

    assert "WORLD_RPC_URL" in read

    for name <- read do
      assert allowlist =~ "  - #{name}\n", "#{name} is read but not in docs/secret-allowlist.yaml"
      assert env_example =~ ~r/\b#{name}\b/, "#{name} is read but not in .env.example"
    end
  end
end
