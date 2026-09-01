defmodule SiwaServer.DatabaseConfigTest do
  use ExUnit.Case, async: true

  alias SiwaServer.DatabaseConfig

  @pooled_url "postgres://siwa_server:secret@pgbouncer.cluster.flympg.net/siwa_server"

  test "uses verified TLS and unnamed prepares for a Fly MPG pooled runtime URL" do
    config = DatabaseConfig.runtime_config!(@pooled_url, [])

    assert config[:url] == @pooled_url
    assert config[:port] == 5432
    assert config[:prepare] == :unnamed
    assert config[:socket_options] == [:inet6]
    assert config[:ssl][:verify] == :verify_peer
    assert config[:ssl][:cacerts] != []
    assert config[:ssl][:server_name_indication] == ~c"pgbouncer.cluster.flympg.net"
    assert is_function(config[:ssl][:customize_hostname_check][:match_fun], 2)
  end

  test "derives the direct Fly MPG host for release migrations" do
    config = DatabaseConfig.release_config!(@pooled_url, [:inet6])

    assert config[:url] ==
             "postgres://siwa_server:secret@direct.cluster.flympg.net/siwa_server"

    refute Keyword.has_key?(config, :prepare)
    assert config[:ssl][:server_name_indication] == ~c"direct.cluster.flympg.net"
  end

  test "accepts an already-direct Fly MPG URL for release migrations" do
    direct_url = "postgres://siwa_server:secret@direct.cluster.flympg.net/siwa_server"

    assert DatabaseConfig.release_config!(direct_url, [])[:url] == direct_url
  end

  test "rejects a direct Fly MPG URL for normal runtime" do
    direct_url = "postgres://siwa_server:secret@direct.cluster.flympg.net/siwa_server"

    assert_raise RuntimeError, ~r/pooled endpoint/, fn ->
      DatabaseConfig.runtime_config!(direct_url, [])
    end
  end

  test "rejects Fly MPG URL query overrides and nonstandard ports" do
    for url <- [
          @pooled_url <> "?ssl=false",
          "postgres://siwa_server:secret@pgbouncer.cluster.flympg.net:6432/siwa_server"
        ] do
      assert_raise RuntimeError, ~r/valid PostgreSQL URL/, fn ->
        DatabaseConfig.runtime_config!(url, [])
      end
    end
  end

  test "canonicalizes a trailing-dot Fly MPG host before applying every safeguard" do
    trailing_url =
      "postgres://siwa_server:secret@pgbouncer.cluster.flympg.net./siwa_server"

    runtime = DatabaseConfig.runtime_config!(trailing_url, [])
    release = DatabaseConfig.release_config!(trailing_url, [])

    assert runtime[:url] == @pooled_url
    assert runtime[:prepare] == :unnamed
    assert runtime[:ssl][:verify] == :verify_peer

    assert release[:url] ==
             "postgres://siwa_server:secret@direct.cluster.flympg.net/siwa_server"

    assert_raise RuntimeError, ~r/valid PostgreSQL URL/, fn ->
      DatabaseConfig.runtime_config!(trailing_url <> "?ssl=false", [])
    end
  end

  test "rejects malformed and unsupported database URLs" do
    for url <- [
          "",
          "https://siwa_server:secret@pgbouncer.cluster.flympg.net/siwa_server",
          "postgres://pgbouncer.cluster.flympg.net/siwa_server",
          "postgres://siwa_server:secret@flympg.net/siwa_server"
        ] do
      assert_raise RuntimeError, ~r/DATABASE_URL/, fn ->
        DatabaseConfig.runtime_config!(url, [])
      end
    end
  end

  test "preserves the existing behavior for a non-Fly PostgreSQL URL" do
    url = "postgres://postgres:postgres@database.internal/siwa_server"

    assert DatabaseConfig.runtime_config!(url, []) == [url: url, socket_options: []]
    assert DatabaseConfig.release_config!(url, [:inet6]) == [url: url, socket_options: [:inet6]]
  end

  test "preserves a passwordless non-Fly PostgreSQL URL" do
    url = "postgres://postgres@database.internal/siwa_server"

    assert DatabaseConfig.runtime_config!(url, []) == [url: url, socket_options: []]
    assert DatabaseConfig.release_config!(url, [:inet6]) == [url: url, socket_options: [:inet6]]
  end
end
