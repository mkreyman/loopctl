defmodule Loopctl.Knowledge.ArticleAccessEventTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge.Analytics
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
      assert ArticleAccessEvent.access_types() == ~w(search get context index drill referenced)
    end

    test "`referenced` is in NO read set — a client assertion must never rank anything" do
      # `referenced` is the one access type a CLIENT asserts about itself. Every other type
      # here is the server recording something it delivered. Admitting it to a read set would
      # let an agent inflate its own article's reads, its heat, and precision, which is the
      # self-inflation failure #567/#569 rebuilt the heat index around — one table over.
      assert "referenced" in ArticleAccessEvent.access_types(),
             "the assertions below are vacuous if the type does not exist"

      refute "referenced" in Analytics.read_access_types()
      refute "referenced" in Analytics.attributable_access_types()

      metrics = File.read!("lib/loopctl/knowledge.ex")
      assert metrics =~ "@heat_read_access_types ~w(get)"

      live = File.read!("lib/loopctl/knowledge/live_retrieval_metrics.ex")
      assert live =~ ~s(@chosen_read_types ["get", "drill"])
    end

    test "#569: the schema allowlist and the Analytics write guard do not drift" do
      # Two allowlists over one column, and there is NO DB CHECK — these are the enforcement.
      # A value in the schema but not in Analytics is silently unwritable (`record_access/6`
      # falls through to its catch-all `:ok` and drops the event); a value in Analytics but not
      # the schema fails `validate_inclusion` at insert, inside a fire-and-forget task where
      # nobody sees it. Both failures are SILENT, which is why this is asserted rather than
      # left to review.
      schema_types = ArticleAccessEvent.access_types()
      analytics_types = Analytics.valid_access_types()

      assert Enum.sort(schema_types) == Enum.sort(analytics_types)
      assert "drill" in schema_types, "the guard is vacuous if the sets are empty"
    end

    test "#569: the analytics READ surface enumerates no list of its own" do
      # There was a THIRD copy, in `KnowledgeAnalyticsController`, and it went stale the moment
      # `drill` was added to the other two — silently, because its filter DROPPED an
      # unrecognised value rather than rejecting it, so `?access_type=drill` returned the
      # UNFILTERED top articles labelled as if the filter had applied. A drift test that binds
      # two of three lists reads like coverage while the third is free, so this asserts the
      # controller holds no independent list at all: it must be the SAME term, not an equal one.
      source = File.read!("lib/loopctl_web/controllers/knowledge_analytics_controller.ex")

      assert source =~ "@valid_access_types Analytics.valid_access_types()"

      refute source =~ ~r/@valid_access_types\s+~w\(/,
             "the analytics controller must DERIVE the access types, never re-list them"
    end
  end
end
