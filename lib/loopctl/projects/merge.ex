defmodule Loopctl.Projects.Merge do
  @moduledoc """
  Merges one project into another (US-52.2), so a repo that grew two projects ends with one
  project and one channel (docs/factory/architecture.md, R5).

  Every row of every table in `project_tables/0` moves from the source's `project_id` to the
  target's, in ONE `AdminRepo` transaction that also archives the source (recording
  `metadata.merged_into`), promotes a `:kb` target to `:work` when the source was a work
  project, and writes one `merged_into` audit entry. Either all of that commits or none of it.

  ## What stays behind, deliberately

  `audit_log` and `search_events` also carry a `project_id`, and neither moves. The audit log
  is append-only and hash-chained, so rewriting it would falsify history; `search_events` is
  telemetry about what was searched where. Both keep naming the source, which stays as an
  archived row pointing at its target. `test/loopctl/projects/merge_test.exs` reads the schema
  and fails when a table with a `project_id` foreign key is missing from `project_tables/0`.

  ## Conflicts

  A per-project unique key held by both projects (a story number, an epic number, a claim
  ref, a channel post's keyed slot, ...) cannot be merged blindly: one row would have to be
  dropped or renumbered, and either is a decision about data the caller owns. The merge reads
  every such key first and refuses with the full list, writing nothing. `unique_keys/0` is the
  list, bound to the schema by the same test.

  ## Concurrency

  Both project rows are locked `FOR UPDATE` before anything is read, so two merges of one
  project serialise, and an insert referencing either project (its foreign-key check takes a
  `KEY SHARE` lock on the project row) waits for the merge to commit.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Projects.Project

  @project_tables ~w(
    agent_run_outcomes article_access_events articles channel_claims channel_posts corpora
    egress_blocked_decisions egress_scope_markings epics intake_records intake_sources memories
    orchestrator_states reply_drafts session_memories skills spec_tuning_drafts stories
    token_usage_reports ui_test_runs webhooks
  )

  # Each per-project unique index, by name, with the columns that collide besides
  # (tenant_id, project_id) and the index's own predicate (`%{a}` is the table alias).
  @unique_keys [
    %{index: "channel_claims_ref_uidx", table: "channel_claims", columns: ~w(ref), where: nil},
    %{
      index: "channel_posts_idempotency_uidx",
      table: "channel_posts",
      columns: ~w(agent_id idempotency_key),
      where: "%{a}.idempotency_key IS NOT NULL AND %{a}.key IS NULL"
    },
    %{
      index: "channel_posts_session_key_uidx",
      table: "channel_posts",
      columns: ~w(agent_id session_id key),
      where: "%{a}.key IS NOT NULL"
    },
    %{
      index: "egress_scope_markings_project_scope_idx",
      table: "egress_scope_markings",
      columns: [],
      where: nil
    },
    %{
      index: "epics_tenant_id_project_id_number_index",
      table: "epics",
      columns: ~w(number),
      where: nil
    },
    %{
      index: "orchestrator_states_tenant_id_project_id_state_key_index",
      table: "orchestrator_states",
      columns: ~w(state_key),
      where: nil
    },
    %{index: "skills_tenant_project_name_index", table: "skills", columns: ~w(name), where: nil},
    %{
      index: "spec_tuning_drafts_pending_uidx",
      table: "spec_tuning_drafts",
      columns: ~w(target_spec_id),
      where: "%{a}.status = 'pending'"
    },
    %{
      index: "stories_tenant_id_project_id_number_index",
      table: "stories",
      columns: ~w(number),
      where: nil
    }
  ]

  @type conflict :: %{
          table: String.t(),
          index: String.t(),
          source_row_id: Ecto.UUID.t(),
          target_row_id: Ecto.UUID.t()
        }

  @type result :: %{
          required(:source_id) => Ecto.UUID.t(),
          required(:target_id) => Ecto.UUID.t(),
          optional(:dry_run) => boolean(),
          optional(:already_merged) => boolean(),
          optional(:promoted) => boolean(),
          optional(:counts) => %{String.t() => non_neg_integer()},
          optional(:conflicts) => [conflict()]
        }

  @doc "The tables whose rows a merge moves."
  @spec project_tables() :: [String.t()]
  def project_tables, do: @project_tables

  @doc "The per-project unique indexes a merge checks for collisions."
  @spec unique_keys() :: [map()]
  def unique_keys, do: @unique_keys

  @doc """
  Merges `source_id` into `target_id`, both projects of `tenant_id`.

  Options: `:dry_run` (counts and conflicts, nothing written), and the audit actor
  `:actor_id`, `:actor_label`, `:actor_type`.

  Returns `{:ok, result}`, `{:ok, %{already_merged: true}}` for a source already merged into
  this target, or `{:error, reason}` with `{:merge_conflicts, conflicts}`, `:same_project`,
  `:not_found`, `:target_not_active` or `:source_not_active`.
  """
  @spec merge_into(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, result()}
          | {:error,
             {:merge_conflicts, [conflict()]}
             | :same_project
             | :not_found
             | :target_not_active
             | :source_not_active}
  def merge_into(tenant_id, source_id, target_id, opts \\ [])

  def merge_into(_tenant_id, id, id, _opts), do: {:error, :same_project}

  def merge_into(tenant_id, source_id, target_id, opts) do
    with {:ok, source_id} <- Ecto.UUID.cast(source_id),
         {:ok, target_id} <- Ecto.UUID.cast(target_id) do
      AdminRepo.transaction(fn -> run(tenant_id, source_id, target_id, opts) end)
      |> unwrap()
    else
      :error -> {:error, :not_found}
    end
  end

  defp unwrap({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp run(tenant_id, source_id, target_id, opts) do
    projects =
      Project
      |> where([p], p.tenant_id == ^tenant_id and p.id in [^source_id, ^target_id])
      |> order_by([p], p.id)
      |> lock("FOR UPDATE")
      |> AdminRepo.all()
      |> Map.new(&{&1.id, &1})

    with {:ok, source} <- Map.fetch(projects, source_id) |> found(),
         {:ok, target} <- Map.fetch(projects, target_id) |> found(),
         :ok <- mergeable(source, target) do
      base = %{source_id: source_id, target_id: target_id}
      counts = counts(tenant_id, source_id)
      conflicts = conflicts(tenant_id, source_id, target_id)

      cond do
        Keyword.get(opts, :dry_run, false) ->
          {:ok, Map.merge(base, %{dry_run: true, counts: counts, conflicts: conflicts})}

        conflicts != [] ->
          {:error, {:merge_conflicts, conflicts}}

        true ->
          promoted = apply_merge(tenant_id, source, target, counts, opts)
          {:ok, Map.merge(base, %{dry_run: false, counts: counts, promoted: promoted})}
      end
    else
      {:already_merged, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp found({:ok, project}), do: {:ok, project}
  defp found(:error), do: {:error, :not_found}

  defp mergeable(%{status: :archived, metadata: %{"merged_into" => target_id}} = source, %{
         id: target_id
       }) do
    {:already_merged, %{source_id: source.id, target_id: target_id, already_merged: true}}
  end

  defp mergeable(_source, %{status: status}) when status != :active,
    do: {:error, :target_not_active}

  defp mergeable(%{status: status}, _target) when status != :active,
    do: {:error, :source_not_active}

  defp mergeable(_source, _target), do: :ok

  defp counts(tenant_id, source_id) do
    Map.new(@project_tables, fn table ->
      count =
        from(r in table,
          where: r.tenant_id == type(^tenant_id, :binary_id),
          where: r.project_id == type(^source_id, :binary_id),
          select: count()
        )
        |> AdminRepo.one()

      {table, count}
    end)
  end

  defp conflicts(tenant_id, source_id, target_id) do
    Enum.flat_map(@unique_keys, fn key ->
      key_sql(key)
      |> AdminRepo.query!([
        Ecto.UUID.dump!(tenant_id),
        Ecto.UUID.dump!(source_id),
        Ecto.UUID.dump!(target_id)
      ])
      |> Map.fetch!(:rows)
      |> Enum.map(fn [s, t] ->
        %{
          table: key.table,
          index: key.index,
          source_row_id: Ecto.UUID.cast!(s),
          target_row_id: Ecto.UUID.cast!(t)
        }
      end)
    end)
  end

  # Identifiers come only from the compile-time `@unique_keys` list, never from input.
  defp key_sql(%{table: table, columns: columns, where: where}) do
    joins = Enum.map(columns, &" AND t.#{&1} = s.#{&1}")

    predicate =
      if where,
        do: " AND " <> alias_where(where, "s") <> " AND " <> alias_where(where, "t"),
        else: ""

    "SELECT s.id, t.id FROM #{table} s JOIN #{table} t ON t.tenant_id = s.tenant_id " <>
      "AND t.project_id = $3#{Enum.join(joins)} " <>
      "WHERE s.tenant_id = $1 AND s.project_id = $2#{predicate} LIMIT 100"
  end

  defp alias_where(where, a), do: String.replace(where, "%{a}", a)

  defp apply_merge(tenant_id, source, target, counts, opts) do
    Enum.each(@project_tables, fn table ->
      from(r in table,
        where: r.tenant_id == type(^tenant_id, :binary_id),
        where: r.project_id == type(^source.id, :binary_id)
      )
      |> AdminRepo.update_all(set: [project_id: Ecto.UUID.dump!(target.id)])
    end)

    promoted = source.kind == :work and target.kind == :kb

    if promoted do
      target |> Ecto.Changeset.change(kind: :work) |> AdminRepo.update!()
    end

    source
    |> Ecto.Changeset.change(
      status: :archived,
      metadata: Map.put(source.metadata || %{}, "merged_into", target.id)
    )
    |> AdminRepo.update!()

    audit(tenant_id, source, target, counts, promoted, opts)
    promoted
  end

  defp audit(tenant_id, source, target, counts, promoted, opts) do
    {:ok, _} =
      Multi.new()
      |> Audit.log_in_multi(:audit, fn _ ->
        %{
          tenant_id: tenant_id,
          entity_type: "project",
          entity_id: source.id,
          action: "merged_into",
          actor_type: Keyword.get(opts, :actor_type, "api_key"),
          actor_id: Keyword.get(opts, :actor_id),
          actor_label: Keyword.get(opts, :actor_label),
          metadata: %{
            "target_id" => target.id,
            "counts" => counts,
            "target_promoted" => promoted
          },
          old_state: %{"status" => to_string(source.status), "slug" => source.slug},
          new_state: %{"status" => "archived", "merged_into" => target.id}
        }
      end)
      |> maybe_promotion_audit(tenant_id, source, target, promoted, opts)
      |> AdminRepo.transaction()

    :ok
  end

  defp maybe_promotion_audit(multi, _tenant_id, _source, _target, false, _opts), do: multi

  defp maybe_promotion_audit(multi, tenant_id, source, target, true, opts) do
    Audit.log_in_multi(multi, :promotion_audit, fn _ ->
      %{
        tenant_id: tenant_id,
        entity_type: "project",
        entity_id: target.id,
        action: "kind_promoted",
        actor_type: Keyword.get(opts, :actor_type, "api_key"),
        actor_id: Keyword.get(opts, :actor_id),
        actor_label: Keyword.get(opts, :actor_label),
        metadata: %{"merged_from" => source.id},
        old_state: %{"kind" => "kb"},
        new_state: %{"kind" => "work"}
      }
    end)
  end
end
