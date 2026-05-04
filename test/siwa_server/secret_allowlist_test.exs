defmodule SiwaServer.SecretAllowlistTest do
  use ExUnit.Case, async: true

  test "secret allowlist keeps shared SIWA secrets inside this repo boundary" do
    allowlist = File.read!("docs/secret-allowlist.yaml")

    for name <- ~w(
      DATABASE_URL
      SECRET_KEY_BASE
      SIWA_RECEIPT_SECRET
      KEYSTORE_PASSWORD
      KEYRING_PROXY_SECRET
      BASE_RPC_URL
    ) do
      assert allowlist =~ "  - #{name}"
    end

    assert allowlist =~ "  - shared_siwa_receipt_signing"
    assert allowlist =~ "  - shared_keyring_proxy_hmac"
    assert allowlist =~ "  - product_billing_secret"
    assert allowlist =~ "  - mobile_payment_secret"
    refute allowlist =~ "STRIPE_SECRET"
    refute allowlist =~ "PRIVY_APP_SECRET"
  end

  test "local environment example lists runtime environment knobs" do
    env_example = File.read!(".env.example")

    for name <- ~w(
      BASE_RPC_URL
      DNS_CLUSTER_QUERY
      PHX_SERVER
      POOL_SIZE
      SIWA_CLEANUP_BATCH_SIZE
    ) do
      assert env_example =~ "export #{name}="
    end
  end
end
