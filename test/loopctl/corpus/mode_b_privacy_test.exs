defmodule Loopctl.Corpus.ModeBPrivacyTest do
  @moduledoc """
  US-43.3 AC-43.3.8 / TC-43.3.1 — the property mode B exists for, asserted DIRECTLY
  rather than inferred from the shape of the API.

  A regulated corpus is indexed end to end over HTTP with a marker string that is
  NEVER sent: the client hashes and embeds it locally and loopctl receives only a
  vector, a pointer and an opaque hash. The marker is then hunted for in every place
  it could possibly have landed — every COLUMN of `document_chunks` and
  `document_chunk_embeddings` (the whole row cast to text, not just `text`), the
  audit rows the ingest wrote, the captured log, and every field of the ingest and
  search responses.

  ## Why each scan carries a positive control

  A `refute haystack =~ marker` passes VACUOUSLY when the haystack was never
  populated in the first place — the failure class the repo's own guard tests are
  written against. So every scan here is run TWICE: once for the marker, which must
  be absent, and once for a string that IS legitimately submitted (`source_ref`,
  a permitted `snippet`), which must be PRESENT. If the scan stops working, the
  control fails first.

  The second test covers the other direction: a snippet sent to a corpus that
  FORBIDS them is refused, and the refusal must not echo, store or log it — the
  "convenience field" regression this file is written to catch.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Corpus
  alias Loopctl.Corpus.DocumentChunk

  setup :verify_on_exit!

  # Never sent. The client holds it, hashes it and embeds it; loopctl sees neither the
  # string nor anything derived from it that could reconstruct it.
  @marker "zorbitrandex-phi-body-marker-7Q"

  # Sent, and REFUSED, because the corpus forbids snippets.
  @refused_snippet "quixotrimble-phi-snippet-3W"

  @source_ref "regulated/837p-companion.pdf"

  # The control token for the log capture (see the assertion that uses it).
  @log_probe "log-capture-control-5R"

  # The modules a mode B request passes through. A log line on this path is the one way
  # content could leave the request without touching a column, so the guard below reads
  # their SOURCE rather than trusting an environment that cannot emit `:debug`.
  @mode_b_path [
    "lib/loopctl/corpus/indexer.ex",
    "lib/loopctl/corpus/search.ex",
    "lib/loopctl_web/controllers/corpus_controller.ex"
  ]

  # Bindings that hold caller-supplied content at some point on that path.
  @payload_bindings ~w(chunks attrs item items text snippet vector params body_params)

  defp keyed_tenant do
    tenant = fixture(:tenant)
    {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    {tenant, raw_key}
  end

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp mode_b_corpus!(tenant_id, attrs \\ %{}) do
    {:ok, corpus} =
      Corpus.create_corpus(
        tenant_id,
        Map.merge(
          %{
            slug: "regulated-#{System.unique_integer([:positive])}",
            name: "Regulated companion",
            mode: :client_embedded,
            embedding_model: "local-nomic-embed",
            dim: 1536
          },
          attrs
        )
      )

    corpus
  end

  # The CLIENT's pipeline, run entirely in the test: the text is hashed and embedded
  # here and neither the text nor the request ever carries it.
  defp client_hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp client_vector(tenant_id, dims) do
    base = rem(:erlang.phash2(tenant_id), 1500)
    hot = MapSet.new(dims, &(base + &1))

    Enum.map(0..1535, fn i -> if MapSet.member?(hot, i), do: 1.0, else: 0.0 end)
  end

  # Casting the WHOLE ROW to text catches every column — including one a later change
  # adds — rather than only the ones this test knew to name.
  defp row_matches(table, tenant_id, needle) do
    %{rows: [[count]]} =
      AdminRepo.query!(
        "SELECT count(*) FROM #{table} t WHERE t.tenant_id = $1::uuid AND t::text LIKE $2",
        [Ecto.UUID.dump!(tenant_id), "%#{needle}%"]
      )

    count
  end

  describe "the server never receives the text (TC-43.3.1)" do
    test "a marker the client never sends appears in no row, no audit entry, no log and no response",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      # The client's own chunking. `text` exists only here.
      text = "#{@marker} — member 12345678 rendering provider taxonomy 207Q00000X"

      chunk = %{
        "source_ref" => @source_ref,
        "locator" => %{"page" => 47},
        "vector" => client_vector(tenant.id, 0..7),
        "content_hash" => client_hash(text),
        "ordinal" => 47
      }

      refute inspect(chunk) =~ @marker

      {{ingest_body, search_body}, log} =
        with_log([level: :debug], fn ->
          # The control for the capture itself. The test env's primary logger level is
          # `:warning`, so a capture with nothing at that level in it is EMPTY and
          # `refute log =~ marker` passes vacuously. This line proves the capture is live
          # at the level the refusal and write-failure paths actually log at; the
          # source-level guard below is what covers the `:debug`/`:info` lines this
          # environment cannot emit.
          Logger.warning("corpus mode B privacy probe #{@log_probe}")

          ingest =
            conn
            |> auth(raw_key)
            |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [chunk]})
            |> json_response(200)

          search =
            conn
            |> auth(raw_key)
            |> post(~p"/api/v1/corpora/#{corpus.id}/search", %{
              "query_vector" => client_vector(tenant.id, 0..7)
            })
            |> json_response(200)

          {ingest, search}
        end)

      # --- the controls: the scans below are live and the haystacks are populated ---
      assert [%{"status" => "inserted"}] = ingest_body["data"]
      assert [%{"source_ref" => @source_ref}] = search_body["data"]
      assert row_matches("document_chunks", tenant.id, @source_ref) == 1

      audit_rows =
        AdminRepo.all(
          from(a in AuditLog,
            where: a.tenant_id == ^tenant.id and a.action == "corpus_indexed"
          )
        )

      assert length(audit_rows) == 1
      assert row_matches("audit_log", tenant.id, "corpus_indexed") == 1

      embedding_rows =
        AdminRepo.aggregate(
          from(e in Loopctl.Corpus.DocumentChunkEmbedding, where: e.tenant_id == ^tenant.id),
          :count,
          :id
        )

      assert embedding_rows == 1

      # --- the property ---
      assert row_matches("document_chunks", tenant.id, @marker) == 0
      assert row_matches("document_chunk_embeddings", tenant.id, @marker) == 0
      assert row_matches("audit_log", tenant.id, @marker) == 0
      assert log =~ @log_probe, "the log capture is empty — the refutation below is vacuous"
      refute log =~ @marker
      refute inspect(ingest_body) =~ @marker
      refute inspect(search_body) =~ @marker

      # And the column that would hold it is NULL, not merely free of this one string.
      assert [%DocumentChunk{text: nil, snippet: nil}] =
               AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id))
    end
  end

  describe "a snippet the corpus forbids is refused, never stored and never echoed" do
    test "the 422 names the rule without repeating the value", %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id)

      refute corpus.allow_snippets

      chunk = %{
        "source_ref" => @source_ref,
        "locator" => %{"page" => 47},
        "vector" => client_vector(tenant.id, 0..7),
        "content_hash" => client_hash("whatever the client held"),
        "snippet" => @refused_snippet
      }

      body =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [chunk]})
        |> json_response(422)

      assert body["error"]["code"] == "snippets_not_allowed"
      assert body["error"]["message"] =~ "allow_snippets"
      refute inspect(body) =~ @refused_snippet

      assert row_matches("document_chunks", tenant.id, @refused_snippet) == 0
      assert AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id)) == []
    end

    # The CONTROL for the scan above: the very same needle IS found once a corpus that
    # permits snippets stores one, so a zero above means absence and not a broken scan.
    test "the identical scan finds the value once a corpus that permits snippets stores it",
         %{conn: conn} do
      {tenant, raw_key} = keyed_tenant()
      corpus = mode_b_corpus!(tenant.id, %{allow_snippets: true})

      chunk = %{
        "source_ref" => @source_ref,
        "locator" => %{"page" => 47},
        "vector" => client_vector(tenant.id, 0..7),
        "content_hash" => client_hash("whatever the client held"),
        "snippet" => @refused_snippet
      }

      conn
      |> auth(raw_key)
      |> post(~p"/api/v1/corpora/#{corpus.id}/index", %{"chunks" => [chunk]})
      |> json_response(200)

      assert row_matches("document_chunks", tenant.id, @refused_snippet) == 1
    end
  end

  # The half the environment cannot test: this suite runs at `:warning`, production at
  # `:info`, so a `Logger.debug`/`Logger.info` echoing a request body would emit in
  # production and be invisible here. Read the source instead.
  #
  # MUTATION-VERIFIED, in the INTERPOLATED form — the one an author actually writes, and
  # the one an earlier version of this guard could not see because it rejected every line
  # containing a `#` (the first character of `\#{}`) as a comment: adding
  # `Logger.info("payload \#{inspect(chunks)}")` to `Loopctl.Corpus.Indexer.index_chunks/4`
  # turns this red, as does the `<>` concatenation form.
  describe "no module on the mode B path logs the payload" do
    test "every Logger call on the ingest and search path is free of payload bindings" do
      call_sites =
        Enum.flat_map(@mode_b_path, fn path ->
          # Comments are stripped, not used to reject the whole line: a trailing `# ...`
          # must not hide the code before it, and an interpolation is not a comment.
          lines = path |> File.read!() |> String.split("\n") |> Enum.map(&strip_comment/1)

          for {line, index} <- Enum.with_index(lines),
              String.contains?(line, "Logger."),
              do: {path, index + 1, lines |> Enum.slice(index, 4) |> Enum.join(" ")}
        end)

      # Non-vacuity: the scan found the log lines that ARE there (the write-failure
      # error), so an empty offender list means absence and not a broken scan.
      assert call_sites != []

      offenders =
        for {path, line, window} <- call_sites,
            binding <- @payload_bindings,
            Regex.match?(payload_regex(binding), window),
            do: "#{path}:#{line} logs #{binding}"

      assert offenders == []
    end
  end

  # Everything from the first `#` that does not open an interpolation. Crude for Elixir
  # in general (a literal `#` inside a string is not a comment), but exact for the one
  # question asked here: whether a Logger call names a payload binding.
  defp strip_comment(line), do: line |> String.split(~r/#(?!\{)/, parts: 2) |> hd()

  # The binding may be reached through a field or an index (`inspect(item.snippet)`,
  # `\#{hd(chunks)}`), so it is matched as a WORD anywhere inside the `inspect(...)` call
  # or the interpolation rather than as the whole argument.
  defp payload_regex(binding),
    do: ~r/inspect\([^)]*\b#{binding}\b|\#\{[^}]*\b#{binding}\b/
end
