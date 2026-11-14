defmodule SiwaServer.ConfigTest do
  use ExUnit.Case, async: false

  alias Config.Reader
  alias SiwaServer.Config

  @regents String.duplicate("r", 32)
  @patchbay String.duplicate("p", 32)
  @env ~w(BASE_RPC_URL SIWA_RECEIPT_SECRET SIWA_NONCE_TTL_SECONDS SIWA_RECEIPT_TTL_SECONDS SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS
          ETHEREUM_RPC_URL WORLD_RPC_URL KEYSTORE_PASSWORD SIWA_ACTIVITY_READERS SIWA_WALLET_ORIGINS SIWA_RELEASE_COMMAND
          DATABASE_URL SECRET_KEY_BASE PHX_HOST PRIVY_APP_ID PRIVY_VERIFICATION_KEY)
  @pem "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----"

  setup do
    original_env = Map.new(@env, &{&1, System.get_env(&1)})
    original_siwa = Application.fetch_env!(:siwa_server, :siwa)
    original_privy = Application.fetch_env!(:siwa_server, :privy)

    on_exit(fn ->
      for {name, value} <- original_env, do: restore_env(name, value)
      Application.put_env(:siwa_server, :siwa, original_siwa)
      Application.put_env(:siwa_server, :privy, original_privy)
    end)

    :ok
  end

  test "base rpc url is absent when BASE_RPC_URL is unset" do
    System.delete_env("BASE_RPC_URL")

    assert Config.base_rpc_url() == nil
  end

  test "base rpc url is trimmed from BASE_RPC_URL" do
    System.put_env("BASE_RPC_URL", " https://base.example/rpc ")

    assert Config.base_rpc_url() == "https://base.example/rpc"
  end

  test "the receipt secret is trimmed when the server starts" do
    System.put_env("SIWA_RECEIPT_SECRET", " receipt-secret ")

    assert started_siwa()[:receipt_secret] == "receipt-secret"
  end

  test "the receipt secret is not configured until one is set" do
    Application.put_env(
      :siwa_server,
      :siwa,
      Keyword.put(Application.fetch_env!(:siwa_server, :siwa), :receipt_secret, nil)
    )

    assert Config.receipt_secret() ==
             {:error, {500, "siwa_not_configured", "SIWA receipt secret is not configured"}}
  end

  test "TTLs and the signature tolerance come from the environment when the server starts" do
    System.put_env("SIWA_NONCE_TTL_SECONDS", "120")
    System.put_env("SIWA_RECEIPT_TTL_SECONDS", "900")
    System.put_env("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", "120")

    assert Keyword.take(started_siwa(), [
             :nonce_ttl_seconds,
             :receipt_ttl_seconds,
             :http_signature_tolerance_seconds
           ]) == [
             nonce_ttl_seconds: 120,
             receipt_ttl_seconds: 900,
             http_signature_tolerance_seconds: 120
           ]
  end

  test "the server does not start with a TTL or tolerance that is not a positive integer" do
    for {name, bad} <- [
          {"SIWA_NONCE_TTL_SECONDS", "0"},
          {"SIWA_RECEIPT_TTL_SECONDS", "-1"},
          {"SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", "0"}
        ] do
      System.put_env(name, bad)

      assert_raise RuntimeError, "environment variable #{name} must be a positive integer.", fn ->
        started_siwa()
      end

      System.delete_env(name)
    end
  end

  test "the server does not start with a tolerance below the contract's signing lifetime" do
    System.put_env("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", "119")

    assert_raise ArgumentError,
                 "SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS must be at least 120, the contract's signing lifetime",
                 fn -> started_siwa() end
  end

  test "activity readers: each site's own key" do
    assert Config.activity_readers!(" regents=#{@regents} , patchbay=#{@patchbay}") ==
             %{"regents" => @regents, "patchbay" => @patchbay}
  end

  test "activity readers: every site has its own name and its own key of at least 32 characters" do
    for bad <- [
          "",
          "regents",
          "regents=short",
          "Regents=#{@regents}",
          "regents=#{@regents},regents=#{@patchbay}",
          "regents=#{@regents},patchbay=#{@regents}"
        ] do
      assert_raise ArgumentError, fn -> Config.activity_readers!(bad) end
    end
  end

  test "names the site whose activity read key is presented" do
    key = Application.fetch_env!(:siwa_server, :siwa)[:activity_readers]["patchbay"]

    assert Config.activity_reader("Bearer " <> key) == {:ok, "patchbay"}
    assert Config.activity_reader(key) == :error
  end

  test "the control API's Privy settings come from the environment, trimmed" do
    System.put_env("PRIVY_APP_ID", " privy-app ")
    System.put_env("PRIVY_VERIFICATION_KEY", @pem <> "\n")
    Application.put_env(:siwa_server, :privy, started(:test)[:privy])

    assert Config.privy() == {:ok, [app_id: "privy-app", verification_key: @pem]}
  end

  test "production starts without the Privy settings, and the control API is then off" do
    for name <- ~w(PRIVY_APP_ID PRIVY_VERIFICATION_KEY SIWA_WALLET_ORIGINS SIWA_RELEASE_COMMAND),
        do: System.delete_env(name)

    for {name, value} <- [
          {"SIWA_RECEIPT_SECRET", "receipt-secret"},
          {"KEYSTORE_PASSWORD", "keystore-password"},
          {"SIWA_ACTIVITY_READERS", "regents=#{@regents}"},
          {"BASE_RPC_URL", "https://base.example/rpc"},
          {"ETHEREUM_RPC_URL", "https://ethereum.example/rpc"},
          {"WORLD_RPC_URL", "https://world.example/rpc"},
          {"DATABASE_URL",
           "postgres://siwa_server:secret@pgbouncer.cluster.flympg.net/siwa_server"},
          {"SECRET_KEY_BASE", String.duplicate("s", 64)},
          {"PHX_HOST", "siwa.example"}
        ],
        do: System.put_env(name, value)

    Application.put_env(:siwa_server, :privy, started(:prod)[:privy])

    assert Config.privy() == :error

    System.put_env("PRIVY_APP_ID", "privy-app")
    Application.put_env(:siwa_server, :privy, started(:prod)[:privy])

    assert Config.privy() == :error
  end

  defp started_siwa, do: Keyword.fetch!(started(:test), :siwa)

  defp started(env) do
    "config/runtime.exs"
    |> Reader.read!(env: env)
    |> Keyword.fetch!(:siwa_server)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
