defmodule SiwaServerWeb.ErrorJSONTest do
  use SiwaServerWeb.ConnCase, async: true

  test "renders 404" do
    assert SiwaServerWeb.ErrorJSON.render("404.json", %{}) == %{
             "ok" => false,
             "error" => %{"code" => "not_found", "message" => "Not Found"}
           }
  end

  test "renders 500" do
    assert SiwaServerWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               "ok" => false,
               "error" => %{
                 "code" => "internal_server_error",
                 "message" => "Internal Server Error"
               }
             }
  end
end
