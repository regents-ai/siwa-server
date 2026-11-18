defmodule SiwaDemoWeb.SiteFileTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint SiwaDemoWeb.Endpoint

  setup do
    on_exit(fn -> Application.put_env(:siwa_demo, :site_token, nil) end)
  end

  test "serves the address-proof token as the whole body" do
    Application.put_env(:siwa_demo, :site_token, "siwa-site-token-example")

    conn = get(build_conn(), "/.well-known/siwa-site.txt")

    assert conn.status == 200
    assert conn.resp_body == "siwa-site-token-example"
  end

  test "is not found when no token is set" do
    assert get(build_conn(), "/.well-known/siwa-site.txt").status == 404
  end
end
