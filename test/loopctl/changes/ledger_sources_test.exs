defmodule Loopctl.Changes.LedgerSourcesTest do
  @moduledoc """
  Issue #1047: sending is not routing. A `pr` source holding the chg credentials, and a
  `ledger` source on a `:kb` scope, authenticate on the chg ledger and change-event endpoints;
  only a `chg` source's events move anything. The merge precondition's half (a `pr` source's
  story still answers from the pull request) is in
  `Loopctl.Delivery.MergePreconditionIntegrationTest`, and the review-dispatch half in
  `LoopctlWeb.ChgReviewDispatchControllerTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Landings
  alias Loopctl.Changes.Ledger
  alias Loopctl.Changes.Signature
  alias Loopctl.Intake
  alias Loopctl.Intake.Source

  setup :verify_on_exit!

  defp signed(secret, raw) do
    ts = Integer.to_string(System.os_time(:second))

    %{
      raw_body: raw,
      timestamp: ts,
      signature: Signature.header(secret, Signature.delivery_string(ts, raw))
    }
  end

  defp batch(repo) do
    Jason.encode!(%{
      rows: [
        %{
          "v" => 1,
          "kind" => "gate",
          "repo" => repo,
          "host" => "minis",
          "sha" => "0123456789abcdef0123456789abcdef01234567",
          "at_ms" => 1_763_400_000_000,
          "verdict" => "pass",
          "ms" => 12
        }
      ]
    })
  end

  defp push(ctx, attrs) do
    raw = Jason.encode!(build(:chg_event, Map.merge(%{repo: ctx.source.repo_full_name}, attrs)))
    Events.receive_push(ctx.source.id, signed(ctx.secret, raw))
  end

  defp events(ctx, change_id),
    do: Events.list_events(ctx.source.tenant_id, ctx.source.repo_full_name, change_id)

  defp bindings(tenant_id),
    do: AdminRepo.all(from(b in Binding, where: b.tenant_id == ^tenant_id))

  defp chg_credentials(tenant_id) do
    root = fixture(:chg_root_dispatch, %{tenant_id: tenant_id})
    %{change_events_secret: String.duplicate("s", 32), chg_root_dispatch_id: root.id}
  end

  describe "a pr source holding the chg credentials" do
    setup do
      fixture(:ledger_source, %{mode: "pr"})
    end

    test "authenticates a signed ledger batch and stays pr", ctx do
      assert ctx.source.mode == :pr

      assert {:ok, %{inserted: 1, duplicates: 0, rejected: []}} =
               Ledger.receive_batch(ctx.source.id, signed(ctx.secret, batch("mkreyman/infra")))

      assert [%{kind: "gate", source_id: source_id}] = Ledger.list_rows(ctx.source.tenant_id)
      assert source_id == ctx.source.id
      assert AdminRepo.get!(Source, ctx.source.id).mode == :pr
    end

    test "its change events are stored and audited but routed nowhere: no binding", ctx do
      story = fixture(:story, %{tenant_id: ctx.source.tenant_id})

      assert {:ok, %{outcome: :applied, applied_seq: 1}} =
               push(ctx, %{
                 change_id: "C1",
                 event_seq: 1,
                 kind: "submitted",
                 data: %{"story_id" => story.id}
               })

      assert [%Event{} = event] = events(ctx, "C1")
      assert event.applied_at
      refute event.routed
      assert event.effect == %{"effect" => "recorded", "routed" => false}
      assert bindings(ctx.source.tenant_id) == []
    end

    test "a pr source whose credentials were cleared is refused", ctx do
      {:ok, _} =
        Intake.update_source(ctx.source.tenant_id, ctx.source.id, %{
          change_events_secret: nil,
          chg_root_dispatch_id: nil
        })

      assert {:error, :unauthorized} =
               Ledger.receive_batch(ctx.source.id, signed(ctx.secret, batch("mkreyman/infra")))

      assert {:error, :unauthorized} = push(ctx, %{change_id: "C1"})
      assert Ledger.list_rows(ctx.source.tenant_id) == []
    end

    test "a pr source whose root is revoked is refused", ctx do
      {1, _} =
        AdminRepo.update_all(
          from(d in Loopctl.Dispatches.Dispatch, where: d.id == ^ctx.root.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert {:error, :unauthorized} =
               Ledger.receive_batch(ctx.source.id, signed(ctx.secret, batch("mkreyman/infra")))
    end

    test "a pr source enrolled with the secret but no root is refused (root required)" do
      tenant = fixture(:tenant)
      secret = String.duplicate("q", 32)

      {_ws, source} =
        fixture(:intake_source, %{
          tenant_id: tenant.id,
          repo_full_name: "mkreyman/chg",
          change_events_secret: secret
        })

      assert source.mode == :pr

      assert {:error, :unauthorized} =
               Ledger.receive_batch(source.id, signed(secret, batch("mkreyman/chg")))
    end
  end

  describe "a pr source with no chg credentials" do
    test "is refused as before" do
      {_ws, source} = fixture(:intake_source, %{repo_full_name: "mkreyman/infra"})

      assert {:error, :unauthorized} =
               Ledger.receive_batch(
                 source.id,
                 signed(String.duplicate("x", 32), batch("mkreyman/infra"))
               )
    end
  end

  describe "the mode is read when an event APPLIES, not when it arrives" do
    test "an event held under chg and applied after a switch to pr is unrouted" do
      ctx = fixture(:chg_source, %{})
      assert {:ok, %{outcome: :held}} = push(ctx, %{change_id: "C1", event_seq: 2})

      {:ok, _} = Intake.update_source(ctx.source.tenant_id, ctx.source.id, %{mode: "pr"})

      assert {:ok, %{outcome: :applied, applied_seq: 2}} =
               push(ctx, %{change_id: "C1", event_seq: 1})

      assert [%Event{routed: false}, %Event{routed: false}] = events(ctx, "C1")
    end
  end

  describe "a chg source is unchanged" do
    test "its events are routed" do
      ctx = fixture(:chg_source, %{})
      assert {:ok, %{outcome: :applied}} = push(ctx, %{change_id: "C1", event_seq: 1})

      assert [%Event{routed: true, effect: %{"effect" => "recorded"} = effect}] =
               events(ctx, "C1")

      refute Map.has_key?(effect, "routed")
    end
  end

  describe "an unrouted event is evidence for nothing" do
    test "a landed event a pr source delivered is not the change's landed revision" do
      ctx = fixture(:chg_source, %{})
      routed_sha = String.duplicate("1", 40)

      assert {:ok, _} =
               push(ctx, %{change_id: "C1", event_seq: 1, kind: "landed", sha: routed_sha})

      {:ok, _} = Intake.update_source(ctx.source.tenant_id, ctx.source.id, %{mode: "pr"})

      assert {:ok, _} =
               push(ctx, %{
                 change_id: "C1",
                 event_seq: 2,
                 kind: "landed",
                 sha: String.duplicate("2", 40)
               })

      repo = Events.repo_key(ctx.source.repo_full_name)
      binding = %Binding{repo: repo, change_id: "C1"}

      assert %{{^repo, "C1"} => %{sha: ^routed_sha, event_seq: 1}} =
               Landings.newest_applied_landings(AdminRepo, ctx.source.tenant_id, [binding])
    end
  end

  describe "mode ledger on a kb scope" do
    setup do
      fixture(:ledger_source, %{})
    end

    test "enrols on an active kb scope with both credentials", ctx do
      assert ctx.source.mode == :ledger
      assert ctx.source.project_id == ctx.project.id
      assert ctx.project.kind == :kb
    end

    test "accepts a signed ledger batch and records its events unrouted", ctx do
      assert {:ok, %{inserted: 1}} =
               Ledger.receive_batch(ctx.source.id, signed(ctx.secret, batch("mkreyman/infra")))

      assert {:ok, %{outcome: :applied}} = push(ctx, %{change_id: "C1", event_seq: 1})
      assert [%Event{routed: false}] = events(ctx, "C1")
    end

    test "is never a project's dispatch binding", ctx do
      tenant_id = ctx.source.tenant_id
      kb_id = ctx.project.id

      assert {:error, {:no_intake_source, ^kb_id}} = Intake.source_for_project(tenant_id, kb_id)

      assert {:error, {:no_intake_source, ^kb_id}} =
               tenant_id |> Intake.list_sources() |> Intake.select_project_source(kb_id)

      refute ctx.source.id in AdminRepo.all(
               from(s in Intake.binding_sources_query(tenant_id), select: s.id)
             )
    end

    test "is never chosen, and never makes a project's real source ambiguous", ctx do
      work = fixture(:project, %{tenant_id: ctx.source.tenant_id})

      {_ws, pr_source} =
        fixture(:intake_source, %{
          tenant_id: ctx.source.tenant_id,
          project_id: work.id,
          repo_full_name: "mkreyman/home_care_billing"
        })

      # Enrolment cannot put a ledger source on a work project, so the rule is pinned on the
      # list itself: a ledger row naming the same project is neither chosen nor counted.
      stray = %{ctx.source | project_id: work.id}
      work_id = work.id

      assert {:ok, ^pr_source} = Intake.select_project_source([stray, pr_source], work.id)

      assert {:error, {:no_intake_source, ^work_id}} =
               Intake.select_project_source([stray], work.id)
    end

    test "refuses every GitHub delivery", ctx do
      %{webhook_secret: webhook_secret} = rotate_free_webhook_secret(ctx.source)
      raw = Jason.encode!(build(:github_issues_payload, %{repo: "mkreyman/infra"}))

      assert {:error, :unauthorized} =
               Intake.receive_github_delivery(ctx.source.id, %{
                 raw_body: raw,
                 signature: Loopctl.Intake.Signature.header(webhook_secret, raw),
                 event: "issues",
                 delivery_id: Ecto.UUID.generate(),
                 content_type: "application/json"
               })

      assert Intake.list_records(ctx.source.tenant_id) == []
    end

    test "cannot be switched to pr or chg", ctx do
      for mode <- ["pr", "chg"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Intake.update_source(ctx.source.tenant_id, ctx.source.id, %{mode: mode})

        assert %{mode: [message]} = errors_on(changeset)
        assert message =~ "cannot move a source between a work project and a kb scope"
      end

      assert AdminRepo.get!(Source, ctx.source.id).mode == :ledger
    end

    test "tenant isolation: another tenant sees none of its rows and cannot enrol on its scope",
         ctx do
      assert {:ok, %{inserted: 1}} =
               Ledger.receive_batch(ctx.source.id, signed(ctx.secret, batch("mkreyman/infra")))

      other = fixture(:tenant)
      assert Ledger.list_rows(other.id) == []
      assert Intake.list_sources(other.id) == []

      assert {:error, %Ecto.Changeset{} = changeset} =
               Intake.create_source(
                 other.id,
                 Map.merge(
                   %{repo_full_name: "mkreyman/chg", project_id: ctx.project.id, mode: "ledger"},
                   chg_credentials(other.id)
                 )
               )

      assert %{project_id: ["project not found"]} = errors_on(changeset)
    end
  end

  describe "ledger enrolment refusals" do
    setup do
      %{tenant: fixture(:tenant)}
    end

    test "a ledger source on a work project is refused", %{tenant: tenant} do
      work = fixture(:project, %{tenant_id: tenant.id})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Intake.create_source(
                 tenant.id,
                 Map.merge(
                   %{repo_full_name: "mkreyman/infra", project_id: work.id, mode: "ledger"},
                   chg_credentials(tenant.id)
                 )
               )

      assert %{project_id: [message]} = errors_on(changeset)
      assert message =~ "must be an active kb scope"
    end

    test "a pr or chg source on a kb scope is refused", %{tenant: tenant} do
      kb = fixture(:project, %{tenant_id: tenant.id, kind: :kb})

      for mode <- ["pr", "chg"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Intake.create_source(
                   tenant.id,
                   Map.merge(
                     %{repo_full_name: "mkreyman/infra", project_id: kb.id, mode: mode},
                     chg_credentials(tenant.id)
                   )
                 )

        assert %{project_id: ["must be an active work project"]} = errors_on(changeset)
      end
    end

    test "a ledger source needs both credentials", %{tenant: tenant} do
      kb = fixture(:project, %{tenant_id: tenant.id, kind: :kb})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Intake.create_source(tenant.id, %{
                 repo_full_name: "mkreyman/infra",
                 project_id: kb.id,
                 mode: "ledger"
               })

      assert %{
               change_events_secret: ["is required when mode is ledger"],
               chg_root_dispatch_id: ["is required when mode is ledger"]
             } = errors_on(changeset)
    end

    test "a ledger source's root is judged like a chg one", %{tenant: tenant} do
      kb = fixture(:project, %{tenant_id: tenant.id, kind: :kb})
      revoked = fixture(:chg_root_dispatch, %{tenant_id: tenant.id, revoked: true})

      assert {:error, :chg_root_invalid} =
               Intake.create_source(tenant.id, %{
                 repo_full_name: "mkreyman/infra",
                 project_id: kb.id,
                 mode: "ledger",
                 change_events_secret: String.duplicate("s", 32),
                 chg_root_dispatch_id: revoked.id
               })
    end

    test "a write to a ledger source whose kept root was revoked is chg_root_invalid", %{
      tenant: tenant
    } do
      %{source: source, root: root} = fixture(:ledger_source, %{tenant_id: tenant.id})

      {1, _} =
        AdminRepo.update_all(
          from(d in Loopctl.Dispatches.Dispatch, where: d.id == ^root.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert {:error, :chg_root_invalid} =
               Intake.update_source(tenant.id, source.id, %{base_branch: "main"})

      fresh = fixture(:chg_root_dispatch, %{tenant_id: tenant.id})

      assert {:ok, %Source{chg_root_dispatch_id: fresh_id}} =
               Intake.update_source(tenant.id, source.id, %{chg_root_dispatch_id: fresh.id})

      assert fresh_id == fresh.id
    end

    test "a pr source cannot be switched to ledger", %{tenant: tenant} do
      %{source: source} = fixture(:ledger_source, %{tenant_id: tenant.id, mode: "pr"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Intake.update_source(tenant.id, source.id, %{mode: "ledger"})

      assert %{mode: [_message]} = errors_on(changeset)
      assert AdminRepo.get!(Source, source.id).mode == :pr
    end
  end

  # The webhook secret is returned once by `create_source/3` and the fixture drops it, so the
  # test sets a known one directly: the point is that even a CORRECT signature is refused.
  defp rotate_free_webhook_secret(source) do
    secret = String.duplicate("w", 64)

    source
    |> Ecto.Changeset.change(webhook_secret: secret)
    |> AdminRepo.update!()

    %{webhook_secret: secret}
  end
end
