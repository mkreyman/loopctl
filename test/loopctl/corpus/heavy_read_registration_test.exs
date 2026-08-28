defmodule Loopctl.Corpus.HeavyReadRegistrationTest do
  @moduledoc """
  US-43.2 AC-43.2.11 — `:corpus_search` must appear in ALL FOUR places a heavy ANN
  read has to be registered, and each omission fails differently:

    * `HeavyRead.known_endpoints/0` — the source of truth the other three are checked
      against. `heavy_read_guard_test.exs` statically scans `lib/` for every literal
      `HeavyRead.opts(:endpoint)` atom against it, so registering only the others
      fails that test too.
    * `HeavyRead.ann_endpoints/0` — without it the read gets NO `SET LOCAL
      hnsw.ef_search`, and the HNSW scan returns pgvector's default breadth no matter
      how large an inner pool the code asks for. That is a SILENT recall loss, not an
      error, which is why it needs an assertion rather than a test that would notice.
    * `TenantGate.heavy_endpoints/0` — without it the read is admitted at LIGHT weight
      and cannot be shed proportionally under load.
    * `@expected_weights` in `tenant_gate_test.exs` — asserts MapSet equality against
      `known_endpoints/0`, so it fails deterministically until the endpoint carries a
      deliberate heavy/light decision. That one is exercised by its own file; this
      test pins the three production registries and the endpoint's actual use.

  Verified by MUTATION rather than by reading: removing `corpus_search` from
  `@ann_endpoints` turns the second assertion red, and removing it from
  `@heavy_endpoints` turns the third red. Both mutations were reversed in place.
  """

  use ExUnit.Case, async: true

  alias Loopctl.HeavyRead
  alias Loopctl.HeavyRead.TenantGate

  @endpoint_atom :corpus_search

  test "the endpoint is registered in all three production registries" do
    assert @endpoint_atom in HeavyRead.known_endpoints(),
           "an unregistered endpoint escapes the weight-drift guard entirely"

    assert @endpoint_atom in HeavyRead.ann_endpoints(),
           "without this the corpus ANN gets no SET LOCAL hnsw.ef_search and the " <>
             "over-fetched inner pool is inert — a silent recall loss, not an error"

    assert @endpoint_atom in TenantGate.heavy_endpoints(),
           "without this a corpus search is admitted at light weight and cannot be shed"
  end

  test "it is classified HEAVY, like every other ANN endpoint" do
    assert TenantGate.weight_for(@endpoint_atom) == TenantGate.heavy_weight()
  end

  test "the ANN registration is what the search path actually reaches for" do
    # Non-vacuity: the atom is not merely present in the registries, it is the one the
    # corpus search path stamps into its telemetry options. A rename on one side alone
    # fails here rather than silently un-registering the read.
    opts = HeavyRead.opts(@endpoint_atom)

    assert Keyword.get(opts, :telemetry_options)[:endpoint] == @endpoint_atom

    source = File.read!(Path.join(__DIR__, "../../../lib/loopctl/corpus/search.ex"))
    assert source =~ "HeavyRead.opts(:#{@endpoint_atom})"
  end
end
