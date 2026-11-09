defmodule SiwaServer.WalletOriginsTest do
  use ExUnit.Case, async: true

  alias SiwaServer.Config

  test "empty configuration disables every wallet audience" do
    assert Config.wallet_origins!(nil) == %{}
    assert Config.wallet_origins!("") == %{}
  end

  test "parses several audiences, keeps each audience's origins in order and trims trailing slashes" do
    assert Config.wallet_origins!(
             " patchbay=https://patchbay.help/ , keyfleet=https://keyfleet.example," <>
               "keyfleet=https://club.notebooks.keyfleet.example"
           ) ==
             %{
               "patchbay" => ["https://patchbay.help"],
               "keyfleet" => [
                 "https://keyfleet.example",
                 "https://club.notebooks.keyfleet.example"
               ]
             }
  end

  test "rejects malformed entries, bad audiences, non-origin URLs and duplicates" do
    for bad <- [
          "patchbay",
          "Patchbay=https://patchbay.help",
          "patchbay=http://patchbay.help",
          "patchbay=https://patchbay.help/start",
          "patchbay=https://patchbay.help:8443",
          "patchbay=https://user:pw@patchbay.help",
          "patchbay=https://patchbay.help?x=1",
          "patchbay=https://patchbay.help,patchbay=https://patchbay.help/",
          "patchbay=https://patchbay.help,keyfleet=https://patchbay.help"
        ] do
      assert_raise ArgumentError, fn -> Config.wallet_origins!(bad) end
    end
  end

  test "a server run for local work also accepts a localhost origin with a port" do
    local = "keyfleet=https://keyfleet.ai,keyfleet=http://localhost:4000"

    assert Config.wallet_origins!(local, local: true) == %{
             "keyfleet" => ["https://keyfleet.ai", "http://localhost:4000"]
           }

    assert_raise ArgumentError, fn -> Config.wallet_origins!(local) end

    for bad <- [
          "site=http://localhost",
          "site=http://127.0.0.1:4000",
          "site=http://keyfleet.ai:4000"
        ] do
      assert_raise ArgumentError, fn -> Config.wallet_origins!(bad, local: true) end
    end
  end

  # R-20261018-numeric-origin: a browser writes https://2130706433, https://0x7f.0.0.1 and
  # https://127.1 all as https://127.0.0.1, so a numeric host could be listed under two
  # audiences. An origin is a site's name; its last label starts with a letter.
  test "rejects numeric hosts and labels over 63 characters, and keeps names that end in a word" do
    for bad <- [
          "site=https://127.0.0.1",
          "site=https://127.0.0.1,other=https://2130706433",
          "site=https://0x7f.0.0.1",
          "site=https://127.1",
          "site=https://a.123",
          "site=https://" <> String.duplicate("a", 64) <> ".example"
        ] do
      assert_raise ArgumentError, fn -> Config.wallet_origins!(bad) end
    end

    label = String.duplicate("a", 63)

    assert Config.wallet_origins!(
             "a=https://xn--bcher-kva.example,b=https://123.example,c=https://localhost,d=https://#{label}.example"
           ) == %{
             "a" => ["https://xn--bcher-kva.example"],
             "b" => ["https://123.example"],
             "c" => ["https://localhost"],
             "d" => ["https://#{label}.example"]
           }
  end
end
