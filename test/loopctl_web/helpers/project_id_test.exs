defmodule LoopctlWeb.Helpers.ProjectIdTest do
  use ExUnit.Case, async: true

  alias LoopctlWeb.Helpers.ProjectId

  describe "validate/1" do
    test "absent (nil) project_id is :ok (tenant-wide listing stays available)" do
      assert ProjectId.validate(nil) == :ok
    end

    test "empty string project_id is :ok (treated as absent)" do
      assert ProjectId.validate("") == :ok
    end

    test "a valid canonical UUID is :ok" do
      assert ProjectId.validate(Ecto.UUID.generate()) == :ok
    end

    test "a malformed (non-UUID) string is a 422 error tuple" do
      assert {:error, :unprocessable_entity, message} = ProjectId.validate("not-a-uuid")
      assert message =~ "project_id"
    end

    test "a 16-char junk string is rejected (does not coerce into a raw-binary UUID)" do
      # Ecto.UUID.cast/1 accepts a raw 16-byte binary; requiring the 36-char
      # dashed form prevents a 16-char junk value coercing into a bogus UUID.
      assert {:error, :unprocessable_entity, _} = ProjectId.validate("0123456789abcdef")
    end

    test "a 36-char non-UUID string is rejected" do
      assert {:error, :unprocessable_entity, _} =
               ProjectId.validate(String.duplicate("z", 36))
    end

    test "a non-string value is tolerated as absent (:ok)" do
      # `?project_id[]=x` decodes to a list; controllers neutralize it to
      # "no filter" and the context filters guard the cast, so it never 500s.
      # Rejecting it here would break array-style query params, so it is :ok.
      assert ProjectId.validate(["not", "a", "string"]) == :ok
      assert ProjectId.validate(123) == :ok
    end
  end
end
