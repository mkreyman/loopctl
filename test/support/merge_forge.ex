defmodule Loopctl.Test.MergeForge do
  @moduledoc """
  The forge a merge-precondition test stands up: one repository's commits, and the
  `Loopctl.MockMergeForge` stubs that answer for them.

  Shared by `Loopctl.Delivery.MergePreconditionIntegrationTest` (sandboxed) and
  `Loopctl.Delivery.MergePreconditionLockTest` (committed, for a lock another session holds),
  so the two judge the same forge. A test module binds the shas below to its own attributes
  (`@head MergeForge.head()`) to match on them, and overrides a stub for what it is about.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Loopctl.Delivery.Stages
  alias Loopctl.MockMergeForge

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
  @tree String.duplicate("e", 40)
  @base_tree String.duplicate("f", 40)
  # The comparison's merge base: what the judged three-dot diff is relative to, and so the
  # `base_sha` an allow records.
  @base_head String.duplicate("8", 40)
  @merge String.duplicate("c", 40)
  @session %{repo: @repo, token: "ghs_test"}

  def repo, do: @repo
  def head, do: @head
  def tree, do: @tree
  def base_tree, do: @base_tree
  def base_head, do: @base_head
  def merge, do: @merge
  def session, do: @session

  @doc """
  The forge as the executor sees it on the happy path: the base head is the allow's
  `base_sha`, the thread branch names the checkpoint, the checkpoint contains the base, and
  every write succeeds.
  """
  def stub_forge(branch) do
    Mox.stub(MockMergeForge, :session, fn @repo -> {:ok, @session} end)
    stub_base_head(@base_head, branch)

    Mox.stub(MockMergeForge, :commit, fn
      @session, @head -> {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}
      @session, sha -> {:ok, %{sha: sha, tree_sha: @base_tree, parents: []}}
    end)

    stub_ancestors(%{{@base_head, @head} => true})
    Mox.stub(MockMergeForge, :create_commit, fn @session, _commit -> {:ok, @merge} end)
    Mox.stub(MockMergeForge, :update_ref, fn @session, "master", _sha -> :ok end)
    Mox.stub(MockMergeForge, :create_ref, fn @session, _temp, @head -> :ok end)
    Mox.stub(MockMergeForge, :delete_ref, fn @session, _temp -> :ok end)
    Mox.stub(MockMergeForge, :merge, &unexpected_merge/4)
  end

  @doc """
  The App unreachable. Every recorded thread allow enqueues the merge executor (US-45.5), and
  Oban runs it INLINE in test, so a test that judges the GATE gives the executor a transient
  fault, which it answers by retrying later and which changes nothing now.
  """
  def stub_app_unreachable do
    Mox.stub(MockMergeForge, :session, fn _repo ->
      {:error, {:github_unreachable, :econnrefused}}
    end)
  end

  @doc "`branch_head/2`: `master` at `base_head`, the thread branch (or any, when nil) at the head."
  def stub_base_head(base_head, branch \\ nil) do
    Mox.stub(MockMergeForge, :branch_head, fn
      @session, "master" -> {:ok, base_head}
      @session, thread when thread == branch or is_nil(branch) -> {:ok, @head}
    end)
  end

  @doc "`ancestor?/3` answers from `known`, false for any pair it does not name."
  def stub_ancestors(known) do
    Mox.stub(MockMergeForge, :ancestor?, fn @session, ancestor, descendant ->
      {:ok, Map.get(known, {ancestor, descendant}, false)}
    end)
  end

  @doc """
  A recorded thread-mode allow for `checkpoint` at `sha`, exactly as the gate records one: the
  row's allow and the event naming the checkpoint and the merge base.
  """
  def record_thread_allow(%{tenant_id: tenant_id, story_id: story_id}, checkpoint, sha) do
    {:ok, _row} =
      Stages.record_effect(tenant_id, story_id, :merge_gate_allowed_sha, sha,
        claim_epoch: 0,
        event_data: %{
          "checkpoint_id" => checkpoint.id,
          "checkpoint_sha" => sha,
          "base_sha" => @base_head
        }
      )
  end

  @spec unexpected_merge(term(), term(), term(), term()) :: no_return()
  defp unexpected_merge(_session, _base, _head, _message), do: flunk("no base merge expected")
end
