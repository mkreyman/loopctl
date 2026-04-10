defmodule Loopctl.Knowledge.ArticleAccessEventTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge.ArticleAccessEvent

  describe "create_changeset/2" do
    test "valid changeset with all required fields" do
      changeset =
        ArticleAccessEvent.create_changeset(%ArticleAccessEvent{}, %{
          article_id: Ecto.UUID.generate(),
          api_key_id: Ecto.UUID.generate(),
          access_type: "get",
          accessed_at: DateTime.utc_now()
        })

      assert changeset.valid?
      assert get_field(changeset, :metadata) == %{}
    end

    test "metadata defaults to empty map and accepts free-form values" do
      changeset =
        ArticleAccessEvent.create_changeset(%ArticleAccessEvent{}, %{
          article_id: Ecto.UUID.generate(),
          api_key_id: Ecto.UUID.generate(),
          access_type: "search",
          metadata: %{"query" => "elixir genserver", "rank" => 1},
          accessed_at: DateTime.utc_now()
        })

      assert changeset.valid?
      assert get_field(changeset, :metadata) == %{"query" => "elixir genserver", "rank" => 1}
    end

    test "rejects missing required fields" do
      changeset = ArticleAccessEvent.create_changeset(%ArticleAccessEvent{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:article_id]
      assert errors[:api_key_id]
      assert errors[:access_type]
      assert errors[:accessed_at]
    end

    for type <- ~w(search get context index) do
      test "accepts access_type=#{type}" do
        changeset =
          ArticleAccessEvent.create_changeset(%ArticleAccessEvent{}, %{
            article_id: Ecto.UUID.generate(),
            api_key_id: Ecto.UUID.generate(),
            access_type: unquote(type),
            accessed_at: DateTime.utc_now()
          })

        assert changeset.valid?
      end
    end

    test "rejects invalid access_type values" do
      changeset =
        ArticleAccessEvent.create_changeset(%ArticleAccessEvent{}, %{
          article_id: Ecto.UUID.generate(),
          api_key_id: Ecto.UUID.generate(),
          access_type: "delete",
          accessed_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:access_type]
    end
  end

  describe "access_types/0" do
    test "returns all supported types" do
      assert ArticleAccessEvent.access_types() == ~w(search get context index)
    end
  end
end
