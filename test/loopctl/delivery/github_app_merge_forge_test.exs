defmodule Loopctl.Delivery.GitHubAppMergeForgeTest do
  @moduledoc """
  `Loopctl.Delivery.GitHubAppMergeForge` against `Req.Test` bytes (US-45.5): the requests the
  App makes and the answers the executor decides on — a refused fast-forward, a conflicting
  base merge, a commit GitHub does not have. And the App JWT, checked against the key's public
  half rather than trusted.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.GitHubAppMergeForge, as: Forge

  @repo "acme/widgets"
  @session %{repo: @repo, token: "ghs_installation"}
  @a String.duplicate("a", 40)
  @b String.duplicate("b", 40)
  @t String.duplicate("e", 40)

  setup do
    Req.Test.set_req_test_from_context(%{async: true})
    Req.Test.verify_on_exit!()
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Forge, fun)

  defp json(conn, status, body), do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp body(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(raw)
  end

  test "the App JWT is RS256 over its claims, verifiable with the public key" do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:ok, decoded} = Forge.private_key(pem)
    jwt = Forge.app_jwt("12345", decoded, 1_000_000)

    [header, claims, signature] = String.split(jwt, ".")
    assert %{"alg" => "RS256"} = header |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert %{"iss" => "12345", "iat" => 999_940, "exp" => 1_000_540} =
             claims |> Base.url_decode64!(padding: false) |> Jason.decode!()

    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}

    assert :public_key.verify(
             header <> "." <> claims,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             public
           )

    assert {:error, :app_private_key_invalid} = Forge.private_key("not a key")
  end

  test "update_ref moves the branch with force false; a refused fast-forward is its own answer" do
    stub(fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/acme/widgets/git/refs/heads/master"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghs_installation"]
      assert body(conn) == %{"sha" => @a, "force" => false}
      json(conn, 200, %{"ref" => "refs/heads/master"})
    end)

    assert :ok = Forge.update_ref(@session, "master", @a)

    stub(fn conn -> json(conn, 422, %{"message" => "Update is not a fast forward"}) end)
    assert {:error, :not_fast_forward} = Forge.update_ref(@session, "master", @a)

    # A ruleset refusing the update is a configuration fault, never the swap losing.
    stub(fn conn -> json(conn, 422, %{"message" => "Repository rule violations found"}) end)
    assert {:error, {:github_api_error, 422}} = Forge.update_ref(@session, "master", @a)
  end

  test "merge answers the merge commit, up to date, or a conflict" do
    stub(fn conn ->
      assert conn.request_path == "/repos/acme/widgets/merges"
      assert %{"base" => "loop/x", "head" => "master"} = body(conn)

      json(conn, 201, %{
        "sha" => @b,
        "commit" => %{"tree" => %{"sha" => @t}},
        "parents" => [%{"sha" => @a}, %{"sha" => @t}]
      })
    end)

    assert {:ok, %{sha: @b, tree_sha: @t, parents: [@a, @t]}} =
             Forge.merge(@session, "loop/x", "master", "m")

    stub(fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    assert {:ok, :up_to_date} = Forge.merge(@session, "loop/x", "master", "m")

    stub(fn conn -> json(conn, 409, %{"message" => "Merge conflict"}) end)
    assert {:error, :merge_conflict} = Forge.merge(@session, "loop/x", "master", "m")
  end

  test "ancestor? reads the compare status; a commit GitHub does not have is no ancestor" do
    stub(fn conn ->
      assert conn.request_path == "/repos/acme/widgets/compare/#{@a}...#{@b}"
      json(conn, 200, %{"status" => "ahead"})
    end)

    assert {:ok, true} = Forge.ancestor?(@session, @a, @b)

    stub(fn conn -> json(conn, 200, %{"status" => "diverged"}) end)
    assert {:ok, false} = Forge.ancestor?(@session, @a, @b)

    stub(fn conn -> json(conn, 404, %{"message" => "Not Found"}) end)
    assert {:ok, false} = Forge.ancestor?(@session, @a, @b)

    stub(fn conn -> json(conn, 502, %{}) end)
    assert {:error, {:github_api_error, 502}} = Forge.ancestor?(@session, @a, @b)
  end

  test "create_commit posts the tree, the parents and the message, and moves no ref" do
    stub(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/acme/widgets/git/commits"
      assert body(conn) == %{"tree" => @t, "parents" => [@a], "message" => "msg"}
      json(conn, 201, %{"sha" => @b})
    end)

    assert {:ok, @b} = Forge.create_commit(@session, %{tree: @t, parents: [@a], message: "msg"})
  end

  test "a ref or sha that would change the addressed resource never reaches the forge" do
    assert {:error, {:invalid_ref, _}} = Forge.branch_head(@session, "../x")
    assert {:error, {:invalid_sha, _}} = Forge.commit(@session, "HEAD?x")
  end
end
