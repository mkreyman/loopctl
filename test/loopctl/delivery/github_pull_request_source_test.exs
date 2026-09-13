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
      stub(fn conn -> Plug.Conn.resp(conn, 500, ~s({"message":"boom"})) end)

      assert {:error, {:github_api_error, 500}} = Source.pull_request(@repo, 7)
    end

    test "a 403 with NO rate-limit headers is a permission denial, not a rate limit" do
      # "Resource not accessible by personal access token" — a fine-grained token missing a
      # scope. It never clears, so it must not be reported as something to retry.
      stub(fn conn ->
        Plug.Conn.resp(conn, 403, ~s({"message":"Resource not accessible by token"}))
      end)

      assert {:error, {:github_api_error, 403}} = Source.pull_request(@repo, 7)
    end

    test "a 403 with an exhausted rate limit IS a rate limit" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.resp(403, ~s({"message":"API rate limit exceeded"}))
      end)

      assert {:error, {:github_rate_limited, 403, nil}} = Source.pull_request(@repo, 7)
    end

    test "a 403 with a retry-after IS a rate limit, and the delay is carried" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "60")
        |> Plug.Conn.resp(403, ~s({"message":"secondary rate limit"}))
      end)

      assert {:error, {:github_rate_limited, 403, 60}} = Source.pull_request(@repo, 7)
    end

    test "a 429 is a rate limit whatever its headers say" do
      stub(fn conn -> Plug.Conn.resp(conn, 429, "") end)

      assert {:error, {:github_rate_limited, 429, nil}} = Source.pull_request(@repo, 7)
    end

    test "an HTTP-date retry-after is a rate limit — PRESENCE decides the class" do
      # No `x-ratelimit-remaining`, so the header itself is the only signal. An HTTP-date is
      # legal; refusing to parse it into a number must not turn "come back later" into a
      # permanent permission denial that escalates the story at once.
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "Wed, 21 Oct 2026 07:28:00 GMT")
        |> Plug.Conn.resp(403, "")
      end)

      assert {:error, {:github_rate_limited, 403, nil}} = Source.pull_request(@repo, 7)
    end

    test "a NEGATIVE or unparseable retry-after is still a rate limit, with no delay" do
      for value <- ["-5", "soon", ""] do
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", value)
          |> Plug.Conn.resp(403, "")
        end)

        assert {:error, {:github_rate_limited, 403, nil}} = Source.pull_request(@repo, 7)
      end
    end

    test "a PRIMARY limit's delay comes from x-ratelimit-reset, not from a caller's floor" do
      # The anonymous-quota case: an hourly window, and no `retry-after` at all. Without
      # this the caller waits its floor (seconds) against a window of up to an hour, and the
      # consecutive-unevaluated bound escalates the very fault that was going to clear.
      reset = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(1_800)

      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(reset))
        |> Plug.Conn.resp(403, ~s({"message":"API rate limit exceeded"}))
      end)

      assert {:error, {:github_rate_limited, 403, seconds}} = Source.pull_request(@repo, 7)
      assert_in_delta seconds, 1_800, 5
    end

    test "a retry-after that parses WINS over the reset — it is about this request" do
      reset = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(1_800)

      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "45")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(reset))
        |> Plug.Conn.resp(403, "")
      end)

      assert {:error, {:github_rate_limited, 403, 45}} = Source.pull_request(@repo, 7)
    end

    test "a reset in the PAST, or absurdly far ahead, yields no delay" do
      past = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      far = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(86_400)

      for value <- [past, far] do
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
          |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(value))
          |> Plug.Conn.resp(403, "")
        end)

        assert {:error, {:github_rate_limited, 403, nil}} = Source.pull_request(@repo, 7)
      end
    end

    test "x-ratelimit-reset alone does NOT make a permission denial a rate limit" do
      # It rides on ordinary responses too, so its presence says nothing about why THIS one
      # failed. Only remaining-zero or a retry-after classify.
      reset = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(1_800)

      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "4998")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(reset))
        |> Plug.Conn.resp(403, ~s({"message":"Resource not accessible by token"}))
      end)

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

  describe "latest_deployment/2 — the DEPLOYMENT, never a workflow run" do
    test "reads the newest deployment of the environment and its latest state" do
      # Design §9: the deployment's own `sha` is what the deploying job recorded. The
      # workflow run's head is what GitHub ATTRIBUTED, and the two diverge whenever two
      # merges land minutes apart.
      stub(fn conn ->
        case {conn.request_path, conn.query_string} do
          {"/repos/acme/widgets/deployments", "environment=production&per_page=1"} ->
            json(conn, [%{"id" => 501, "sha" => @head}])

          {"/repos/acme/widgets/deployments/501/statuses", "per_page=1"} ->
            json(conn, [%{"state" => "success"}])

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert {:ok, %{id: 501, sha: @head, state: :success}} =
               Source.latest_deployment(@repo, "production")
    end

    test "an environment with no deployments is a FACT, not a failure" do
      # The verifier fails closed on it — it cannot tell what is running — but calling it an
      # error would put it in the transient/permanent classification, where it does not
      # belong: it is not going to clear on a retry, and it is not a contract change either.
      stub(fn conn -> json(conn, []) end)

      assert {:ok, nil} = Source.latest_deployment(@repo, "staging")
    end

    for {state, mapped} <- [
          {"failure", :failure},
          {"error", :error},
          {"inactive", :inactive},
          {"queued", :pending},
          {"pending", :pending},
          {"in_progress", :pending}
        ] do
      test "a #{state} status maps to #{inspect(mapped)}" do
        stub(&deployment_route(&1, [%{"state" => unquote(state)}]))

        assert {:ok, %{state: unquote(mapped)}} = Source.latest_deployment(@repo, "production")
      end
    end

    test "a deployment with NO status has not settled, which is not a failure" do
      stub(&deployment_route(&1, []))

      assert {:ok, %{state: :pending}} = Source.latest_deployment(@repo, "production")
    end

    test "a state this module does not map is refused, never approximated to success" do
      stub(&deployment_route(&1, [%{"state" => "abandoned"}]))

      assert {:error, {:unrecognised_deployment_state, "abandoned"}} =
               Source.latest_deployment(@repo, "production")
    end

    test "a deployment list this module cannot read is refused" do
      stub(fn conn -> json(conn, %{"message" => "Not Found"}) end)

      assert {:error, {:unreadable_deployments, {:map, ["message"]}}} =
               Source.latest_deployment(@repo, "production")
    end

    test "an environment name that could change the request is refused before it is sent" do
      # It is spliced into a QUERY parameter, so the same rule as a ref: nothing that could
      # add a parameter of its own or address a different resource.
      stub(fn conn -> flunk("must not reach the forge: #{conn.request_path}") end)

      assert {:error, {:invalid_environment, "prod&per_page=100"}} =
               Source.latest_deployment(@repo, "prod&per_page=100")

      assert {:error, {:invalid_environment, nil}} = Source.latest_deployment(@repo, nil)

      assert {:error, {:invalid_environment, :unreadable}} =
               Source.latest_deployment(@repo, 42.0)
    end
  end

  describe "contains?/3 — containment, which is why verification is not sha equality" do
    for {status, contained} <- [
          {"identical", true},
          {"ahead", true},
          {"behind", false},
          {"diverged", false}
        ] do
      test "a #{status} comparison means contained=#{contained}" do
        # `compare/<sha>...<ref>` describes the HEAD relative to the BASE, so `ahead` is
        # `ref` ahead of `sha` — i.e. `sha` is an ancestor of it, and the merge shipped.
        stub(fn conn ->
          assert conn.request_path == "/repos/acme/widgets/compare/#{@head}...#{@merge_base}"
          json(conn, %{"status" => unquote(status)})
        end)

        assert {:ok, unquote(contained)} = Source.contains?(@repo, @head, @merge_base)
      end
    end

    test "a status this module does not recognise is refused" do
      stub(fn conn -> json(conn, %{"status" => "sideways"}) end)

      assert {:error, {:unrecognised_compare_status, "sideways"}} =
               Source.contains?(@repo, @head, @merge_base)
    end

    test "a body with no status is refused, never read as containment" do
      stub(fn conn -> json(conn, %{"commits" => []}) end)

      assert {:error, {:unreadable_compare, {:map, ["commits"]}}} =
               Source.contains?(@repo, @head, @merge_base)
    end

    test "both refs are validated: either one is spliced into the URL path" do
      stub(fn conn -> flunk("must not reach the forge: #{conn.request_path}") end)

      assert {:error, {:invalid_ref, "a?b"}} = Source.contains?(@repo, "a?b", @merge_base)
      assert {:error, {:invalid_ref, "a#b"}} = Source.contains?(@repo, @head, "a#b")
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp stub(fun), do: Req.Test.stub(Source, fun)

  defp deployment_route(conn, statuses) do
    case conn.request_path do
      "/repos/acme/widgets/deployments" -> json(conn, [%{"id" => 501, "sha" => @head}])
      "/repos/acme/widgets/deployments/501/statuses" -> json(conn, statuses)
      other -> flunk("unexpected request path: #{other}")
    end
  end

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
