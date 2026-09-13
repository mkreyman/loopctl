defmodule Loopctl.Delivery.GitHubPullRequestSourceTest do
  @moduledoc """
  `Loopctl.Delivery.GitHubPullRequestSource` against `Req.Test` bytes (issue #803).

  What is tested here is the RESPONSE MAPPING, because that is the part that decides
  whether a guarded path is SEEN: a status this module does not map, a rename with no old
  name, or a file list GitHub truncated would each turn a change to an effect path into a
  clean-looking diff. Every one of them is refused instead.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.GitHubPullRequestSource, as: Source

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
  @merge_base String.duplicate("b", 40)

  setup do
    Req.Test.set_req_test_from_context(%{async: true})
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "pull_request/2 — an open pull request" do
    test "returns the forge's own diffstat and a DiffNames-shaped diff" do
      stub(fn conn -> route(conn, files: default_files()) end)

      assert {:ok, pr} = Source.pull_request(@repo, 7)

      assert pr.state == "open"
      refute pr.merged?
      assert pr.head_sha == @head
      assert pr.merge_base_sha == @merge_base
      # The forge's totals, never `length(files)`.
      assert pr.diffstat == %{files: 4, changed_lines: 30}

      assert {:ok, %{files: files, renames: renames}} = pr.diff
      assert files == ["lib/a.ex", "lib/gone.ex", "lib/new.ex", "lib/copy.ex"]
      assert renames == [{"lib/old.ex", "lib/new.ex"}]
    end

    test "a DELETION is a touched path and a COPY contributes only its new name" do
      stub(fn conn -> route(conn, files: default_files()) end)

      assert {:ok, %{diff: {:ok, %{files: files}}}} = Source.pull_request(@repo, 7)

      assert "lib/gone.ex" in files
      assert "lib/copy.ex" in files
      refute "lib/source.ex" in files
    end
  end

  describe "pull_request/2 — what it refuses rather than approximating" do
    test "a status this module does not map is refused, `unchanged` included" do
      stub(fn conn ->
        route(conn,
          changed_files: 1,
          files: [%{"status" => "unchanged", "filename" => "lib/a.ex"}]
        )
      end)

      assert {:ok, %{diff: {:error, {:unrecognised_status, "unchanged"}}}} =
               Source.pull_request(@repo, 7)
    end

    test "a rename with no previous_filename is refused" do
      stub(fn conn ->
        route(conn,
          changed_files: 1,
          files: [%{"status" => "renamed", "filename" => "lib/new.ex"}]
        )
      end)

      assert {:ok, %{diff: {:error, {:rename_without_previous_filename, "lib/new.ex"}}}} =
               Source.pull_request(@repo, 7)
    end

    test "a file list beyond one page is refused rather than presented as the whole diff" do
      stub(fn conn -> route(conn, changed_files: 101, files: default_files()) end)

      assert {:ok, pr} = Source.pull_request(@repo, 7)
      assert pr.diff == {:error, {:file_list_truncated, 101}}
      # The diffstat is still the forge's, so the size bound judges the real change.
      assert pr.diffstat.files == 101
    end

    test "a file list SHORTER than the forge's own count is refused" do
      stub(fn conn -> route(conn, changed_files: 9, files: default_files()) end)

      assert {:ok, %{diff: {:error, {:file_list_short, 4, 9}}}} = Source.pull_request(@repo, 7)
    end

    test "a non-200 is an error, never an empty diff" do
      stub(fn conn -> Plug.Conn.resp(conn, 403, ~s({"message":"rate limited"})) end)

      assert {:error, {:github_api_error, 403}} = Source.pull_request(@repo, 7)
    end

    test "a body missing the fields it needs is an error naming only its SHAPE" do
      stub(fn conn -> json(conn, %{"state" => "open"}) end)

      assert {:error, {:unreadable_pull_request, {:map, ["state"]}}} =
               Source.pull_request(@repo, 7)
    end

    test "a repository name that is not owner/name never reaches the network" do
      assert {:error, {:invalid_repo, "../../etc"}} = Source.pull_request("../../etc", 7)
    end

    test "a non-positive pull request number never reaches the network" do
      assert {:error, {:invalid_pr_number, 0}} = Source.pull_request(@repo, 0)
    end

    test "a head sha the forge reports is VALIDATED before it is spliced into a URL" do
      # The head is remote data like every other field, and it goes into a URL PATH.
      stub(fn conn ->
        case conn.request_path do
          "/repos/acme/widgets/pulls/7" ->
            json(conn, %{
              "state" => "open",
              "merged" => false,
              "merge_commit_sha" => nil,
              "head" => %{"sha" => "abc?ref=../../other"},
              "base" => %{"ref" => "master"},
              "changed_files" => 1,
              "additions" => 1,
              "deletions" => 0
            })

          other ->
            flunk("an unvalidated head must not reach the network: #{other}")
        end
      end)

      assert {:error, {:invalid_ref, "abc?ref=../../other"}} = Source.pull_request(@repo, 7)
    end

    test "a REDIRECT is not followed — a renamed repository is not the configured one" do
      # Req follows redirects by default, so a transferred repository would be read under
      # its new name while the trigger list stays keyed to the configured one.
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "https://api.github.com/repos/other/repo/pulls/7"
        )
        |> Plug.Conn.resp(301, "")
      end)

      assert {:error, {:github_api_error, 301}} = Source.pull_request(@repo, 7)
    end
  end

  describe "pull_request/2 — an already-merged pull request" do
    test "is answered with its merge sha, without reading a diff or a merge base" do
      merge_sha = String.duplicate("c", 40)

      stub(fn conn ->
        case conn.request_path do
          "/repos/acme/widgets/pulls/7" ->
            json(conn, pull_request_body(merged: true, merge_commit_sha: merge_sha))

          other ->
            flunk("a merged pull request should not have been read further: #{other}")
        end
      end)

      assert {:ok, pr} = Source.pull_request(@repo, 7)
      assert pr.merged?
      assert pr.merge_sha == merge_sha
      assert pr.merge_base_sha == pr.head_sha
      assert pr.diff == {:ok, %{files: [], renames: []}}
    end

    test "a null merge_commit_sha on a merged pull request yields nil, not a bad sha" do
      stub(fn conn -> json(conn, pull_request_body(merged: true, merge_commit_sha: nil)) end)

      assert {:ok, %{merged?: true, merge_sha: nil}} = Source.pull_request(@repo, 7)
    end
  end

  describe "repo_files/2" do
    test "returns every blob path and ignores trees" do
      stub(fn conn ->
        json(conn, %{
          "truncated" => false,
          "tree" => [
            %{"type" => "blob", "path" => "lib/a.ex"},
            %{"type" => "tree", "path" => "lib"},
            %{"type" => "blob", "path" => "priv/rates/2026.csv"}
          ]
        })
      end)

      assert {:ok, ["lib/a.ex", "priv/rates/2026.csv"]} = Source.repo_files(@repo, @head)
    end

    test "a TRUNCATED tree is refused — an incomplete list would hide a stale trigger" do
      stub(fn conn -> json(conn, %{"truncated" => true, "tree" => []}) end)

      assert {:error, {:tree_truncated, @head}} = Source.repo_files(@repo, @head)
    end

    test "a ref that could change which resource is addressed never reaches the network" do
      assert {:error, {:invalid_ref, "main?recursive=0"}} =
               Source.repo_files(@repo, "main?recursive=0")

      assert {:error, {:invalid_ref, "refs/../../heads/main"}} =
               Source.repo_files(@repo, "refs/../../heads/main")
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp stub(fun), do: Req.Test.stub(Source, fun)

  defp route(conn, opts) do
    case conn.request_path do
      "/repos/acme/widgets/pulls/7" ->
        json(conn, pull_request_body(changed_files: Keyword.get(opts, :changed_files, 4)))

      "/repos/acme/widgets/compare/" <> _rest ->
        json(conn, %{"merge_base_commit" => %{"sha" => @merge_base}})

      "/repos/acme/widgets/pulls/7/files" ->
        json(conn, Keyword.fetch!(opts, :files))

      other ->
        flunk("unexpected request path: #{other}")
    end
  end

  defp pull_request_body(opts) do
    %{
      "state" => Keyword.get(opts, :state, "open"),
      "merged" => Keyword.get(opts, :merged, false),
      "merge_commit_sha" => Keyword.get(opts, :merge_commit_sha),
      "head" => %{"sha" => @head},
      "base" => %{"ref" => "master"},
      "changed_files" => Keyword.get(opts, :changed_files, 4),
      "additions" => 20,
      "deletions" => 10
    }
  end

  defp default_files do
    [
      %{"status" => "modified", "filename" => "lib/a.ex"},
      %{"status" => "removed", "filename" => "lib/gone.ex"},
      %{"status" => "renamed", "filename" => "lib/new.ex", "previous_filename" => "lib/old.ex"},
      %{"status" => "copied", "filename" => "lib/copy.ex", "previous_filename" => "lib/source.ex"}
    ]
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
