defmodule LoopctlWeb.StoryEscalationControllerTest do
  @moduledoc """
  Issue #803, design §8: `POST /api/v1/stories/:id/escalate`.

  ## Why `async: false`

  The auth pipeline resolves the API key through `Loopctl.AdminRepo` while
  `Loopctl.Delivery.Stages` reads and writes the story on the RLS `Loopctl.Repo`. Those are
  separate sandbox connections that cannot see each other's uncommitted rows, and no sandbox
  mode shares one transaction across two repos — so the TENANT and the KEY are committed
  (`fixture(:committed_agent_key)`, swept at the module boundary) while the story and its
  stage row stay inside the `Repo` sandbox. A committed row is visible to every concurrently
  running async test, which is what makes this module serial. The gate's own logic is tested
  without a socket or a key in `Loopctl.Delivery.EscalationsTest`, which is async.
  """

  use LoopctlWeb.ConnCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Delivery.Stages
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 5

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # A committed tenant and agent key, plus a story claimed by that agent at `@epoch` with its
  # stage row at `stage`, both inside the `Repo` sandbox.
  defp claimed_story(stage \\ :implementing) do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {raw_key, _api_key, agent} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
    story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: @epoch})

    as_tenant(tenant.id, fn ->
      from(s in Story, where: s.id == ^story.id)
      |> Repo.update_all(set: [assigned_agent_id: agent.id, agent_status: :implementing])
    end)

    # `story_stages_escalation_reason` requires one when the row IS escalated — the column and
    # the stage are constrained together, so a fixture that parks a row without a reason is
    # refused by Postgres rather than by the machine.
    reason =
      if stage == :escalated, do: %{escalation_reason: "parked by the first run"}, else: %{}

    fixture(
      :story_stage,
      Map.merge(
        %{tenant_id: tenant.id, story_id: story.id, stage: stage, claim_epoch: @epoch},
        reason
      )
    )

    %{tenant: tenant, raw_key: raw_key, agent: agent, story: story}
  end

  defp body(overrides \\ %{}) do
    Map.merge(
      %{"claim_epoch" => @epoch, "reason" => "the request contradicts US-3.1"},
      overrides
    )
  end

  describe "GET /api/v1/stories/:id/stage" do
    test "returns where the story is in the delivery machine", %{conn: conn} do
      %{story: story, raw_key: raw_key} = claimed_story(:worktree)

      # THE LOOP WAS UNOBSERVABLE WITHOUT THIS. Nothing on the API returned a stage, so an
      # operator watching a run could not see where a story was, and a runner refused
      # `stale_stage` — which means "the row is not where you think" — had no way to find out
      # where it actually was. The deployed runner brute-forces three transitions for want of
      # this one read.
      body =
        conn
        |> auth(raw_key)
        |> get(~p"/api/v1/stories/#{story.id}/stage")
        |> json_response(200)

      assert body["stage"]["stage"] == "worktree"
      assert body["stage"]["story_id"] == story.id
      assert body["stage"]["claim_epoch"] == @epoch
      assert body["stage"]["escalation_reason_untrusted"] == true
    end

    test "a story the delivery loop has never touched answers null, not 404", %{conn: conn} do
      tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
      {raw_key, _api_key, _agent} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
      story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: 0})

      # A story with no stage row is an ORDINARY state — every story created outside the
      # delivery loop is in it — so it is an answer rather than an error. A 404 here would be
      # indistinguishable from a story id that does not exist.
      body =
        conn
        |> auth(raw_key)
        |> get(~p"/api/v1/stories/#{story.id}/stage")
        |> json_response(200)

      assert body["stage"] == nil
    end
  end

  describe "POST /api/v1/stories/:id/stage/resolve" do
    test "a human sends an escalated story back to be worked", %{conn: conn} do
      %{story: story, tenant: tenant} = claimed_story(:escalated)
      {operator_key, _operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})

      # The other half of `escalate`, and it had NO caller of any kind: `:human_resolution` is
      # in the stage machine, `Stages.advance/4` gates it, and nothing in `lib/` or on the API
      # could take it — so a story a session parked for a person stayed parked for ever,
      # including the one the loop's first end-to-end run left behind.
      body =
        conn
        |> auth(operator_key)
        |> post(~p"/api/v1/stories/#{story.id}/stage/resolve", %{
          "to" => "queued",
          "reason" => "rescoped, go ahead"
        })
        |> json_response(200)

      assert body["stage"]["stage"] == "queued"
      assert Stages.get(story.tenant_id, story.id).stage == :queued
    end

    test "an AGENT key cannot resolve, which is the separation", %{conn: conn} do
      %{story: story, raw_key: raw_key} = claimed_story(:escalated)

      # `escalate` is `exact_role: :agent` and this is `role: :user`, so the principal that
      # raises an escalation cannot clear it. The stage machine enforces the same thing itself
      # — a `:user`+ role on a key no dispatch minted — and this gate says so before any story
      # is read.
      conn
      |> auth(raw_key)
      |> post(~p"/api/v1/stories/#{story.id}/stage/resolve", %{"to" => "queued"})
      |> json_response(403)

      assert Stages.get(story.tenant_id, story.id).stage == :escalated
    end

    test "a story that is NOT escalated is refused, and told which stage it is at", %{conn: conn} do
      %{story: story, tenant: tenant} = claimed_story(:implementing)
      {operator_key, _operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})

      # Named rather than answered with the machine's `stale_stage`, which is the word it uses
      # for a story that moved under a runner — an operator reading that would go looking for
      # a race that did not happen.
      body =
        conn
        |> auth(operator_key)
        |> post(~p"/api/v1/stories/#{story.id}/stage/resolve", %{"to" => "queued"})
        |> json_response(409)

      assert body["error"]["code"] == "not_escalated"
      assert body["error"]["stage"] == "implementing"
    end

    test "a target the stage machine does not have is refused", %{conn: conn} do
      %{story: story, tenant: tenant} = claimed_story(:escalated)
      {operator_key, _operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})

      # `escalated` leads to `queued`, `done` or `failed` and nowhere else. Sending a story
      # straight back to `implementing` would skip the claim it no longer has.
      conn
      |> auth(operator_key)
      |> post(~p"/api/v1/stories/#{story.id}/stage/resolve", %{"to" => "implementing"})
      |> json_response(400)

      assert Stages.get(story.tenant_id, story.id).stage == :escalated
    end
  end

  describe "POST /api/v1/stories/:id/escalate" do
    test "the claimant parks the story at escalated", %{conn: conn} do
      %{story: story, raw_key: raw_key} = claimed_story()

      conn =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

      assert %{"stage" => stage} = json_response(conn, 200)
      assert stage["stage"] == "escalated"
      assert stage["story_id"] == story.id
      assert stage["claim_epoch"] == @epoch
      assert stage["escalation_reason"] == "the request contradicts US-3.1"
      assert stage["attempts"]["session_escalated"] == 1

      # The flag a client acts on: the reason is session-authored and must be fenced before
      # it reaches a model. It is a property of the field, so it is always stated.
      assert stage["escalation_reason_untrusted"] == true

      assert Stages.get(story.tenant_id, story.id).stage == :escalated
    end

    test "records the optional structured payload", %{conn: conn} do
      %{story: story, raw_key: raw_key} = claimed_story()

      conn =
        conn
        |> auth(raw_key)
        |> post(
          ~p"/api/v1/stories/#{story.id}/escalate",
          body(%{"payload" => %{"contradicts" => ["US-3.1"]}})
        )

      assert json_response(conn, 200)["stage"]["stage"] == "escalated"

      assert [%{data: data}] =
               story.tenant_id
               |> Stages.list_events(story.id)
               |> Enum.filter(&(&1.event == "transitioned"))

      assert data["payload"] == %{"contradicts" => ["US-3.1"]}
    end

    test "is idempotent on replay", %{conn: conn} do
      %{story: story, raw_key: raw_key} = claimed_story()

      first =
        conn |> auth(raw_key) |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

      second =
        build_conn()
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

      one = json_response(first, 200)["stage"]
      two = json_response(second, 200)["stage"]

      assert two["lock_version"] == one["lock_version"]
      assert two["attempts"]["session_escalated"] == 1
    end

    test "409 not_claimant for an agent that is not the story's", %{conn: conn} do
      %{tenant: tenant, story: story} = claimed_story()
      {other_key, _api_key, _agent} = fixture(:committed_agent_key, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth(other_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

      assert json_response(conn, 409)["error"]["code"] == "not_claimant"
      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "409 stale_claim_epoch for an epoch the claim no longer has", %{conn: conn} do
      %{story: story, raw_key: raw_key} = claimed_story()

      conn =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body(%{"claim_epoch" => @epoch - 1}))

      assert json_response(conn, 409)["error"]["code"] == "stale_claim_epoch"
      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "400 for a missing or malformed claim_epoch and for a bad reason" do
      %{story: story, raw_key: raw_key} = claimed_story()

      for params <- [
            Map.delete(body(), "claim_epoch"),
            body(%{"claim_epoch" => "5"}),
            body(%{"claim_epoch" => -1}),
            Map.delete(body(), "reason"),
            body(%{"reason" => "   "}),
            body(%{"reason" => String.duplicate("x", 4_001)}),
            body(%{"payload" => "not an object"})
          ] do
        conn =
          build_conn()
          |> auth(raw_key)
          |> post(~p"/api/v1/stories/#{story.id}/escalate", params)

        assert json_response(conn, 400)
      end

      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    # #824 round 1, finding 1: these two atoms had NO FallbackController clause and no
    # catch-all, so both answered 500 — the declared 422 and 409 were fiction. Both are
    # reachable from a well-formed request, which is what makes them worth a test rather
    # than a comment.
    test "422, not 500, for a payload the stage event will not take" do
      %{story: story, raw_key: raw_key} = claimed_story()
      oversized = %{"blob" => String.duplicate("x", 8_001)}

      conn =
        build_conn()
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body(%{"payload" => oversized}))

      assert json_response(conn, 422)["error"]["code"] == "invalid_event_data"
      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "409, not 500, escalating from a stage no session may escalate from" do
      # `verified` is control's: it is reached only by control's own `deployed -> verified`,
      # and nothing a session does leaves it. `merged` and `deployed` ARE escalatable — they
      # would otherwise be absorbing (#824 round 3, H2) — so this uses the one that is not.
      %{story: story, raw_key: raw_key} = claimed_story(:verified)

      conn =
        build_conn()
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

      assert json_response(conn, 409)["error"]["code"] == "invalid_transition"
      assert Stages.get(story.tenant_id, story.id).stage == :verified
    end

    test "escalating from deployed works, so the deploy is not a dead end" do
      # H2: with the runner's source filter stopping at `merged`, nothing in lib/ could write
      # any edge out of `deployed` — the row froze for every principal including Mark.
      %{story: story, raw_key: raw_key} = claimed_story(:deployed)

      conn =
        build_conn()
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

      assert json_response(conn, 200)["stage"]["stage"] == "escalated"
      assert Stages.get(story.tenant_id, story.id).stage == :escalated
    end

    # #824 round 1, finding 5: `maxLength` counts GRAPHEMES and the CHECK counts CODEPOINTS,
    # so a reason under the schema's bound and over Postgres' used to reach the database and
    # die there. An emoji family is ONE grapheme and SEVEN codepoints.
    test "400 for a reason over the bound in CODEPOINTS though under it in graphemes" do
      %{story: story, raw_key: raw_key} = claimed_story()
      family = "👨‍👩‍👧‍👦"

      assert String.length(family) == 1
      assert family |> String.to_charlist() |> length() == 7

      # 1000 graphemes, 7000 codepoints: inside maxLength 4000, well past the CHECK's 4000.
      reason = String.duplicate(family, 1_000)

      conn =
        build_conn()
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body(%{"reason" => reason}))

      assert json_response(conn, 400)
      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "404 when the story has no delivery stage row", %{conn: conn} do
      tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
      {raw_key, _api_key, agent} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
      story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: @epoch})

      as_tenant(tenant.id, fn ->
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [assigned_agent_id: agent.id])
      end)

      conn =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

      assert json_response(conn, 404)["error"]["code"] == "unknown_story_stage"
    end

    test "a story in ANOTHER tenant is a 404, not another tenant's escalation", %{conn: conn} do
      %{story: story} = claimed_story()
      intruder = fixture(:committed_tenant, %{trust_tier: :human_anchored})
      {raw_key, _api_key, _agent} = fixture(:committed_agent_key, %{tenant_id: intruder.id})

      conn =
        conn
        |> auth(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

      assert json_response(conn, 404)
      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end
  end

  describe "the role gate" do
    test "403s an orchestrator key, so the principal that RESOLVES cannot raise" do
      # `:human_resolution` is gated on a role of at least `:user`. If escalate took a
      # hierarchy `role:` gate instead of `exact_role: :agent`, one high-privilege key could
      # manufacture the escalation it then resolves — the separation this route exists inside.
      %{tenant: tenant, story: story} = claimed_story()

      for role <- [:orchestrator, :user] do
        {raw_key, _} =
          Sandbox.unboxed_run(AdminRepo, fn ->
            {:ok, pair} =
              Auth.generate_api_key(%{
                tenant_id: tenant.id,
                name: "#{role}-key",
                role: role
              })

            pair
          end)

        conn =
          build_conn()
          |> auth(raw_key)
          |> post(~p"/api/v1/stories/#{story.id}/escalate", body())

        assert json_response(conn, 403)
      end

      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end
  end
end
