defmodule Loopctl.E2E.CoordinationHandoffJourneyTest do
  @moduledoc """
  End-to-end journey for the repo coordination bus (Epics 39/40): the handoff that lets
  a session on one machine pass work to a session on another with no human relay.

  The property that matters is EXACTLY-ONCE. A handoff is discovered by many sessions
  and must be executed by one, so the claim — not the post, and not the reader's good
  intentions — is what prevents two machines doing the same work. This journey drives
  the whole path an agent takes (post -> discover -> claim -> second claimant refused
  -> done) and asserts that a claimed handoff stops being advertised, which is what
  clears it from every other session's startup context.

  Excluded from the default suite (`@moduletag :e2e`); run with `mix test.e2e`.
  """
  use LoopctlWeb.ConnCase, async: true

  @moduletag :e2e

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # A channel write is project-scoped by MEMBERSHIP (US-40.D3), and membership is
  # derived from a story assignment — an agent with no story in the project is refused
  # `ownership_rejected` by the default-deny gate even though its key is valid and
  # carries an agent identity. Both properties are load-bearing for a handoff: the key
  # must be attributable (agent_id) AND admitted to the channel (membership).
  defp member_agent(tenant, project) do
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent.id,
      agent_status: :assigned
    })

    raw
  end

  describe "handoff journey: post -> discover -> claim -> done" do
    test "a posted handoff is discoverable, claimable exactly once, and retired by done",
         %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      # Two DISTINCT member agents — the claim gate is between agents, so one key
      # cannot demonstrate it.
      raw_a = member_agent(tenant, project)
      raw_b = member_agent(tenant, project)

      anchor = "e2e-handoff-#{System.unique_integer([:positive])}"
      ref = "handoff:#{anchor}"

      # 1) POST the pointer. Body is a TL;DR + where the full context lives — the bus is
      # a coordination signal, not a document store.
      posted =
        conn
        |> auth_conn(raw_a)
        |> post(~p"/api/v1/channel/posts", %{
          project_id: project.id,
          key: ref,
          body: "HANDOFF #{anchor}: full context in the durable home."
        })
        |> json_response(201)

      assert posted["post"]["key"] == ref

      # 2) DISCOVER — an unclaimed handoff is advertised.
      listed =
        conn
        |> auth_conn(raw_b)
        |> get(~p"/api/v1/channel/handoffs", %{project_id: project.id})
        |> json_response(200)

      assert ref in Enum.map(listed["data"], & &1["key"]),
             "a freshly posted, unclaimed handoff must be discoverable"

      # 3) CLAIM — the first claimant wins.
      conn
      |> auth_conn(raw_b)
      |> post(~p"/api/v1/channel/claims", %{project_id: project.id, ref: ref})
      |> json_response(201)

      # 4) The anti-double-work gate: a DIFFERENT agent is refused with 409. This is the
      # single assertion the whole mechanism exists for — without it two machines do the
      # same work, and the failure is invisible because both succeed.
      conflict =
        conn
        |> auth_conn(raw_a)
        |> post(~p"/api/v1/channel/claims", %{project_id: project.id, ref: ref})

      assert conflict.status == 409

      # 5) A claimed handoff stops being advertised, so no other session is offered work
      # that is already owned.
      after_claim =
        conn
        |> auth_conn(raw_a)
        |> get(~p"/api/v1/channel/handoffs", %{project_id: project.id})
        |> json_response(200)

      refute ref in Enum.map(after_claim["data"], & &1["key"]),
             "a claimed handoff must leave the discovery list"

      # 6) DONE is terminal — it must not resurface afterwards.
      conn
      |> auth_conn(raw_b)
      |> post(~p"/api/v1/channel/claims/done", %{project_id: project.id, ref: ref})
      |> json_response(200)

      after_done =
        conn
        |> auth_conn(raw_a)
        |> get(~p"/api/v1/channel/handoffs", %{project_id: project.id})
        |> json_response(200)

      refute ref in Enum.map(after_done["data"], & &1["key"])
    end

    test "re-claiming your OWN active ref is idempotent, so a lost response is safe to retry",
         %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      raw = member_agent(tenant, project)

      ref = "handoff:e2e-idem-#{System.unique_integer([:positive])}"

      conn
      |> auth_conn(raw)
      |> post(~p"/api/v1/channel/posts", %{project_id: project.id, key: ref, body: "idempotency"})
      |> json_response(201)

      first =
        conn
        |> auth_conn(raw)
        |> post(~p"/api/v1/channel/claims", %{project_id: project.id, ref: ref})
        |> json_response(201)

      # Same agent, same ref: returns the existing claim rather than 409ing itself out of
      # its own work. A timeout on the first call must not strand the handoff.
      again =
        conn
        |> auth_conn(raw)
        |> post(~p"/api/v1/channel/claims", %{project_id: project.id, ref: ref})

      assert again.status in [200, 201]
      assert json_response(again, again.status)["claim"]["id"] == first["claim"]["id"]
    end
  end
end
