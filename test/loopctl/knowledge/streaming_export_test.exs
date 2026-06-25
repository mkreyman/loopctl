defmodule Loopctl.Knowledge.StreamingExportTest do
  @moduledoc """
  US-27.16 core streaming-export tests on a SMALL corpus (the heavy 50k scale
  assertions live in `streaming_export_scale_test.exs`, tagged `:scale_nightly`).

  Covers:
  - TC-27.16.4: the streamed id-set equals the canonical export base-query id-set
    for the same `(tenant, project)` — including the `project_id IS NULL`
    disjunction — and carries zero cross-tenant content.
  - TC-27.16.3 (small): a mid-stream failure fails CLOSED (consumer detects
    truncation) and the partial bytes contain no SQL/params/vector/stack text.
  - AC-27.16.3 (small): a dense-hub article's link list is bounded.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.StreamingExport
  alias Loopctl.Knowledge.StreamingExport.ObsidianFormat
  alias Loopctl.StreamingExportHelper

  defp published(tenant_id, attrs) do
    fixture(
      :article,
      Map.merge(%{tenant_id: tenant_id, status: :published}, Enum.into(attrs, %{}))
    )
  end

  # The canonical id-set the legacy exporter would have produced: the EXACT WHERE
  # of StreamingExport.base_query/2 (tenant + status=:published + project
  # disjunction), via the tenant-guarded heavy-read path.
  defp canonical_ids(tenant_id, project_id) do
    query = StreamingExport.base_query(tenant_id, project_id) |> select([a], a.id)
    tenant_id |> HeavyRead.all(query) |> MapSet.new()
  end

  # Resolve the streamed bundle back to the set of article ids it contains. The
  # Obsidian frontmatter has no id, so map each rendered article file back to its
  # id by title (titles are unique per tenant among active articles).
  defp streamed_ids(tenant_id, opts) do
    {:ok, targz} = StreamingExportHelper.to_targz_binary(tenant_id, ObsidianFormat, opts)
    {:ok, files} = StreamingExportHelper.extract(targz)

    titles =
      files
      |> Map.drop(["_index.md"])
      |> Map.values()
      |> Enum.map(&extract_title/1)

    query =
      Article
      |> where([a], a.tenant_id == ^tenant_id and a.title in ^titles)
      |> select([a], a.id)

    tenant_id |> HeavyRead.all(query) |> MapSet.new()
  end

  defp extract_title(content) do
    [_, title] = Regex.run(~r/title:\s*"([^"]*)"/, content)
    title
  end

  describe "TC-27.16.4: streamed id-set == canonical export id-set + tenant-scoped" do
    test "tenant-wide export (no project): identical id-set" do
      tenant = fixture(:tenant)

      for i <- 1..7,
          do: published(tenant.id, %{title: "T#{i}", body: "b#{i}", category: :pattern})

      canonical = canonical_ids(tenant.id, nil)
      streamed = streamed_ids(tenant.id, [])

      assert MapSet.equal?(streamed, canonical)
      assert MapSet.size(streamed) == 7
    end

    test "project-scoped export includes the project_id IS NULL disjunction" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other = fixture(:project, %{tenant_id: tenant.id})

      published(tenant.id, %{title: "Wide", body: "b", category: :pattern})

      published(tenant.id, %{
        title: "InProj",
        body: "b",
        category: :decision,
        project_id: project.id
      })

      published(tenant.id, %{title: "Other", body: "b", category: :finding, project_id: other.id})

      canonical = canonical_ids(tenant.id, project.id)
      streamed = streamed_ids(tenant.id, project_id: project.id)

      assert MapSet.equal?(streamed, canonical)
      # Wide (nil project) + InProj, but NOT Other.
      assert MapSet.size(streamed) == 2
    end

    test "zero cross-tenant content in the streamed bundle" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      published(tenant_a.id, %{title: "Alpha A", body: "secret-a", category: :pattern})
      published(tenant_b.id, %{title: "Bravo B", body: "secret-b", category: :pattern})

      {:ok, targz} = StreamingExportHelper.to_targz_binary(tenant_a.id, ObsidianFormat)
      {:ok, files} = StreamingExportHelper.extract(targz)
      all = files |> Map.values() |> Enum.join("\n")

      assert all =~ "secret-a"
      refute all =~ "Bravo B"
      refute all =~ "secret-b"
    end
  end

  describe "TC-27.16.3 (small): fail-closed on mid-stream error, no leak" do
    test "a mid-stream DB-style error truncates the archive and leaks no internal text" do
      tenant = fixture(:tenant)
      # Enough articles to span multiple keyset pages (chunk_size is 3 in test).
      for i <- 1..6,
          do: published(tenant.id, %{title: "Doc #{i}", body: "body #{i}", category: :pattern})

      # A format that raises a Postgrex.Error partway (simulating a Repo/timeout
      # error reaching the streaming producer mid-bundle).
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      emit = fn iodata ->
        Agent.update(agent, fn _ -> :unused end)
        send(self(), {:chunk, IO.iodata_to_binary(iodata)})
        {:ok, :collected}
      end

      result =
        StreamingExport.stream(tenant.id, __MODULE__.FailingFormat, emit, conn: :collected)

      assert {:error, %Postgrex.Error{}} = result

      # Collect everything emitted before the failure.
      partial = drain_chunks()

      # The producer DID stream real bytes before failing (so the no-leak scan
      # below is non-vacuous) and they start with the gzip magic.
      assert byte_size(partial) > 0
      assert <<0x1F, 0x8B, _::binary>> = partial

      # (a) The consumer detects incompleteness: the bytes are NOT a valid archive
      # (no end-of-archive marker was written — fail-closed).
      assert {:error, _} = :erl_tar.extract({:binary, partial}, [:memory, :compressed])

      # (b) No internal text leaks into the partial bytes: no SQL keywords, no
      # vector literals, no Elixir stacktrace/module noise, no the raw error string.
      decompressed = gunzip_partial(partial)
      lower = String.downcase(decompressed)
      refute lower =~ "select "
      refute lower =~ "from articles"
      refute decompressed =~ "Postgrex"
      refute decompressed =~ "Elixir."
      refute decompressed =~ "stacktrace"
      refute decompressed =~ "embedding"
    end
  end

  describe "TC-27.16.3: fail-closed when a DB-style error hits the index build" do
    test "a connection error during the cheap index aggregate fails closed" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "X", body: "b", category: :pattern})

      emit = fn iodata ->
        send(self(), {:chunk, IO.iodata_to_binary(iodata)})
        {:ok, :collected}
      end

      # IndexFailingFormat raises a DBConnection.ConnectionError while building the
      # prelude index — the first thing the stream emits — exercising the
      # maybe_emit_index/6 rescue → fail-closed abort.
      assert {:error, %DBConnection.ConnectionError{}} =
               StreamingExport.stream(
                 tenant.id,
                 __MODULE__.IndexFailingFormat,
                 emit,
                 conn: :collected
               )

      # No valid archive was finalized: any emitted bytes are detectably incomplete.
      partial = drain_chunks()
      assert {:error, _} = :erl_tar.extract({:binary, partial}, [:memory, :compressed])
    end
  end

  describe "AC-27.16.3 (small): dense-hub link fan-out is bounded" do
    test "a hub article's Related section is capped at max_links_per_article" do
      tenant = fixture(:tenant)

      hub = published(tenant.id, %{title: "Hub", body: "hub body", category: :pattern})

      # Create more neighbors than the (test-config) cap of 5.
      for i <- 1..12 do
        target =
          published(tenant.id, %{title: "Neighbor #{i}", body: "n#{i}", category: :reference})

        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: hub.id,
          target_article_id: target.id,
          relationship_type: :relates_to
        })
      end

      {:ok, targz} = StreamingExportHelper.to_targz_binary(tenant.id, ObsidianFormat)
      {:ok, files} = StreamingExportHelper.extract(targz)
      hub_md = files["pattern/hub.md"]

      related_lines =
        hub_md
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "- [["))

      # Bounded by max_links_per_article/0 (5 in test config), NOT the 12 created.
      assert length(related_lines) <= StreamingExport.max_links_per_article()
      assert length(related_lines) == 5
    end
  end

  # --- helpers ---

  defp drain_chunks(acc \\ []) do
    receive do
      {:chunk, bin} -> drain_chunks([bin | acc])
    after
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  # Best-effort gunzip of the partial (truncated) gzip stream so we can scan the
  # PLAINTEXT for leaks. A truncated gzip won't fully inflate; inflate as much as
  # possible and scan that.
  defp gunzip_partial(partial) do
    z = :zlib.open()
    :zlib.inflateInit(z, 31)

    result =
      try do
        z |> :zlib.inflate(partial) |> IO.iodata_to_binary()
      rescue
        _ -> ""
      catch
        _, _ -> ""
      end

    :zlib.close(z)
    result
  end

  # A Format whose article_entries/2 raises a Postgrex.Error on the 4th article
  # (mid-stream, after at least one full keyset page of 3 has been emitted).
  defmodule FailingFormat do
    @behaviour Loopctl.Knowledge.StreamingExport.Format

    @impl true
    def index_position, do: :prelude

    @impl true
    def index_entries(_aggregate), do: [{"_index.md", "# index\n"}]

    @impl true
    def article_entries(article, _ctx) do
      # Use the title's trailing number as a deterministic counter.
      n =
        case Regex.run(~r/(\d+)$/, article.title) do
          [_, d] -> String.to_integer(d)
          _ -> 0
        end

      if n >= 4 do
        raise %Postgrex.Error{
          postgres: %{
            code: :query_canceled,
            pg_code: "57014",
            message: "canceling statement due to statement timeout",
            severity: "ERROR"
          }
        }
      end

      [{"pattern/doc-#{n}.md", "doc #{n} body"}]
    end
  end

  # A Format whose index_entries/1 raises a DBConnection.ConnectionError — exercises
  # the maybe_emit_index/6 rescue (a DB error on the FIRST thing the stream emits).
  defmodule IndexFailingFormat do
    @behaviour Loopctl.Knowledge.StreamingExport.Format

    @impl true
    def index_position, do: :prelude

    @impl true
    def index_entries(_aggregate) do
      raise %DBConnection.ConnectionError{message: "tcp recv: closed"}
    end

    @impl true
    def article_entries(_article, _ctx), do: []
  end
end
