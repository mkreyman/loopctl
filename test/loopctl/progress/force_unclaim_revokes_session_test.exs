defmodule Loopctl.Progress.ForceUnclaimRevokesSessionTest do
  @moduledoc """
  Taking a story back kills the credential the previous holder had.

  `Placement.place/4` mints a per-story session dispatch (`story_id` set) and an
  ephemeral key with it. When the session ends abnormally the key is still
  `revoked_at IS NULL`, so it OCCUPIES the runner agent's slot in
  `api_keys_one_role_per_agent_idx` for its whole TTL, and every later placement onto
  that agent is refused 422 `agent already has an active key with this role`. The index
  cannot test expiry (a partial-index predicate must be IMMUTABLE; `now()` is STABLE),
  so only a revoke frees it before the TTL.

  Two halves, and BOTH are load-bearing:

    * the revoke is SCOPED to a dispatch minted FOR this story. `Dispatches.revoke/2`
      cascades to descendants, so revoking a general agent dispatch that merely claimed
      the story would kill that agent's whole subtree — every other story it holds — as
      a side effect of parking ONE. Force-unclaim is a routine compensation
      (`Placement.undo_claim/5` runs it on every placement refusal), so that blast
      radius would be paid constantly.
    * `implementer_dispatch_id` is NOT cleared. It is custody provenance;
      `Progress`'s lineage lookups resolve a REVOKED dispatch row exactly as they
      resolve a live one, so no L4 comparison changes.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  # A claimed story whose `implementer_dispatch_id` is a dispatch minted FOR it — the
  # shape `Placement.mint_session_dispatch/5` produces.
  defp story_with_session_dispatch(dispatch_attrs \\ %{}) do
    agent = fixture(:agent, %{agent_type: :implementer})
    tenant_id = agent.tenant_id
    story = fixture(:story, %{tenant_id: tenant_id, agent_status: :contracted})

    attrs =
      Map.merge(%{role: :agent, agent_id: agent.id, story_id: story.id}, dispatch_attrs)

    {:ok, %{dispatch: dispatch}} = Dispatches.create_dispatch(tenant_id, attrs)

    {:ok, claimed} =
      Progress.claim_story(tenant_id, story.id, agent_id: agent.id, dispatch_id: dispatch.id)

    %{tenant_id: tenant_id, agent: agent, story: claimed, dispatch: dispatch}
  end

  defp reload_dispatch(id), do: AdminRepo.get!(Dispatch, id)
  defp reload_story(id), do: AdminRepo.get!(Story, id)

  defp key_for(dispatch) do
    AdminRepo.get!(ApiKey, reload_dispatch(dispatch.id).api_key_id)
  end

  describe "force_unclaim_story/3 revokes this story's session credential" do
    test "the session dispatch and its ephemeral key are both revoked" do
      %{tenant_id: tenant_id, story: story, dispatch: dispatch} = story_with_session_dispatch()

      refute reload_dispatch(dispatch.id).revoked_at
      refute key_for(dispatch).revoked_at

      {:ok, _released} = Progress.force_unclaim_story(tenant_id, story.id)

      assert reload_dispatch(dispatch.id).revoked_at,
             "the session dispatch must be revoked when the story is taken back"

      assert key_for(dispatch).revoked_at,
             "the ephemeral key is what holds the one-key-per-role slot — revoking the " <>
               "dispatch alone would leave the slot occupied"
    end

    test "the freed slot is the point: the agent can be dispatched again immediately" do
      # Asserted as the behaviour the delivery loop sees rather than as a column. A
      # `revoked_at` assertion alone stays green if the index predicate ever stops
      # matching what the revoke writes.
      %{tenant_id: tenant_id, agent: agent, story: story} = story_with_session_dispatch()

      assert {:error, _} =
               Dispatches.create_dispatch(tenant_id, %{role: :agent, agent_id: agent.id})

      {:ok, _released} = Progress.force_unclaim_story(tenant_id, story.id)

      assert {:ok, %{dispatch: %Dispatch{}}} =
               Dispatches.create_dispatch(tenant_id, %{role: :agent, agent_id: agent.id})
    end

    test "implementer_dispatch_id is KEPT — it is custody provenance, not a credential" do
      %{tenant_id: tenant_id, story: story, dispatch: dispatch} = story_with_session_dispatch()

      {:ok, _released} = Progress.force_unclaim_story(tenant_id, story.id)

      assert reload_story(story.id).implementer_dispatch_id == dispatch.id
    end

    test "the lineage every L4 gate compares still resolves after the revoke" do
      # The reason clearing and revoking are different acts. `get_dispatch/2` reads a
      # revoked row, so `verify`/`report`/`review-complete` compare exactly the lineage
      # they compared before — a revoke cannot launder custody, and cannot strand a
      # story behind `unresolvable_dispatch_lineage` either.
      %{tenant_id: tenant_id, story: story, dispatch: dispatch} = story_with_session_dispatch()

      lineage_before = reload_dispatch(dispatch.id).lineage_path

      {:ok, _released} = Progress.force_unclaim_story(tenant_id, story.id)

      assert {:ok, revoked} = Dispatches.get_dispatch(tenant_id, dispatch.id)
      assert revoked.lineage_path == lineage_before
      assert revoked.revoked_at
    end

    test "it is idempotent: a second force-unclaim keeps the ORIGINAL revoked_at" do
      %{tenant_id: tenant_id, story: story, dispatch: dispatch} = story_with_session_dispatch()

      {:ok, _} = Progress.force_unclaim_story(tenant_id, story.id)
      first = reload_dispatch(dispatch.id).revoked_at

      {:ok, _} = Progress.force_unclaim_story(tenant_id, story.id)

      assert DateTime.compare(reload_dispatch(dispatch.id).revoked_at, first) == :eq
    end
  end

  describe "scope: only a dispatch minted FOR this story" do
    test "a general agent dispatch (story_id: nil) keeps its key" do
      # The blast-radius bound. `Dispatches.revoke/2` cascades to descendants, so
      # revoking here would kill every other story the agent holds.
      %{tenant_id: tenant_id, story: story, dispatch: dispatch} =
        story_with_session_dispatch(%{story_id: nil})

      {:ok, _released} = Progress.force_unclaim_story(tenant_id, story.id)

      refute reload_dispatch(dispatch.id).revoked_at,
             "a dispatch not minted for this story must survive its force-unclaim"

      refute key_for(dispatch).revoked_at
    end

    test "a dispatch minted for a DIFFERENT story keeps its key" do
      %{tenant_id: tenant_id, agent: agent, story: story} = story_with_session_dispatch()
      other = fixture(:story, %{tenant_id: tenant_id, agent_status: :contracted})

      {:ok, %{dispatch: elsewhere}} =
        Dispatches.create_dispatch(tenant_id, %{
          role: :orchestrator,
          agent_id: agent.id,
          story_id: other.id
        })

      # Point THIS story at the other story's dispatch, which is what a hand-claim with
      # an unrelated dispatch key produces.
      {1, _} =
        from(s in Story, where: s.id == ^story.id)
        |> AdminRepo.update_all(set: [implementer_dispatch_id: elsewhere.id])

      {:ok, _released} = Progress.force_unclaim_story(tenant_id, story.id)

      refute reload_dispatch(elsewhere.id).revoked_at
    end

    test "a story with no implementer dispatch releases normally" do
      agent = fixture(:agent, %{agent_type: :implementer})
      story = fixture(:story, %{tenant_id: agent.tenant_id, agent_status: :contracted})
      {:ok, claimed} = Progress.claim_story(agent.tenant_id, story.id, agent_id: agent.id)

      assert is_nil(claimed.implementer_dispatch_id)
      assert {:ok, released} = Progress.force_unclaim_story(agent.tenant_id, story.id)
      assert released.agent_status == :pending
    end
  end

  describe "Dispatches.revoke_story_session/3" do
    test "reports WHY it left a dispatch alone rather than returning a bare :ok" do
      # A silent skip and a successful revoke would be indistinguishable to the caller,
      # and the caller is what logs the operator-facing remedy.
      %{tenant_id: tenant_id, story: story, dispatch: dispatch} = story_with_session_dispatch()

      assert {:ok, :no_dispatch} = Dispatches.revoke_story_session(tenant_id, story.id, nil)

      assert {:ok, :dispatch_not_found} =
               Dispatches.revoke_story_session(tenant_id, story.id, Ecto.UUID.generate())

      other = fixture(:story, %{tenant_id: tenant_id})

      assert {:ok, :not_story_session} =
               Dispatches.revoke_story_session(tenant_id, other.id, dispatch.id)

      assert {:ok, count} =
               Dispatches.revoke_story_session(tenant_id, story.id, dispatch.id)

      assert count >= 1
    end

    test "tenant isolation: another tenant's id cannot revoke this dispatch" do
      %{story: story, dispatch: dispatch} = story_with_session_dispatch()
      other_tenant = fixture(:tenant)

      assert {:ok, :dispatch_not_found} =
               Dispatches.revoke_story_session(other_tenant.id, story.id, dispatch.id)

      refute reload_dispatch(dispatch.id).revoked_at
    end
  end
end
