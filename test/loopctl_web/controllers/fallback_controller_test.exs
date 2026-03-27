defmodule LoopctlWeb.FallbackControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias LoopctlWeb.FallbackController

  defp call_fallback(conn, error) do
    conn
    |> Plug.Conn.put_private(:phoenix_format, "json")
    |> FallbackController.call(error)
  end

  describe "error atom handling" do
    test "renders 404 for :not_found", %{conn: conn} do
      conn = call_fallback(conn, {:error, :not_found})

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 404
      assert body["error"]["message"] == "Not found"
    end

    test "renders 401 for :unauthorized", %{conn: conn} do
      conn = call_fallback(conn, {:error, :unauthorized})

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 401
      assert body["error"]["message"] == "Unauthorized"
    end

    test "renders 403 for :forbidden", %{conn: conn} do
      conn = call_fallback(conn, {:error, :forbidden})

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 403
      assert body["error"]["message"] == "Forbidden"
    end

    test "renders 409 for :conflict", %{conn: conn} do
      conn = call_fallback(conn, {:error, :conflict})

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 409
      assert body["error"]["message"] == "Conflict"
    end

    test "renders 429 for :rate_limited", %{conn: conn} do
      conn = call_fallback(conn, {:error, :rate_limited})

      assert conn.status == 429
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 429
      assert body["error"]["message"] == "Too many requests"
    end
  end

  describe "changeset error handling" do
    test "renders 422 with changeset errors", %{conn: conn} do
      changeset =
        {%{}, %{name: :string, email: :string}}
        |> Ecto.Changeset.cast(%{}, [:name, :email])
        |> Ecto.Changeset.validate_required([:name, :email])

      conn = call_fallback(conn, {:error, changeset})

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] == "Validation failed"
      assert "can't be blank" in body["error"]["details"]["name"]
      assert "can't be blank" in body["error"]["details"]["email"]
    end
  end

  describe "custom message handling" do
    test "renders 422 with custom message for 3-tuple", %{conn: conn} do
      conn =
        call_fallback(
          conn,
          {:error, :unprocessable_entity, "Cycle detected in dependency graph"}
        )

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] == "Cycle detected in dependency graph"
    end
  end

  describe "ErrorJSON" do
    test "renders 500 without leaking internal details" do
      body = LoopctlWeb.ErrorJSON.render("500.json", %{})
      assert body == %{error: %{status: 500, message: "Internal server error"}}
    end

    test "renders 404 with consistent format" do
      body = LoopctlWeb.ErrorJSON.render("404.json", %{})
      assert body == %{error: %{status: 404, message: "Not found"}}
    end
  end

  describe "Ecto.CastError handling" do
    test "Ecto.CastError maps to 404 via Plug.Exception" do
      exception = %Ecto.CastError{message: "invalid UUID"}
      assert Plug.Exception.status(exception) == 404
    end

    test "Ecto.Query.CastError maps to 404 via Plug.Exception" do
      exception = %Ecto.Query.CastError{message: "invalid UUID"}
      assert Plug.Exception.status(exception) == 404
    end
  end
end
