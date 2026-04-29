defmodule SiwaServer.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias SiwaServer.RuntimeConfig

  setup do
    original_base_rpc_url = System.get_env("BASE_RPC_URL")
    original_signature_tolerance = System.get_env("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS")
    original_siwa_config = Application.get_env(:siwa_server, :siwa)

    on_exit(fn ->
      if is_nil(original_base_rpc_url) do
        System.delete_env("BASE_RPC_URL")
      else
        System.put_env("BASE_RPC_URL", original_base_rpc_url)
      end

      if is_nil(original_signature_tolerance) do
        System.delete_env("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS")
      else
        System.put_env("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", original_signature_tolerance)
      end

      Application.put_env(:siwa_server, :siwa, original_siwa_config)
    end)

    :ok
  end

  test "base rpc url is absent when BASE_RPC_URL is unset" do
    System.delete_env("BASE_RPC_URL")

    assert RuntimeConfig.base_rpc_url() == nil
  end

  test "base rpc url is trimmed from BASE_RPC_URL" do
    System.put_env("BASE_RPC_URL", " https://base.example/rpc ")

    assert RuntimeConfig.base_rpc_url() == "https://base.example/rpc"
  end

  test "siwa receipt secret is trimmed from app config" do
    Application.put_env(:siwa_server, :siwa, receipt_secret: " receipt-secret ")

    assert RuntimeConfig.siwa_receipt_secret() == {:ok, "receipt-secret"}
  end

  test "siwa receipt secret fails when absent" do
    Application.put_env(:siwa_server, :siwa, receipt_secret: " ")

    assert RuntimeConfig.siwa_receipt_secret() ==
             {:error, {500, "siwa_not_configured", "SIWA receipt secret is not configured"}}
  end

  test "siwa ttl values come from app config when positive" do
    Application.put_env(:siwa_server, :siwa,
      nonce_ttl_seconds: 120,
      receipt_ttl_seconds: 900,
      receipt_secret: "receipt-secret"
    )

    assert RuntimeConfig.siwa_nonce_ttl_seconds() == 120
    assert RuntimeConfig.siwa_receipt_ttl_seconds() == 900
  end

  test "siwa ttl values fail when invalid" do
    Application.put_env(:siwa_server, :siwa,
      nonce_ttl_seconds: 0,
      receipt_ttl_seconds: -1,
      receipt_secret: "receipt-secret"
    )

    assert_raise ArgumentError, ":siwa nonce_ttl_seconds must be a positive integer", fn ->
      RuntimeConfig.siwa_nonce_ttl_seconds()
    end

    assert_raise ArgumentError, ":siwa receipt_ttl_seconds must be a positive integer", fn ->
      RuntimeConfig.siwa_receipt_ttl_seconds()
    end
  end

  test "http signature tolerance comes from env when positive" do
    System.put_env("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", "120")

    assert RuntimeConfig.siwa_http_signature_tolerance_seconds() == 120
  end

  test "http signature tolerance fails when invalid" do
    System.put_env("SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS", "0")

    assert_raise ArgumentError,
                 "SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS must be a positive integer",
                 fn ->
                   RuntimeConfig.siwa_http_signature_tolerance_seconds()
                 end
  end
end
