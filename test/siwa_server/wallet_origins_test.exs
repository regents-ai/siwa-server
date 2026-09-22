defmodule SiwaServer.WalletOriginsTest do
  use ExUnit.Case, async: true

  alias SiwaServer.WalletOrigins

  test "empty configuration disables every wallet audience" do
    assert WalletOrigins.parse!(nil) == %{}
    assert WalletOrigins.parse!("") == %{}
  end

  test "parses several audiences and trims trailing slashes" do
    assert WalletOrigins.parse!(
             " patchbay=https://patchbay.help/ , keyfleet=https://keyfleet.example"
           ) ==
             %{"patchbay" => "https://patchbay.help", "keyfleet" => "https://keyfleet.example"}
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
          "patchbay=https://patchbay.help,patchbay=https://other.example"
        ] do
      assert_raise ArgumentError, fn -> WalletOrigins.parse!(bad) end
    end
  end
end
