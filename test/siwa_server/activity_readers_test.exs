defmodule SiwaServer.ActivityReadersTest do
  use ExUnit.Case, async: true

  alias SiwaServer.ActivityReaders

  @regents String.duplicate("r", 32)
  @patchbay String.duplicate("p", 32)

  test "parses each site's own key" do
    assert ActivityReaders.parse!(" regents=#{@regents} , patchbay=#{@patchbay}") ==
             %{"regents" => @regents, "patchbay" => @patchbay}
  end

  test "every site has its own name and its own key of at least 32 characters" do
    for bad <- [
          "",
          "regents",
          "regents=short",
          "Regents=#{@regents}",
          "regents=#{@regents},regents=#{@patchbay}",
          "regents=#{@regents},patchbay=#{@regents}"
        ] do
      assert_raise ArgumentError, fn -> ActivityReaders.parse!(bad) end
    end
  end

  test "names the site whose key is presented" do
    readers = %{"regents" => @regents, "patchbay" => @patchbay}

    assert ActivityReaders.reader(readers, "Bearer " <> @patchbay) == {:ok, "patchbay"}
    assert ActivityReaders.reader(readers, @patchbay) == :error
  end
end
