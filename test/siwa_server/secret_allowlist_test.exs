defmodule SiwaServer.SecretAllowlistTest do
  use ExUnit.Case, async: true

  # A setting is read by System.get_env or System.fetch_env, by config/runtime.exs's
  # env_value, env_integer, env_boolean and required_env, or by
  # SiwaServer.RuntimeConfig's fetch and fetch_integer, always with the name written out.
  @setting_read ~r/(?:System\.(?:get_env|fetch_env!?)|\b(?:env_value|env_integer|env_boolean|required_env)\.|(?<![.\w])fetch(?:_integer)?)\(\s*"([A-Z][A-Z0-9_]*)"/

  test "secret allowlist keeps shared SIWA secrets inside this repo boundary" do
    allowlist = File.read!("docs/secret-allowlist.yaml")

    assert allowlist =~ "  - shared_siwa_receipt_signing"
    assert allowlist =~ "  - per_site_siwa_activity_read_keys"
    assert allowlist =~ "  - product_billing_secret"
    assert allowlist =~ "  - mobile_payment_secret"
    refute allowlist =~ "STRIPE_SECRET"
    refute allowlist =~ "PRIVY_APP_SECRET"
  end

  test "every setting the server reads is in the allowlist and the environment example" do
    read =
      ["config/runtime.exs" | Path.wildcard("lib/**/*.ex")]
      |> Enum.flat_map(&Regex.scan(@setting_read, File.read!(&1), capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    allowlist = File.read!("docs/secret-allowlist.yaml")
    env_example = File.read!(".env.example")

    assert "WORLD_RPC_URL" in read

    for name <- read do
      assert allowlist =~ ~r/^  - #{name}$/m,
             "#{name} is read but not in docs/secret-allowlist.yaml"

      assert env_example =~ ~r/^(# )?export #{name}=/m,
             "#{name} is read but has no export line in .env.example"
    end
  end
end
