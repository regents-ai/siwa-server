defmodule SiwaServer.ConfigTest do
  use ExUnit.Case, async: false

  alias Config.Reader
  alias SiwaServer.Config

  @regents String.duplicate("r", 32)
  @patchbay String.duplicate("p", 32)
  @env ~w(BASE_RPC_URL SIWA_RECEIPT_SECRET SIWA_NONCE_TTL_SECONDS SIWA_RECEIPT_TTL_SECONDS SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS)

  setup do
    original_env = Map.new(@env, &{&1, System.get_env(&1)})
    original_siwa = Application.fetch_env!(:siwa_server, :siwa)

    on_exit(fn ->
      for {name, value} <- original_env, do: restore_env(name, value)
      Application.put_env(:siwa_server, :siwa, original_siwa)
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

  defp started_siwa do
    "config/runtime.exs"
    |> Reader.read!(env: :test)
    |> Keyword.fetch!(:siwa_server)
    |> Keyword.fetch!(:siwa)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
