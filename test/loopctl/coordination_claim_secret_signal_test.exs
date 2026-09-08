defmodule Loopctl.CoordinationClaimSecretSignalTest do
  @moduledoc """
  The claim path's credential gate (#779) must raise the SAME
  `[:loopctl, :coordination, :secret_blocked]` counter the post path does. Shipping the
  write-time rejection without the signal leaves the coordination plane's
  credential-attempt dashboard under-reporting exactly the new surface.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Coordination

  test "a credential in the session discriminator fires secret_blocked" do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent_id = fixture(:agent, %{tenant_id: tenant.id}).id

    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent_id,
      agent_status: :assigned
    })

    test_pid = self()
    handler_id = "claim-secret-blocked-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:loopctl, :coordination, :secret_blocked],
      fn _event, measurements, meta, _cfg ->
        if meta[:tenant_id] == tenant.id, do: send(test_pid, {:blocked, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, %Ecto.Changeset{}} =
             Coordination.claim(tenant.id, agent_id, project.id, "handoff:repo#812",
               role: :agent,
               session_id: "sk-ant-api03-" <> String.duplicate("a", 40),
               audit: [actor_type: "api_key", actor_id: Ecto.UUID.generate()]
             )

    assert_received {:blocked, %{count: 1}, %{field: :claimed_by_session}}
  end
end
