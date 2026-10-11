defmodule Loopctl.Embeddings.HeavyReadExactScanTest do
  @moduledoc """
  #645: the default suite's vector reads are served by an EXACT plan, applied at the real
  chokepoint (`Loopctl.HeavyRead.maybe_force_exact_scan/1`, from `config/test.exs`'s
  `:heavy_read_force_exact_scan`). The mechanism it works around is reproduced in
  `Loopctl.Embeddings.HnswDeadEntryRecallTest`.

  This is the test that would have caught #645 never landing. The reproduction measures
  the mechanism through hand-built SQL with a pinned plan; none of it touches the code the
  request path actually runs, so all of it stayed green for the two months in which the
  shipped remedy existed only in a docstring. This one reads the planner GUCs from inside a
  real `Loopctl.HeavyRead` read — the actual chokepoint, at the actual configuration — so it
  goes red the moment `maybe_force_exact_scan/1` or `:heavy_read_force_exact_scan` stops
  being wired. BOTH halves are policed only because the expectation is derived from
  `SCALE_TESTS`/`SCALE_NIGHTLY` rather than from the config key the code reads: unwiring the
  key flips the observed GUC and NOT the expectation. Verified by mutation on a DEFAULT run:
  replace the `SET LOCAL enable_indexscan = off` with a no-op and this test fails. Under
  `SCALE_TESTS` that mutation is invisible here by design — that run asserts the forcing is
  NOT applied, so it catches the forcing becoming unconditional instead.

  Async: it reads its own sandboxed row's planner settings and touches no shared graph
  state; its vector is the per-test sparse `test_vec/1`.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.ArticleEmbedding

  @dim 1536

  test "the SHIPPED default-suite read path has the ANN plan disabled at the chokepoint" do
    tenant = fixture(:tenant)
    article = fixture(:article, %{tenant_id: tenant.id, status: :published, title: "Live"})

    AdminRepo.query!(
      """
      INSERT INTO article_embeddings
        (id, tenant_id, article_id, dim, embedding, live_denorm, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, $4::vector, true, now(), now())
      """,
      [
        Ecto.UUID.dump!(tenant.id),
        Ecto.UUID.dump!(article.id),
        @dim,
        Pgvector.new(test_vec(@dim))
      ]
    )

    # Read the planner GUCs FROM INSIDE a real `HeavyRead` read, which is the only place
    # the claim can be checked: `SET LOCAL` is scoped to that transaction, so asking any
    # other connection returns the session default and proves nothing.
    #
    # This asserts the MECHANISM rather than a recovered row on purpose. A recall
    # assertion here is INERT — verified by mutation: with `maybe_force_exact_scan/1`
    # removed, a poisoned-index read through `HeavyRead` still returned the row, because
    # on a table holding one live tuple the planner picks an exact plan on cost anyway.
    # That is the same plan lottery `HnswDeadEntryRecallTest` has to pin `enable_seqscan` to
    # escape (7 exact / 3 HNSW measured over ten runs), and a guard that only fires on 3 runs
    # in 10 is not a guard. What broke in #645 was never the recall — it was the remedy
    # silently not being wired, and this is the assertion that goes red for that.
    query =
      from(ae in ArticleEmbedding,
        where: ae.tenant_id == ^tenant.id,
        select: %{
          indexscan: fragment("current_setting('enable_indexscan')"),
          bitmapscan: fragment("current_setting('enable_bitmapscan')")
        },
        limit: 1
      )

    # The expectation is derived from the ENV, never from `:heavy_read_force_exact_scan`:
    # reading the key `force_exact_scan?/0` reads would make this guard TRACK the config
    # instead of CHECKING it, and deleting the config line would then leave it green. The
    # env is what `config/test.exs` computes that key from, so it is an independent source
    # of truth for both halves of the wiring. A default run must have the forcing applied;
    # a `SCALE_TESTS`/`SCALE_NIGHTLY` run must NOT, so the scale jobs still reach the real
    # HNSW plan — that branch catches the forcing becoming unconditional, nothing else.
    expected =
      if is_nil(System.get_env("SCALE_TESTS")) and is_nil(System.get_env("SCALE_NIGHTLY")),
        do: "off",
        else: "on"

    assert [%{indexscan: ^expected, bitmapscan: ^expected}] = HeavyRead.all(tenant.id, query)
  end
end
