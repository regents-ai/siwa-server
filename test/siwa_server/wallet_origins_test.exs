defmodule SiwaServer.WalletOriginsTest do
  use ExUnit.Case, async: true

  alias SiwaServer.WalletOrigins

  test "empty configuration disables every wallet audience" do
    assert WalletOrigins.parse!(nil) == %{}
    assert WalletOrigins.parse!("") == %{}
  end

  test "parses several audiences, keeps each audience's origins in order and trims trailing slashes" do
    assert WalletOrigins.parse!(
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
      assert_raise ArgumentError, fn -> WalletOrigins.parse!(bad) end
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
      assert_raise ArgumentError, fn -> WalletOrigins.parse!(bad) end
    end

    label = String.duplicate("a", 63)

    assert WalletOrigins.parse!(
             "a=https://xn--bcher-kva.example,b=https://123.example,c=https://localhost,d=https://#{label}.example"
           ) == %{
             "a" => ["https://xn--bcher-kva.example"],
             "b" => ["https://123.example"],
             "c" => ["https://localhost"],
             "d" => ["https://#{label}.example"]
           }
  end
end
