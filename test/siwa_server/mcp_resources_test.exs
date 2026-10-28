defmodule SiwaServer.McpResourcesTest do
  use ExUnit.Case, async: true

  alias SiwaServer.McpResources

  @origins %{
    "patchbay" => ["https://patchbay.help"],
    "keyfleet" => ["https://keyfleet.ai", "https://code.keyfleet.ai"],
    "regents-mobile" => ["https://regents-mobile-server.fly.dev"]
  }

  test "maps each exact MCP address to its audience" do
    assert McpResources.parse!(
             " patchbay=https://patchbay.help/mcp , keyfleet=https://code.keyfleet.ai/mcp",
             @origins
           ) == %{
             "https://patchbay.help/mcp" => "patchbay",
             "https://code.keyfleet.ai/mcp" => "keyfleet"
           }

    assert McpResources.parse!(nil, @origins) == %{}
    assert McpResources.parse!("", @origins) == %{}
  end

  test "an address is one of its own audience's origins and a path, listed once" do
    for bad <- [
          "patchbay",
          "patchbay=https://patchbay.help",
          "patchbay=https://patchbay.help/",
          "patchbay=http://patchbay.help/mcp",
          "patchbay=https://patchbay.help:443/mcp",
          "patchbay=https://Patchbay.help/mcp",
          "patchbay=https://patchbay.help/mcp?x=1",
          "patchbay=https://patchbay.help/mcp#x",
          "patchbay=https://patchbay.help/../mcp",
          "patchbay=https://patchbay.help/./mcp",
          "patchbay=https://patchbay.help/mcp/..",
          "patchbay=https://user@patchbay.help/mcp",
          "patchbay=https://keyfleet.ai/mcp",
          "techtree=https://techtree.sh/mcp",
          "keyfleet=https://keyfleet.ai/mcp,keyfleet=https://keyfleet.ai/mcp",
          "patchbay=https://patchbay.help/mcp,keyfleet=https://patchbay.help/mcp"
        ] do
      assert_raise ArgumentError, fn -> McpResources.parse!(bad, @origins) end
    end
  end
end
