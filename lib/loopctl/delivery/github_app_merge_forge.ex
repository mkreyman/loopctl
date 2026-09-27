defmodule Loopctl.Delivery.GitHubAppMergeForge do
  @moduledoc """
  `Loopctl.Delivery.MergeForge` over GitHub's REST API, as loopctl's GitHub App (US-45.5,
  Epic 45 PRD §4).

  ## Authentication

  `GITHUB_APP_ID` and `GITHUB_APP_PRIVATE_KEY` (the App's PEM private key; a value with
  literal `\\n` escapes is accepted, since a secret store may flatten newlines). Either one
  unset or blank is `{:error, :app_unconfigured}`, with no request made. A key that does not
  decode as an RSA private key is `{:error, :app_private_key_invalid}`.

  A session is minted per executor run: an App JWT (RS256, signed with `:public_key`, valid
  nine minutes and back-dated one against clock skew), then `GET /repos/:repo/installation`
  and `POST /app/installations/:id/access_tokens`, asking for a token scoped to that ONE
  repository with `contents: write` and nothing else. A token lives an hour and a run takes
  seconds, so nothing is cached: a cached token is one more thing that can be stale.

  ## Bounds

  The same as `Loopctl.Delivery.GitHubPullRequestSource`: a 2 s connect and 5 s receive
  timeout, `retry: false` (a retry the HTTP client makes underneath the executor is a WRITE
  the executor's idempotency record cannot see) and `redirect: false`. Failures are
  classified by that module's `classify_failure/1`, so a rate limit is transient and a bare
  403 a permission fault here exactly as there.
  """

  @behaviour Loopctl.Delivery.MergeForge

  alias Loopctl.Delivery.GitHubPullRequestSource

  @api_base "https://api.github.com"
  @connect_timeout_ms 2_000
  @receive_timeout_ms 5_000

  # The App JWT: GitHub caps its life at ten minutes and rejects an `iat` in the future.
  @jwt_backdate_seconds 60
  @jwt_lifetime_seconds 540

  @repo_name ~r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
  @ref ~r{\A[A-Za-z0-9_./-]+\z}
  @sha ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @impl true
  def session(repo) do
    with {:ok, repo} <- repo_name(repo),
         {:ok, app_id, pem} <- credentials(),
         {:ok, key} <- private_key(pem) do
      jwt = app_jwt(app_id, key, System.system_time(:second))

      with {:ok, %{"id" => id}} when is_integer(id) <-
             request(:get, "/repos/#{repo}/installation", bearer(jwt)),
           {:ok, %{"token" => token}} when is_binary(token) <-
             request(:post, "/app/installations/#{id}/access_tokens", bearer(jwt),
               json: %{
                 repositories: [repo |> String.split("/") |> List.last()],
                 permissions: %{contents: "write"}
               }
             ) do
        {:ok, %{repo: repo, token: token}}
      else
        {:ok, body} -> {:error, {:unreadable_installation, shape(body)}}
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  def branch_head(session, branch) do
    with {:ok, branch} <- ref(branch),
         {:ok, body} <- repo_request(session, :get, "/git/ref/heads/#{branch}") do
      case body do
        %{"object" => %{"sha" => sha}} when is_binary(sha) -> {:ok, sha}
        other -> {:error, {:unreadable_ref, shape(other)}}
      end
    end
  end

  @impl true
  def commit(session, sha) do
    with {:ok, sha} <- sha(sha),
         {:ok, body} <- repo_request(session, :get, "/git/commits/#{sha}") do
      commit_of(body)
    end
  end

  @impl true
  def ancestor?(session, ancestor, descendant) do
    with {:ok, ancestor} <- sha(ancestor),
         {:ok, descendant} <- sha(descendant) do
      case repo_request(session, :get, "/compare/#{ancestor}...#{descendant}") do
        {:ok, %{"status" => status}} when status in ~w(identical ahead) -> {:ok, true}
        {:ok, %{"status" => status}} when status in ~w(behind diverged) -> {:ok, false}
        {:ok, body} -> {:error, {:unreadable_compare, shape(body)}}
        # A commit GitHub does not have is an ancestor of nothing.
        {:error, {:github_api_error, 404}} -> {:ok, false}
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  def create_commit(session, %{tree: tree, parents: parents, message: message}) do
    with {:ok, tree} <- sha(tree),
         {:ok, parents} <- shas(parents),
         {:ok, body} <-
           repo_request(session, :post, "/git/commits",
             json: %{message: message, tree: tree, parents: parents}
           ) do
      case body do
        %{"sha" => sha} when is_binary(sha) -> {:ok, sha}
        other -> {:error, {:unreadable_commit, shape(other)}}
      end
    end
  end

  @impl true
  def update_ref(session, branch, sha) do
    with {:ok, branch} <- ref(branch),
         {:ok, sha} <- sha(sha) do
      case repo_request(session, :patch, "/git/refs/heads/#{branch}",
             json: %{sha: sha, force: false}
           ) do
        {:ok, _body} -> :ok
        {:error, {:unprocessable, message}} -> unprocessable_ref(message)
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  def merge(session, base, head, message) do
    with {:ok, base} <- ref(base),
         {:ok, head} <- ref(head) do
      case repo_request(session, :post, "/merges",
             json: %{base: base, head: head, commit_message: message}
           ) do
        {:ok, :no_content} -> {:ok, :up_to_date}
        {:ok, body} -> commit_of(body)
        {:error, {:github_api_error, 409}} -> {:error, :merge_conflict}
        {:error, {:unprocessable, _message}} -> {:error, {:github_api_error, 422}}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc false
  # The App JWT, pure so its signature can be checked against the public key in a test.
  @spec app_jwt(String.t(), term(), integer()) :: String.t()
  def app_jwt(app_id, key, now) do
    header = encode(%{"alg" => "RS256", "typ" => "JWT"})

    claims =
      encode(%{
        "iat" => now - @jwt_backdate_seconds,
        "exp" => now + @jwt_lifetime_seconds,
        "iss" => app_id
      })

    input = header <> "." <> claims
    input <> "." <> Base.url_encode64(:public_key.sign(input, :sha256, key), padding: false)
  end

  @doc false
  # The PEM decoded to an RSA private key: PKCS#1 (what GitHub issues) or PKCS#8.
  @spec private_key(String.t()) :: {:ok, term()} | {:error, :app_private_key_invalid}
  def private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> rsa_key(:public_key.pem_entry_decode(entry))
      [] -> {:error, :app_private_key_invalid}
    end
  rescue
    _error -> {:error, :app_private_key_invalid}
  end

  defp rsa_key(key) when is_tuple(key) and elem(key, 0) == :RSAPrivateKey, do: {:ok, key}
  defp rsa_key(_other), do: {:error, :app_private_key_invalid}

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp credentials do
    case {blank_to_nil(System.get_env("GITHUB_APP_ID")),
          blank_to_nil(System.get_env("GITHUB_APP_PRIVATE_KEY"))} do
      {app_id, pem} when is_binary(app_id) and is_binary(pem) ->
        {:ok, app_id, String.replace(pem, "\\n", "\n")}

      _unset ->
        {:error, :app_unconfigured}
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # GitHub answers 422 to a non-fast-forward ref update ("Update is not a fast forward") and
  # to a ruleset refusing it. Only the first is the compare-and-swap losing; the second is a
  # configuration fault for a human, so it keeps an error shape the executor escalates.
  defp unprocessable_ref(message) do
    if is_binary(message) and Regex.match?(~r/fast[- ]forward/i, message),
      do: {:error, :not_fast_forward},
      else: {:error, {:github_api_error, 422}}
  end

  # The Git Data API's commit (`tree.sha`, `parents[].sha`) and the REST commit the merges
  # endpoint returns (`commit.tree.sha`) both reach one shape.
  defp commit_of(%{"sha" => sha, "parents" => parents} = body)
       when is_binary(sha) and is_list(parents) do
    tree = get_in(body, ["tree", "sha"]) || get_in(body, ["commit", "tree", "sha"])
    parent_shas = for %{"sha" => parent} <- parents, is_binary(parent), do: parent

    if is_binary(tree) and length(parent_shas) == length(parents),
      do: {:ok, %{sha: sha, tree_sha: tree, parents: parent_shas}},
      else: {:error, {:unreadable_commit, shape(body)}}
  end

  defp commit_of(body), do: {:error, {:unreadable_commit, shape(body)}}

  defp repo_request(%{repo: repo, token: token}, verb, path, opts \\ []),
    do: request(verb, "/repos/#{repo}" <> path, bearer(token), opts)

  defp request(verb, path, auth, opts \\ []) do
    options = Keyword.merge(req_options(auth), opts)

    case Req.request([method: verb, url: @api_base <> path] ++ options) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: 204}} ->
        {:ok, :no_content}

      {:ok, %Req.Response{status: 422, body: body}} ->
        {:error, {:unprocessable, message(body)}}

      {:ok, %Req.Response{} = response} ->
        {:error, GitHubPullRequestSource.classify_failure(response)}

      {:error, reason} ->
        {:error, {:github_unreachable, shape(reason)}}
    end
  end

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(_body), do: nil

  defp req_options(auth) do
    maybe_add_plug(
      headers: [
        auth,
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "loopctl-merge-executor"}
      ],
      retry: false,
      redirect: false,
      receive_timeout: @receive_timeout_ms,
      connect_options: [timeout: @connect_timeout_ms]
    )
  end

  defp bearer(token), do: {"authorization", "Bearer " <> token}

  # The `Req.Test` seam, as `GitHubPullRequestSource` has one.
  defp maybe_add_plug(opts) do
    case Application.get_env(:loopctl, :delivery_merge_forge_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  defp repo_name(repo) when is_binary(repo) do
    if Regex.match?(@repo_name, repo), do: {:ok, repo}, else: {:error, {:invalid_repo, repo}}
  end

  defp repo_name(repo), do: {:error, {:invalid_repo, shape(repo)}}

  # Interpolated into a URL path, so it may carry nothing that changes which resource is
  # addressed: no `?`, no `#`, no `..` segment, no percent escape.
  defp ref(ref) when is_binary(ref) do
    if Regex.match?(@ref, ref) and ".." not in String.split(ref, "/"),
      do: {:ok, ref},
      else: {:error, {:invalid_ref, shape(ref)}}
  end

  defp ref(ref), do: {:error, {:invalid_ref, shape(ref)}}

  defp sha(sha) when is_binary(sha) do
    if Regex.match?(@sha, sha), do: {:ok, sha}, else: {:error, {:invalid_sha, shape(sha)}}
  end

  defp sha(sha), do: {:error, {:invalid_sha, shape(sha)}}

  defp shas(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case sha(value) do
        {:ok, sha} -> {:cont, {:ok, acc ++ [sha]}}
        error -> {:halt, error}
      end
    end)
  end

  # A forge response is remote data: only its SHAPE is echoed into a reason.
  defp shape(%module{}), do: module
  defp shape(value) when is_map(value), do: {:map, value |> Map.keys() |> Enum.sort()}
  defp shape(value) when is_list(value), do: {:list, length(value)}
  defp shape(value) when is_atom(value), do: value
  defp shape(_value), do: :unreadable
end
