defmodule Loopctl.Knowledge.ConsolidationGenericTitleTest do
  @moduledoc """
  The automatic consumer for the `:generic_title` proposal class.

  The class was report-only and therefore LEAKED: re-derived every night with nothing on
  the other end, which is the queue-with-no-consumer shape #605 names. Every test here
  guards one of the conditions under which the retitle is allowed to happen — and each one
  was mutation-verified by deleting its guard and watching this file go red.
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.MockContentExtractor

  @specific_title "Ecto changesets validate before they cast"

  # Published articles are written as draft-then-update so the inline embedding -> linking
  # cascade never fires: everything exercised here is lexical, never vector.
  defp published(tenant_id, attrs) do
    base = %{
      category: :pattern,
      tags: [],
      body: "A body about Ecto changesets. #{System.unique_integer([:positive])}"
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp reload(id), do: AdminRepo.get!(Article, id)

  # Two consecutive reports proposing the same fingerprint — the gate that stands in for the
  # human approver who does not exist.
  defp confirm_over_two_nights(tenant_id) do
    {:ok, _} = Consolidation.run(tenant_id, day: Date.add(Date.utc_today(), -1))
    {:ok, _} = Consolidation.run(tenant_id)
  end

  defp placeholder(tenant_id, title \\ "Untitled") do
    article = published(tenant_id, %{title: title})
    confirm_over_two_nights(tenant_id)
    article
  end

  defp three_placeholders(tenant_id) do
    for t <- ["Untitled", "Draft", "New Article"], do: published(tenant_id, %{title: t})
    confirm_over_two_nights(tenant_id)
  end

  # One extraction returning one usable article; only its TITLE is ever read.
  defp expect_title(title) do
    Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
      {:ok, [%{title: title, body: "Ignored body.", category: :pattern, tags: [], metadata: %{}}]}
    end)
  end

  describe "apply_confirmed_generic_titles/2 — the happy path and its provenance" do
    test "retitles a confirmed placeholder from the article's own content" do
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)
      expect_title(@specific_title)

      assert %{
               applied: 1,
               skipped: 0,
               abstained: 0,
               failed: 0,
               offered: 1,
               budget_exhausted: false,
               gate: :open
             } = Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == @specific_title
    end

    test "records the title it replaced, and marks the new one machine-generated" do
      # Two records, deliberately in two places. The REPLACED TITLE is the undo record and
      # goes on a column; the machine-generated MARKER is advisory (it answers "is this ours
      # to replace"), is allowed to be erasable, and keeps StructuralLinks' shape.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)
      expect_title(@specific_title)

      assert %{applied: 1} = Consolidation.apply_confirmed_generic_titles(tenant.id)

      retitled = reload(article.id)
      assert retitled.previous_title == "Untitled"
      assert retitled.metadata["consolidation_title_generated"] == @specific_title
    end

    test "the undo record SURVIVES an ordinary metadata-replacing update" do
      # The whole reason it is a COLUMN. `metadata` is cast as a WHOLE MAP, so one ordinary
      # `PATCH /api/v1/knowledge/:id` replaces it — which used to destroy the record of what
      # to restore while leaving the retitle standing. Reversibility is the only thing
      # licensing an unattended machine retitle, so an erasable undo record is not one.
      # The advisory marker going away in the same call is the contrast, not a defect.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)
      expect_title(@specific_title)

      assert %{applied: 1} = Consolidation.apply_confirmed_generic_titles(tenant.id)

      {:ok, _} =
        Knowledge.update_article(tenant.id, article.id, %{
          metadata: %{"visibility" => "shared"}
        })

      patched = reload(article.id)
      assert patched.previous_title == "Untitled"
      assert patched.title == @specific_title
      refute Map.has_key?(patched.metadata, "consolidation_title_generated")
    end

    test "regenerates the slug, so a placeholder slug does not outlive the placeholder title" do
      # `maybe_generate_slug/1` runs only in `create_changeset/2`, so a retitled article kept
      # its `untitled-a1b2c3` slug forever — and this step is what makes that fire unattended,
      # at scale, on exactly the articles whose slug is a placeholder.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)
      assert article.slug =~ ~r/\Auntitled-/
      expect_title(@specific_title)

      assert %{applied: 1} = Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).slug =~ ~r/\Aecto-changesets-validate-before-they-cast-/
    end
  end

  describe "the two-run agreement gate" do
    test "does NOT apply on a single report" do
      # Anything transient — a placeholder created and fixed between runs, a half-finished
      # import — is gone by the next night and must never be acted on. `offered: 0` is the
      # assertion that matters: nothing reached the extractor at all.
      tenant = fixture(:tenant)
      article = published(tenant.id, %{title: "Untitled"})
      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 0, offered: 0, gate: :insufficient_history} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "does NOT apply when the two reports are further apart than the window" do
      # On a tenant whose scans failed for a fortnight the two most recent reports are
      # tonight and one from before the outage; agreement across that gap is not the
      # transience filter the gate claims to be.
      tenant = fixture(:tenant)
      article = published(tenant.id, %{title: "Untitled"})
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -14))
      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 0, offered: 0, gate: :report_gap} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "a placeholder that appeared only TONIGHT is not retitled tonight" do
      # The half of the gate the two `gate:` codes above cannot reach: two adjacent reports
      # exist and the window is fine, but only ONE of them proposes this article. A
      # placeholder created and fixed between runs, or a half-finished import, is gone by
      # the next night and must never be acted on — one night of latency buys the whole
      # class of "acted on a state that was already resolving itself".
      tenant = fixture(:tenant)
      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      article = published(tenant.id, %{title: "Untitled"})
      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 0, offered: 0, gate: :open} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "a cap of 0 PAUSES the drain" do
      # This is the one nightly step that spends a tenant's provider budget per item, so an
      # operator halting it mid-incident must get a halt and not a rounded-up 1.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      assert %{applied: 0, offered: 0, gate: :drain_disabled} =
               Consolidation.apply_confirmed_generic_titles(tenant.id, max_retitles: 0)

      assert reload(article.id).title == "Untitled"
    end
  end

  describe "re-derivation against the live row" do
    test "skips a title that was FIXED between the scan and the write" do
      # The one remedy a human has is to retitle the article. Completing their edit for
      # them, with a machine title, hours later, is the failure `still_colliding/5` exists
      # to prevent on the other class. `skipped` (not `abstained`) is the assertion: an
      # abstention would mean the extractor was reached, i.e. the re-check never ran.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      article
      |> Ecto.Changeset.change(%{title: "A human named this properly"})
      |> AdminRepo.update!()

      assert %{applied: 0, skipped: 1, abstained: 0, offered: 1, gate: :open} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "A human named this properly"
    end

    test "skips an article that stopped being PUBLISHED between the scan and the write" do
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      article |> Ecto.Changeset.change(%{status: :draft}) |> AdminRepo.update!()

      assert %{applied: 0, skipped: 1, abstained: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "skips an article that became agent-PRIVATE after the scan" do
      # `shared_only/1` is composed into every scope decision this pass makes, and this one
      # matters more than most: the step ships the article's opening bytes to a provider, so
      # a published article that has since become an agent's private memory must be out of
      # reach here exactly as it is in the scan.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      article
      |> Ecto.Changeset.change(%{
        metadata: %{"agent_id" => "agent-1", "visibility" => "private"}
      })
      |> AdminRepo.update!()

      assert %{applied: 0, skipped: 1, abstained: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "re-checks the live row AFTER the provider call, not only before it" do
      # `classify_live/1` runs BEFORE a call the provider may hold for 25 s; a human who
      # retitles inside that window must not have their edit completed for them.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
        reload(article.id)
        |> Ecto.Changeset.change(%{title: "A human named this properly"})
        |> AdminRepo.update!()

        {:ok, [%{title: @specific_title, body: "b", category: :pattern, tags: [], metadata: %{}}]}
      end)

      assert %{applied: 0, skipped: 1, abstained: 0, failed: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "A human named this properly"
    end

    test "merges into the metadata as it is AFTER the provider call" do
      # `:metadata` is cast as a WHOLE map, so writing back a snapshot one round-trip old
      # reverts whatever landed during the call (`visibility`, ingestion provenance).
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
        reload(article.id)
        |> Ecto.Changeset.change(%{metadata: %{"source_url" => "https://ex.com"}})
        |> AdminRepo.update!()

        {:ok, [%{title: @specific_title, body: "b", category: :pattern, tags: [], metadata: %{}}]}
      end)

      assert %{applied: 1, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).metadata["source_url"] == "https://ex.com"
    end

    test "skips a CURATED article, whose retitle is the one part that is NOT undoable" do
      # Any title change clears `curated_at`/`curated_by`, and putting the title back does
      # not put the governed marker back — re-curation has to go through `mark_curated/3`.
      # Reversibility is what licenses this whole step, so where it does not hold, it stops.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      from(a in Article, where: a.id == ^article.id)
      |> AdminRepo.update_all(set: [curated_at: DateTime.utc_now(), curated_by: "curator"])

      assert %{applied: 0, skipped: 1, abstained: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      article = reload(article.id)
      assert article.title == "Untitled"
      refute is_nil(article.curated_at)
    end
  end

  describe "abstention beats invention" do
    test "abstains when the provider errors" do
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
        {:error, :no_api_key}
      end)

      assert %{applied: 0, abstained: 1, skipped: 0, failed: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "abstains when the extractor declines to produce anything" do
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
        {:ok, []}
      end)

      assert %{applied: 0, abstained: 1, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "abstains rather than writing ANOTHER placeholder" do
      # Without this the article is re-proposed tomorrow night and retitled forever, and the
      # class never converges — with a provider call spent on every lap.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)
      expect_title("Untitled Document")

      assert %{applied: 0, abstained: 1, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "abstains on a title over the column limit rather than letting the write reject it" do
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)
      expect_title(String.duplicate("a", 501))

      assert %{applied: 0, abstained: 1, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "abstains on a reply that names SEVERAL articles" do
      # The extractor SPLITS content into up to ten articles, and saw only the opening 4 KB:
      # candidate #1 names the article's first section, not the article.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
        {:ok,
         [
           %{title: @specific_title, body: "b", category: :pattern, tags: [], metadata: %{}},
           %{title: "Oban unique jobs", body: "b", category: :pattern, tags: [], metadata: %{}}
         ]}
      end)

      assert %{applied: 0, abstained: 1, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "abstains when the reply is not a list of articles at all" do
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
        {:ok, :not_a_list}
      end)

      assert %{applied: 0, abstained: 1, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    defmodule RaisingExtractor do
      @moduledoc false
      @behaviour Loopctl.Knowledge.ContentExtractorBehaviour

      @impl true
      def extract_from_content(_scope, _content, _opts), do: raise("provider exploded")
    end

    test "a raise inside the provider is an ABSTENTION, never a failure" do
      # `failed` is reserved for a write that could not be made. A provider that raised
      # produced no title, which is the same outcome as a model that declined — and counting
      # it as a failure would report a write that was never going to be attempted.
      # Injected PER CALL: `Application.put_env` would mutate VM-global state every other
      # test in this async suite would see.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      assert %{applied: 0, abstained: 1, failed: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id,
                 content_extractor: RaisingExtractor
               )

      assert reload(article.id).title == "Untitled"
    end
  end

  describe "the active-title uniqueness constraint" do
    test "a colliding generated title is a SKIP, not an exception" do
      # `articles_tenant_title_active_idx` is unique per tenant over active statuses. The
      # generated title is not this run's to arbitrate, so the write is refused, the
      # placeholder stands, and the article remains a candidate for a later night.
      tenant = fixture(:tenant)
      _incumbent = published(tenant.id, %{title: @specific_title})
      article = placeholder(tenant.id)
      expect_title(@specific_title)

      assert %{applied: 0, skipped: 1, abstained: 0, failed: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end
  end

  describe "the pass's own normalization" do
    test "skips a generated title that collides with another article only under normalization" do
      # The unique index is on the RAW `(tenant_id, title)`, so a case/punctuation variant
      # stores fine — and the two are then ONE `:duplicate_capture` group, which the sibling
      # drain unpublishes two nights later.
      tenant = fixture(:tenant)
      _incumbent = published(tenant.id, %{title: "Ecto changesets: validate before cast"})
      article = placeholder(tenant.id)
      expect_title("Ecto Changesets - Validate Before Cast")

      assert %{applied: 0, skipped: 1, abstained: 0, failed: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end

    test "a DRAFT or an agent-PRIVATE article never blocks a retitle it could not group with" do
      # The group this guard exists to prevent is built by `title_drift_groups/1` over
      # `published_base/1` — published AND shared-visibility — so the guard is scoped the same
      # way. Scoped instead to the raw index's active statuses, rows that can never join that
      # group vetoed the write, and PERMANENTLY: the collision is deterministic, so the
      # placeholder was re-offered, re-generated at one provider call a night, and never fixed.
      tenant = fixture(:tenant)

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Ecto changesets: validate before cast",
        category: :pattern,
        tags: [],
        body: "A draft nobody published."
      })

      published(tenant.id, %{
        title: "Ecto changesets, validate before cast",
        metadata: %{"visibility" => "private"}
      })

      article = placeholder(tenant.id)
      expect_title("Ecto Changesets - Validate Before Cast")

      assert %{applied: 1, skipped: 0, abstained: 0, failed: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Ecto Changesets - Validate Before Cast"
    end

    test "an empty body found AFTER the provider call ABSTAINS, exactly as it does before" do
      # `classify_live/1` makes an empty body an abstention on purpose — the article is still
      # a live candidate, it just cannot be named from content it does not have. The post-call
      # re-read runs the same classifier, so the same condition must land in the same counter;
      # funnelling it into `skipped` made the bucket depend only on whether the provider call
      # had already returned, and moved it out of the tally the keyless-tenant warning reads.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)

      Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
        article.id
        |> reload()
        |> Ecto.Changeset.change(%{body: "   "})
        |> AdminRepo.update!()

        {:ok, [%{title: @specific_title, body: "b", category: :pattern, tags: [], metadata: %{}}]}
      end)

      assert %{applied: 0, skipped: 0, abstained: 1, failed: 0, offered: 1} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end
  end

  describe "a write that could not be made" do
    test "counts as a FAILURE, and the reduce carries on" do
      # The per-item rescue: this reduce is not transactional, so a raise escaping it would
      # discard the tally of articles already retitled and report zero writes that really
      # happened. A NUL byte is a title Postgres cannot store at all, so the failure lands
      # in the write rather than in the provider — which is exactly the split `failed`
      # exists to keep: a provider that produced nothing is an abstention, a write that
      # could not be made is a failure.
      tenant = fixture(:tenant)
      article = placeholder(tenant.id)
      expect_title("Ecto changesets\u0000 validate")

      assert %{applied: 0, failed: 1, abstained: 0, skipped: 0, offered: 1, gate: :open} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)

      assert reload(article.id).title == "Untitled"
    end
  end

  describe "the wall-clock bound" do
    test "an EXHAUSTED clock buys zero provider calls, not a rounded-up one" do
      # The deadline is checked BEFORE each item: a post-item check is unconditionally
      # committed to item #1, so a budget of exactly 0 still bought one outbound call.
      tenant = fixture(:tenant)
      three_placeholders(tenant.id)

      assert %{
               applied: 0,
               skipped: 0,
               abstained: 0,
               failed: 0,
               offered: 3,
               budget_exhausted: true,
               gate: :open
             } =
               Consolidation.apply_confirmed_generic_titles(tenant.id, budget_ms: 0)

      assert AdminRepo.aggregate(
               from(a in Article, where: a.tenant_id == ^tenant.id and a.title == "Untitled"),
               :count
             ) == 1
    end

    test "a truncated night REPORTS the truncation instead of looking like a quiet one" do
      # The #761 acceptance criterion, in this step: `applied` alone reads the same on a
      # night the clock cut short and a night with nothing left to do. `offered` and
      # `budget_exhausted` are what tell them apart.
      tenant = fixture(:tenant)
      three_placeholders(tenant.id)

      # ONE expectation for three candidates: the halt keeps `verify_on_exit!` green.
      Mox.expect(MockContentExtractor, :extract_from_content, fn _scope, _content, _opts ->
        Process.sleep(40)
        {:ok, [%{title: @specific_title, body: "b", category: :pattern, tags: [], metadata: %{}}]}
      end)

      result = Consolidation.apply_confirmed_generic_titles(tenant.id, budget_ms: 20)

      assert %{offered: 3, budget_exhausted: true, gate: :open} = result

      assert result.applied + result.skipped + result.abstained + result.failed == 1,
             "an exhausted budget must halt before the item it cannot pay for"
    end

    test "a night that drained everything it was offered is NOT reported as truncated" do
      # A flag that is true on a converged night is as unreadable as no flag at all — the
      # head check is never reached again once the last candidate is processed.
      tenant = fixture(:tenant)
      placeholder(tenant.id)
      expect_title(@specific_title)

      assert %{applied: 1, offered: 1, budget_exhausted: false} =
               Consolidation.apply_confirmed_generic_titles(tenant.id)
    end
  end

  describe "tenant isolation" do
    test "one tenant's confirmed placeholder is invisible to another tenant's run" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      article_a = placeholder(tenant_a.id)
      confirm_over_two_nights(tenant_b.id)

      # B has nothing of its own and must not reach A's article — no extractor call at all.
      assert %{applied: 0, offered: 0, gate: :open} =
               Consolidation.apply_confirmed_generic_titles(tenant_b.id)

      assert reload(article_a.id).title == "Untitled"

      # And A's own run still works, so the isolation is not "nothing ever applies".
      expect_title(@specific_title)
      assert %{applied: 1, offered: 1} = Consolidation.apply_confirmed_generic_titles(tenant_a.id)
      assert reload(article_a.id).title == @specific_title
    end
  end
end
