defmodule LoopctlWeb.Plugs.CastErrorHandlerTest do
  @moduledoc """
  The `Plug.Exception` impls map Ecto cast/change errors to clean 4xx statuses
  instead of a raw 500. Query-time cast errors -> 404; insert/update-time
  `Ecto.ChangeError` (a struct field set uncast, dumped on write) -> 400.
  """
  use ExUnit.Case, async: true

  test "Ecto.Query.CastError maps to 404" do
    exception = %Ecto.Query.CastError{type: :binary_id, value: "not-a-uuid", message: "bad"}
    assert Plug.Exception.status(exception) == 404
  end

  test "Ecto.CastError maps to 404" do
    exception = %Ecto.CastError{type: :binary_id, value: "not-a-uuid", message: "bad"}
    assert Plug.Exception.status(exception) == 404
  end

  test "Ecto.ChangeError (insert/update-time dump failure) maps to 400, not 500" do
    exception = %Ecto.ChangeError{
      message: "value `\"not-a-uuid\"` cannot be dumped to :binary_id"
    }

    assert Plug.Exception.status(exception) == 400
  end
end
