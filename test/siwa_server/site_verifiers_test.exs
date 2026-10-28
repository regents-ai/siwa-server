defmodule SiwaServer.SiteVerifiersTest do
  use ExUnit.Case, async: true

  alias SiwaServer.SiteVerifiers

  @patchbay String.duplicate("p", 32)
  @techtree String.duplicate("t", 32)

  test "parses each site's own key" do
    assert SiteVerifiers.parse!(" patchbay=#{@patchbay} , techtree=#{@techtree}") ==
             %{"patchbay" => @patchbay, "techtree" => @techtree}
  end

  test "every site has its own name and its own key of at least 32 characters" do
    for bad <- [
          "",
          "patchbay",
          "patchbay=short",
          "Patchbay=#{@patchbay}",
          "patchbay=#{@patchbay},patchbay=#{@techtree}",
          "patchbay=#{@patchbay},techtree=#{@patchbay}"
        ] do
      assert_raise ArgumentError, fn -> SiteVerifiers.parse!(bad) end
    end
  end

  test "a verify key is never also an activity-read or hosted-signing key" do
    verifiers = %{"patchbay" => @patchbay}

    assert SiteVerifiers.ensure_own_keys!(verifiers, [%{"regents" => @techtree}, %{}]) == :ok

    assert_raise ArgumentError, fn ->
      SiteVerifiers.ensure_own_keys!(verifiers, [%{}, %{"keyfleet" => @patchbay}])
    end
  end

  test "in production every sign-in audience has one verify key, and no key names another" do
    origins = %{"patchbay" => ["https://patchbay.help"], "techtree" => ["https://techtree.sh"]}

    assert SiteVerifiers.ensure_every_audience!(
             %{"patchbay" => @patchbay, "techtree" => @techtree},
             origins
           ) == :ok

    for verifiers <- [
          %{"patchbay" => @patchbay},
          %{
            "patchbay" => @patchbay,
            "techtree" => @techtree,
            "patchbey" => String.duplicate("q", 32)
          }
        ] do
      assert_raise ArgumentError, fn ->
        SiteVerifiers.ensure_every_audience!(verifiers, origins)
      end
    end
  end

  test "names the one site whose key is presented" do
    verifiers = %{"patchbay" => @patchbay, "techtree" => @techtree}

    assert SiteVerifiers.site(verifiers, "Bearer " <> @techtree) == {:ok, "techtree"}
    assert SiteVerifiers.site(verifiers, @techtree) == :error
    assert SiteVerifiers.site(verifiers, "Bearer " <> @techtree <> "x") == :error
  end
end
