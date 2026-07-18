defmodule Loopctl.Coordination.ChannelPostTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Coordination.ChannelPost

  # A minimally-valid programmatic struct; create_changeset casts only the
  # caller fields on top of it.
  defp base_struct do
    %ChannelPost{
      tenant_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      expires_at: DateTime.utc_now()
    }
  end

  describe "create_changeset/2 validations" do
    test "valid with just a body" do
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => "hello"})
      assert cs.valid?
    end

    test "requires body" do
      cs = ChannelPost.create_changeset(base_struct(), %{})
      refute cs.valid?
      assert %{body: _} = errors_on(cs)
    end

    test "rejects body over 16KB" do
      big = String.duplicate("x", 16_385)
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => big})
      refute cs.valid?
      assert %{body: _} = errors_on(cs)
    end

    test "rejects key over 200 chars" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "key" => String.duplicate("k", 201)
        })

      refute cs.valid?
      assert %{key: _} = errors_on(cs)
    end

    test "rejects refs with a key outside the allowlist" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"evil" => "value"}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "rejects an over-large refs value" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"branch" => String.duplicate("x", 9_000)}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "no kind/category/type field exists on the schema" do
      fields = ChannelPost.__schema__(:fields)
      refute :kind in fields
      refute :category in fields
      refute :type in fields
    end
  end

  describe "secret denylist" do
    test "rejects a secret in the body (422 path)" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "here is my key sk-" <> String.duplicate("a", 30)
        })

      refute cs.valid?
      assert %{body: _} = errors_on(cs)
    end

    test "rejects a secret in a refs value" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"branch" => "lc_" <> String.duplicate("a", 30)}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "rejects a secret in the key" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "key" => "ghp_" <> String.duplicate("a", 30)
        })

      refute cs.valid?
      assert %{key: _} = errors_on(cs)
    end
  end
end
