defmodule Loopctl.RunnersTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Auth
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  describe "enroll_runner/3" do
    test "mints an :agent key bound to the machine name and records it on the audit chain" do
      tenant = fixture(:tenant)

      assert {:ok, %{runner: runner, raw_key: raw_key}} =
               Runners.enroll_runner(tenant.id, %{name: "minis"})

      assert runner.name == "minis"
      assert runner.tenant_id == tenant.id
      assert is_nil(runner.revoked_at)

      assert {:ok, api_key} = Auth.verify_api_key(raw_key)
      assert api_key.id == runner.api_key_id
      assert api_key.role == :agent
      assert api_key.tenant_id == tenant.id

      assert AdminRepo.exists?(
               from e in Entry,
                 where:
                   e.tenant_id == ^tenant.id and e.action == "runner_enrolled" and
                     e.entity_id == ^runner.id
             )
    end

    test "binds the machine to a `runner:<name>` agent, and re-enrollment reuses it" do
      tenant = fixture(:tenant)

      assert {:ok, %{runner: runner}} = Runners.enroll_runner(tenant.id, %{name: "minis"})

      agent = AdminRepo.get!(Agent, runner.agent_id)
      assert agent.tenant_id == tenant.id
      # The LITERAL, not `Runners.agent_name("minis")`: comparing the name against the
      # function that produced it is a tautology no change to that function can fail, and
      # `bin/mutate.sh` said so — rewriting the prefix came back inert against this test.
      assert agent.name == "runner:minis"
      assert Runners.agent_name("minis") == "runner:minis"
      assert agent.agent_type == :implementer

      # `Loopctl.Delivery.Placement` claims the story for THIS agent, and a claimed story with
      # an implementer dispatch and no `assigned_agent_id` violates
      # `stories_reported_done_requires_agent` — so the binding is what makes the whole
      # dispatch path reachable, not attribution polish.
      assert AdminRepo.get!(Runner, runner.id).agent_id == agent.id

      # The active-name index is partial on `revoked_at IS NULL`, so the same machine can be
      # enrolled again — and it is the same machine, so it keeps the one agent.
      {:ok, _revoked} = Runners.revoke_runner(tenant.id, runner.id)
      assert {:ok, %{runner: again}} = Runners.enroll_runner(tenant.id, %{name: "minis"})
      assert again.agent_id == agent.id
    end

    test "does not adopt an agent somebody else named `runner:<name>` first" do
      tenant = fixture(:tenant)

      # `AgentController`'s :register is `exact_role: :agent`, so ANY agent-role key in the
      # tenant can create this row before the machine is ever enrolled. Adopting it would hand
      # a squatter the identity a runner's work is attributed to — `Loopctl.Delivery.Placement`
      # claims stories for `runners.agent_id`.
      squatter =
        %Agent{tenant_id: tenant.id}
        |> Agent.register_changeset(%{name: "runner:minis", agent_type: :implementer})
        |> AdminRepo.insert!()

      assert {:ok, %{runner: runner}} = Runners.enroll_runner(tenant.id, %{name: "minis"})

      refute runner.agent_id == squatter.id
      # And enrollment still SUCCEEDS: a squatter must not be able to stop a machine joining
      # either, so the fresh agent takes a disambiguating name rather than failing the insert.
      assert AdminRepo.get!(Agent, runner.agent_id).name =~ ~r/^runner:minis-/
    end

    test "enrolls with max_sessions, defaulting to two, and refuses one out of range" do
      tenant = fixture(:tenant)

      assert {:ok, %{runner: %{max_sessions: 2, in_flight: 0}}} =
               Runners.enroll_runner(tenant.id, %{name: "minis"})

      assert {:ok, %{runner: %{max_sessions: 5}}} =
               Runners.enroll_runner(tenant.id, %{"name" => "blockit", "max_sessions" => 5})

      # Refused by the changeset itself, before the CHECK constraint behind it is reached.
      for bad <- [0, 65] do
        refute Runner.create_changeset(%Runner{tenant_id: tenant.id}, %{
                 name: "nuc",
                 max_sessions: bad
               }).valid?
      end

      for bad <- [0, 65, -1] do
        assert {:error, %Ecto.Changeset{} = cs} =
                 Runners.enroll_runner(tenant.id, %{name: "nuc", max_sessions: bad})

        assert %{max_sessions: _} = errors_on(cs)
      end

      assert Auth.count_api_keys(tenant.id) == 2
    end

    test "refuses a malformed name without minting a key" do
      tenant = fixture(:tenant)

      for bad <- ["", "Minis", "has space", "../etc", "-leading", String.duplicate("a", 64)] do
        assert {:error, %Ecto.Changeset{} = cs} = Runners.enroll_runner(tenant.id, %{name: bad})
        assert %{name: _} = errors_on(cs)
      end

      assert Auth.count_api_keys(tenant.id) == 0
    end

    test "refuses a second ACTIVE runner with the same name, and rolls its key back" do
      tenant = fixture(:tenant)
      {_raw, _runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})

      assert {:error, %Ecto.Changeset{} = cs} = Runners.enroll_runner(tenant.id, %{name: "minis"})
      assert "an active runner already uses this name" in errors_on(cs).name
      assert Auth.count_api_keys(tenant.id) == 1
    end

    test "raising a machine's ceiling is revoke-then-enrol, and the old credential dies with it" do
      # #846.4 review ROUND 2, finding 6. Four operator-facing surfaces said only "re-enrol
      # it", which is not an executable instruction: `runners_active_name_uidx` is partial on
      # `revoked_at IS NULL`, so the revoke is not optional — and it invalidates the
      # credential the machine is connected with, which is why a new token file and a restart
      # are part of the procedure rather than a detail. This test is what makes the corrected
      # wording checkable.
      tenant = fixture(:tenant)
      {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis", max_sessions: 2})

      assert {:error, %Ecto.Changeset{}} =
               Runners.enroll_runner(tenant.id, %{name: "minis", max_sessions: 8})

      {:ok, _} = Runners.revoke_runner(tenant.id, runner.id)

      assert {:ok, %{runner: again, raw_key: new_raw}} =
               Runners.enroll_runner(tenant.id, %{name: "minis", max_sessions: 8})

      assert again.enrolled_max_sessions == 8
      assert again.max_sessions == 8
      assert {:error, _} = Auth.verify_api_key(raw)
      assert {:ok, _} = Auth.verify_api_key(new_raw)
    end

    test "allows re-enrolling a revoked machine under its old name" do
      tenant = fixture(:tenant)
      {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
      {:ok, _} = Runners.revoke_runner(tenant.id, runner.id)

      assert {:ok, %{runner: again}} = Runners.enroll_runner(tenant.id, %{name: "minis"})
      assert again.id != runner.id
    end
  end

  describe "the enrolled ceiling is filled by the database when a writer omits it" do
    test "an INSERT that does not name enrolled_max_sessions takes it from max_sessions" do
      # #846.4 review ROUND 2, finding 5. `fly.toml` runs migrations as the `release_command`
      # and then replaces machines ONE AT A TIME, so for the length of a deploy the column
      # exists and OLD instances are still serving. Their `Runner` schema has no
      # `enrolled_max_sessions`, so their enrollment INSERT does not name it — and against a
      # bare NOT NULL with no server-side fallback that is a not-null violation, i.e.
      # `POST /api/v1/runners` and the `runner_enroll` tool 500 for the whole window.
      #
      # A BEFORE INSERT trigger fills it from `max_sessions`, which is the same derivation
      # `Runner.create_changeset/2` makes, so the operator's own grant is what lands rather
      # than a constant nobody chose. This INSERT is the old instance's statement.
      tenant = fixture(:tenant)
      {_raw, existing} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
      {_raw_key, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      now = DateTime.utc_now()

      assert {1, _} =
               AdminRepo.insert_all("runners", [
                 %{
                   id: Ecto.UUID.bingenerate(),
                   tenant_id: Ecto.UUID.dump!(tenant.id),
                   api_key_id: Ecto.UUID.dump!(key.id),
                   agent_id: Ecto.UUID.dump!(existing.agent_id),
                   name: "beelink",
                   max_sessions: 8,
                   in_flight: 0,
                   inserted_at: now,
                   updated_at: now
                 }
               ])

      assert AdminRepo.one!(
               from r in Runner,
                 where: r.tenant_id == ^tenant.id and r.name == "beelink",
                 select: r.enrolled_max_sessions
             ) == 8
    end

    test "and a writer that DOES name it keeps its own value" do
      # The trigger fills a NULL and never overwrites, so the ordinary enrollment path — which
      # derives the grant in the changeset — is unaffected.
      tenant = fixture(:tenant)

      assert {:ok, %{runner: runner}} =
               Runners.enroll_runner(tenant.id, %{name: "minis", max_sessions: 5})

      assert runner.enrolled_max_sessions == 5
      assert runner.max_sessions == 5
    end
  end

  describe "authenticate/1" do
    test "resolves an enrolled runner's token" do
      {raw, runner} = fixture(:runner, %{})
      assert {:ok, %{runner: %Runner{id: id}, api_key: key}} = Runners.authenticate(raw)
      assert id == runner.id
      assert key.id == runner.api_key_id
    end

    test "refuses garbage, empty and non-binary tokens" do
      assert {:error, :invalid_token} = Runners.authenticate("lc_not_a_key")
      assert {:error, :invalid_token} = Runners.authenticate("")
      assert {:error, :invalid_token} = Runners.authenticate(nil)
    end

    test "refuses a valid agent key that is not bound to a runner" do
      tenant = fixture(:tenant)
      {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      assert {:error, :not_a_runner} = Runners.authenticate(raw)
    end

    test "refuses a valid key of any other role" do
      tenant = fixture(:tenant)

      for role <- [:user, :orchestrator] do
        {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: role})
        assert {:error, :not_a_runner} = Runners.authenticate(raw)
      end
    end

    test "refuses a revoked runner at once, through the key cache" do
      {raw, runner} = fixture(:runner, %{})
      # Warm the positive cache entry first, so the refusal proves the cache was busted.
      assert {:ok, _} = Runners.authenticate(raw)

      {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert {:error, :invalid_token} = Runners.authenticate(raw)
    end

    test "refuses a runner whose tenant is suspended" do
      tenant = fixture(:tenant)
      {raw, _runner} = fixture(:runner, %{tenant_id: tenant.id})
      {:ok, _} = Tenants.suspend_tenant(tenant)
      Auth.invalidate_key_cache_by_hashes([Auth.hash_key(raw)])

      assert {:error, :tenant_inactive} = Runners.authenticate(raw)
    end
  end

  describe "revoke_runner/3" do
    test "revokes the row and the key, audits, and notifies the live channel" do
      {_raw, runner} = fixture(:runner, %{})
      :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.revocation_topic(runner.id))

      assert {:ok, revoked} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert revoked.revoked_at
      assert_receive :runner_revoked

      assert %{revoked_at: %DateTime{}} = AdminRepo.get!(Auth.ApiKey, runner.api_key_id)

      assert AdminRepo.exists?(
               from e in Entry,
                 where: e.action == "runner_revoked" and e.entity_id == ^runner.id
             )
    end

    test "after a key revoke through api_keys, still audits once and tells the live channel" do
      {_raw, runner} = fixture(:runner, %{})
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)
      :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.revocation_topic(runner.id))

      assert {:ok, %Runner{revoked_at: %DateTime{}}} =
               Runners.revoke_runner(runner.tenant_id, runner.id)

      assert_receive :runner_revoked
      {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert revocation_entries(runner) == 1
    end

    test "is idempotent" do
      {_raw, runner} = fixture(:runner, %{})
      {:ok, first} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert {:ok, second} = Runners.revoke_runner(runner.tenant_id, runner.id)
      assert second.revoked_at == first.revoked_at
    end

    test "is not_found for a malformed id" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Runners.revoke_runner(tenant.id, "not-a-uuid")
    end
  end

  describe "the runner row follows its key" do
    test "revoking the key through the api_keys route revokes the runner, freeing its name" do
      tenant = fixture(:tenant)
      {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
      {:ok, key} = Auth.get_api_key(tenant.id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      assert %Runner{revoked_at: %DateTime{}} = AdminRepo.get!(Runner, runner.id)
      assert Runners.list_runners(tenant.id) == []
      assert {:ok, _} = Runners.enroll_runner(tenant.id, %{name: "minis"})
    end

    test "revoking an unrelated key leaves every runner active" do
      tenant = fixture(:tenant)
      {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id})
      {_raw_key, other} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, _} = Auth.revoke_api_key(other)

      assert is_nil(AdminRepo.get!(Runner, runner.id).revoked_at)
    end

    test "runner_key?/2 names a runner's key and nothing else, per tenant" do
      {_raw, runner} = fixture(:runner, %{})
      {_raw_key, plain} = fixture(:api_key, %{tenant_id: runner.tenant_id, role: :agent})

      assert Runners.runner_key?(runner.tenant_id, runner.api_key_id)
      refute Runners.runner_key?(runner.tenant_id, plain.id)
      refute Runners.runner_key?(fixture(:tenant).id, runner.api_key_id)
    end
  end

  defp revocation_entries(runner) do
    AdminRepo.aggregate(
      from(e in Entry, where: e.action == "runner_revoked" and e.entity_id == ^runner.id),
      :count
    )
  end

  describe "authorized?/2" do
    test "is true for an active runner" do
      {_raw, runner} = fixture(:runner, %{})
      assert Runners.authorized?(runner.tenant_id, runner.id)
    end

    test "is false once the runner is revoked" do
      {_raw, runner} = fixture(:runner, %{})
      {:ok, _} = Runners.revoke_runner(runner.tenant_id, runner.id)
      refute Runners.authorized?(runner.tenant_id, runner.id)
    end

    test "is false when the key is revoked by the api_keys route, not the runner route" do
      {_raw, runner} = fixture(:runner, %{})
      {:ok, key} = Auth.get_api_key(runner.tenant_id, runner.api_key_id)
      {:ok, _} = Auth.revoke_api_key(key)

      refute Runners.authorized?(runner.tenant_id, runner.id)
    end

    test "is false when the key has expired" do
      {_raw, runner} = fixture(:runner, %{})
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      from(k in Auth.ApiKey, where: k.id == ^runner.api_key_id)
      |> AdminRepo.update_all(set: [expires_at: past])

      refute Runners.authorized?(runner.tenant_id, runner.id)
    end

    test "is false when the tenant is suspended" do
      tenant = fixture(:tenant)
      {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id})
      {:ok, _} = Tenants.suspend_tenant(tenant)

      refute Runners.authorized?(tenant.id, runner.id)
    end
  end

  describe "declared_branch_prefixes/1 (contract 1.14.0)" do
    # STORED NOWHERE — this reads the live meta at the decision, which is why there is no
    # migration and nothing to reconcile on a reconnect. See the function's own doc for why a
    # branch prefix can take that form where capacity could not.
    test "a declaration is returned verbatim, in the order the runner sent it" do
      assert Runners.declared_branch_prefixes(%{branch_prefixes: ["loop/", "feature/"]}) ==
               ["loop/", "feature/"]
    end

    # AC-1: silence is NO CONSTRAINT, which is what makes the field additive. A runner built
    # before 1.14.0 sends no such key and must behave exactly as it did.
    test "silence and an empty array are no constraint" do
      assert Runners.declared_branch_prefixes(%{max_sessions: 2}) == []
      assert Runners.declared_branch_prefixes(%{branch_prefixes: []}) == []
      assert Runners.declared_branch_prefixes(%{}) == []
    end

    # 846.2 REVIEW ROUND 2, FINDING 6. This returned `[]` for a list carrying ANY non-binary,
    # and `[]` means NO CONSTRAINT — so `["loop/", 3]` had loopctl derive `feature/...` and
    # push it to a machine that enforces `loop/`, which refuses it AFTER the claim. That is the
    # original 846.2 failure, reached through the defence written against it, and it is the
    # disagreement the finding is about: `DispatchPayload.branch_for/2` filtered per entry all
    # along while placement came through here.
    #
    # A meta reaches this without passing `cast_join/1`, which is the only way a non-binary
    # gets in at all — the wire schema refuses one.
    test "a non-binary entry is dropped, and the usable ones still constrain" do
      assert Runners.declared_branch_prefixes(%{branch_prefixes: ["loop/", 3]}) == ["loop/"]
      assert Runners.declared_branch_prefixes(%{branch_prefixes: [3, "loop/"]}) == ["loop/"]
      assert Runners.declared_branch_prefixes(%{branch_prefixes: [nil, %{}]}) == []
    end

    # ONE READING, TWO CALLERS. The pool read and the derivation must filter the same list the
    # same way, which is the thing that drifted.
    test "it agrees with the derivation on which entries are usable" do
      mixed = ["loop/", 3, "agent/"]
      story = %Story{number: 7, id: "a1b2c3d4-e5f6-4789-abcd-ef0123456789"}

      assert DispatchPayload.branch_for(story, mixed) ==
               DispatchPayload.branch_for(
                 story,
                 Runners.declared_branch_prefixes(%{branch_prefixes: mixed})
               )
    end
  end

  describe "tenant isolation" do
    test "tenant B can neither see, fetch, revoke nor authorize tenant A's runner" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {_raw, runner_a} = fixture(:runner, %{tenant_id: tenant_a.id, name: "minis"})

      assert Runners.list_runners(tenant_b.id, include_revoked: true) == []
      assert {:error, :not_found} = Runners.get_runner(tenant_b.id, runner_a.id)
      assert {:error, :not_found} = Runners.revoke_runner(tenant_b.id, runner_a.id)
      refute Runners.authorized?(tenant_b.id, runner_a.id)

      assert [%Runner{id: id}] = Runners.list_runners(tenant_a.id)
      assert id == runner_a.id
      assert is_nil(AdminRepo.get!(Runner, runner_a.id).revoked_at)
    end

    test "two tenants may each enroll a machine of the same name" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {_raw, _a} = fixture(:runner, %{tenant_id: tenant_a.id, name: "minis"})

      assert {:ok, _} = Runners.enroll_runner(tenant_b.id, %{name: "minis"})
    end

    test "each tenant's pool topic is distinct" do
      assert Runners.pool_topic(Ecto.UUID.generate()) != Runners.pool_topic(Ecto.UUID.generate())
    end
  end
end
