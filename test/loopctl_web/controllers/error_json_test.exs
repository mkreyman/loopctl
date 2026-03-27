defmodule LoopctlWeb.ErrorJSONTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  test "renders 404" do
    assert LoopctlWeb.ErrorJSON.render("404.json", %{}) ==
             %{error: %{status: 404, message: "Not found"}}
  end

  test "renders 500" do
    assert LoopctlWeb.ErrorJSON.render("500.json", %{}) ==
             %{error: %{status: 500, message: "Internal server error"}}
  end

  test "renders arbitrary status code" do
    body = LoopctlWeb.ErrorJSON.render("503.json", %{})
    assert body.error.status == 503
    assert body.error.message == "Service Unavailable"
  end
end
