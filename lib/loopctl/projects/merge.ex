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

  ## Intake sources keep their repo (#1113)

  A live `pr`/`chg` intake source routes one repo's escalations to its project's channel, and
  sessions find that channel through `resolve_project({repo_url})`. The merge archives the
  source project, so a moved source must land on a project that holds its repo. A target that
  names another repo refuses with `{:merge_strands_source, source_id, repo}`. A target that
  names no repo claims the sources' one repo (as `Intake.prepare_project/2` does at
  enrolment), and refuses the same way when the sources name more than one. A third active
  project already holding that repo refuses with `{:repo_has_project, holder_id}`.

  ## Concurrency

  Both project rows are locked `FOR UPDATE` before anything is read, so two merges of one
  project serialise, and an insert referencing either project (its foreign-key check takes a
  `KEY SHARE` lock on the project row) waits for the merge to commit.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Intake.Source
  alias Loopctl.Projects
  alias Loopctl.Projects.Project
  alias Loopctl.Projects.RepoUrl
  alias Loopctl.TokenUsage.Budget, as: TokenBudget

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

  Returns `{:ok, result}`, or `{:ok, %{already_merged: true, counts: ...}}` for a source already
  merged into this target: that call moves any row written to the archived source since (a
  write that waited on the merge's lock, a session still holding the old id) and nothing else.
  A `:project`-scoped token budget moves with the rows. Errors: `{:error, reason}` with `{:merge_conflicts, conflicts}`, `:same_project`,
  `:not_found`, `:target_not_active`, `:source_not_active`,
  `{:merge_strands_source, source_id, repo}` or `{:repo_has_project, holder_id}`.
  """
  @spec merge_into(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, result()}
          | {:error,
             {:merge_conflicts, [conflict()]}
             | {:merge_strands_source, Ecto.UUID.t(), String.t()}
             | {:repo_has_project, Ecto.UUID.t()}
             | Ecto.Changeset.t()
             | :same_project
             | :not_found
             | :target_not_active
             | :source_not_active}
  def merge_into(tenant_id, source_id, target_id, opts \\ []) do
    # Compared AFTER the cast: two spellings of one UUID (case) are one project.
    with {:ok, source_id} <- Ecto.UUID.cast(source_id),
         {:ok, target_id} <- Ecto.UUID.cast(target_id),
         :ok <- two_projects(source_id, target_id) do
      AdminRepo.transaction(fn -> run(tenant_id, source_id, target_id, opts) end)
      |> unwrap()
    else
      :error -> {:error, :not_found}
      {:error, :same_project} -> {:error, :same_project}
    end
  end

  defp two_projects(id, id), do: {:error, :same_project}
  defp two_projects(_source_id, _target_id), do: :ok

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
         {:ok, how} <- mergeable(source, target),
         {:ok, claim} <- sources_repo(tenant_id, source, target, how) do
      base = %{source_id: source_id, target_id: target_id}
      base = if how == :sweep, do: Map.put(base, :already_merged, true), else: base
      counts = counts(tenant_id, source_id)
      conflicts = conflicts(tenant_id, source_id, target_id)

      cond do
        Keyword.get(opts, :dry_run, false) ->
          {:ok, Map.merge(base, %{dry_run: true, counts: counts, conflicts: conflicts})}

        conflicts != [] ->
          {:error, {:merge_conflicts, conflicts}}

        how == :sweep ->
          sweep(tenant_id, source, target, counts, opts)
          {:ok, Map.merge(base, %{dry_run: false, counts: counts})}

        true ->
          tenant_id
          |> apply_merge(source, target, claim, counts, opts)
          |> merged(base, counts)
      end
    end
  end

  defp merged({:ok, promoted}, base, counts),
    do: {:ok, Map.merge(base, %{dry_run: false, counts: counts, promoted: promoted})}

  defp merged({:error, reason}, _base, _counts), do: AdminRepo.rollback(reason)

  # The repo the merged target must hold for the source's live pr/chg sources, read with both
  # project rows already locked: `{:ok, nil}` when the target already holds it (or nothing
  # needs one), `{:ok, repo}` when a repo-less target must claim it. A sweep moves only rows
  # written after the merge, and no source can be enrolled on an archived project.
  defp sources_repo(_tenant_id, _source, _target, :sweep), do: {:ok, nil}

  defp sources_repo(tenant_id, source, target, :merge) do
    sources =
      from(s in Source,
        where:
          s.tenant_id == ^tenant_id and s.project_id == ^source.id and is_nil(s.revoked_at) and
            s.mode in [:pr, :chg],
        order_by: [asc: s.inserted_at, asc: s.id]
      )
      |> AdminRepo.all()

    keep = target.repo_key || Enum.find_value(sources, &RepoUrl.key(&1.repo_full_name))

    case Enum.find(sources, &(RepoUrl.key(&1.repo_full_name) != keep)) do
      nil when is_nil(target.repo_key) and sources != [] ->
        claimable(tenant_id, hd(sources).repo_full_name, source, target)

      nil ->
        {:ok, nil}

      stranded ->
        {:error, {:merge_strands_source, stranded.id, stranded.repo_full_name}}
    end
  end

  # Read here, before any write, so a dry run answers the refusal the merge would. The source
  # project itself may hold the repo: it is archived before the target claims it.
  defp claimable(tenant_id, repo, source, target) do
    case Projects.repo_holder(tenant_id, RepoUrl.key(repo), target.id) do
      {:ok, %Project{id: holder_id}} when holder_id != source.id ->
        {:error, {:repo_has_project, holder_id}}

      _ ->
        {:ok, repo}
    end
  end

  defp found({:ok, project}), do: {:ok, project}
  defp found(:error), do: {:error, :not_found}

  # A source already merged into THIS target is swept again rather than answered from its
  # status alone: the archived row stays a valid foreign-key target, so a write that waited on
  # the merge's lock, or a session still holding the old id, can land rows on it afterwards.
  # A repeat call moves those and nothing else (no promotion, no second archive).
  defp mergeable(%{status: :archived, metadata: %{"merged_into" => target_id}}, %{
         id: target_id,
         status: :active
       }),
       do: {:ok, :sweep}

  defp mergeable(_source, %{status: status}) when status != :active,
    do: {:error, :target_not_active}

  defp mergeable(%{status: status}, _target) when status != :active,
    do: {:error, :source_not_active}

  defp mergeable(_source, _target), do: {:ok, :merge}

  defp counts(tenant_id, source_id) do
    @project_tables
    |> Map.new(fn table ->
      count =
        from(r in table,
          where: r.tenant_id == type(^tenant_id, :binary_id),
          where: r.project_id == type(^source_id, :binary_id),
          select: count()
        )
        |> AdminRepo.one()

      {table, count}
    end)
    |> Map.put("token_budgets", AdminRepo.aggregate(budget_query(tenant_id, source_id), :count))
  end

  # `token_budgets` names its project by (scope_type :project, scope_id), not a project_id
  # foreign key, so the schema-bound table list cannot see it; it moves with the rest. One
  # budget per scope (`token_budgets_tenant_id_scope_type_scope_id_index`), so a budget on
  # both projects is a conflict.
  defp budget_query(tenant_id, project_id) do
    from(b in TokenBudget,
      where: b.tenant_id == ^tenant_id and b.scope_type == :project and b.scope_id == ^project_id
    )
  end

  defp budget_conflicts(tenant_id, source_id, target_id) do
    case {AdminRepo.one(budget_query(tenant_id, source_id)),
          AdminRepo.one(budget_query(tenant_id, target_id))} do
      {%TokenBudget{id: s}, %TokenBudget{id: t}} ->
        [
          %{
            table: "token_budgets",
            index: "token_budgets_tenant_id_scope_type_scope_id_index",
            source_row_id: s,
            target_row_id: t
          }
        ]

      _ ->
        []
    end
  end

  defp move_rows(tenant_id, source, target) do
    Enum.each(@project_tables, fn table ->
      from(r in table,
        where: r.tenant_id == type(^tenant_id, :binary_id),
        where: r.project_id == type(^source.id, :binary_id)
      )
      |> AdminRepo.update_all(set: [project_id: Ecto.UUID.dump!(target.id)])
    end)

    AdminRepo.update_all(budget_query(tenant_id, source.id), set: [scope_id: target.id])
  end

  defp sweep(tenant_id, source, target, counts, opts) do
    move_rows(tenant_id, source, target)

    if Enum.any?(counts, fn {_table, n} -> n > 0 end) do
      {:ok, _} =
        Multi.new()
        |> Audit.log_in_multi(:audit, fn _ ->
          %{
            tenant_id: tenant_id,
            entity_type: "project",
            entity_id: source.id,
            action: "merged_into_swept",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            metadata: %{"target_id" => target.id, "counts" => counts},
            old_state: %{"status" => "archived"},
            new_state: %{"status" => "archived", "merged_into" => target.id}
          }
        end)
        |> AdminRepo.transaction()
    end

    :ok
  end

  defp conflicts(tenant_id, source_id, target_id) do
    budget_conflicts(tenant_id, source_id, target_id) ++
      unique_key_conflicts(tenant_id, source_id, target_id)
  end

  defp unique_key_conflicts(tenant_id, source_id, target_id) do
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

  defp apply_merge(tenant_id, source, target, claim, counts, opts) do
    move_rows(tenant_id, source, target)

    promoted = source.kind == :work and target.kind == :kb

    # The source is archived before the target claims a repo: while the source is active it may
    # hold that same repo under `projects_tenant_repo_key_active_uidx`.
    source
    |> Ecto.Changeset.change(
      status: :archived,
      metadata: Map.put(source.metadata || %{}, "merged_into", target.id)
    )
    |> AdminRepo.update!()

    with {:ok, changes} <- update_target(target, promoted, claim) do
      audit(tenant_id, source, target, counts, promoted, changes, opts)
      {:ok, promoted}
    end
  end

  defp update_target(target, promoted, claim) do
    changes =
      if(promoted, do: [kind: :work, open_channel: true], else: [])
      |> then(fn changes ->
        if claim do
          url = "https://github.com/#{claim}"
          [{:repo_url, url}, {:repo_key, RepoUrl.key(url)} | changes]
        else
          changes
        end
      end)

    if changes == [] do
      {:ok, []}
    else
      target
      |> Ecto.Changeset.change(changes)
      |> Ecto.Changeset.unique_constraint(:repo_key, name: Project.repo_key_index())
      # A savepoint, so a unique violation from a holder that appeared after `claimable/4`
      # read leaves the transaction usable for the holder lookup; the merge then rolls back.
      |> AdminRepo.update(mode: :savepoint)
      |> case do
        {:ok, _} -> {:ok, changes}
        {:error, changeset} -> Projects.changeset_or_refusal(target.tenant_id, changeset)
      end
    end
  end

  defp audit(tenant_id, source, target, counts, promoted, changes, opts) do
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
      |> maybe_target_audit(tenant_id, source, target, promoted, changes, opts)
      |> AdminRepo.transaction()

    :ok
  end

  defp maybe_target_audit(multi, _tenant_id, _source, _target, _promoted, [], _opts), do: multi

  # One entry for whatever the merge changed on the target, every changed field old and new,
  # as `Intake`'s enrolment claim records it: kind_promoted when the kind moved, otherwise
  # repo_claimed.
  defp maybe_target_audit(multi, tenant_id, source, target, promoted, changes, opts) do
    fields = Keyword.keys(changes)

    Audit.log_in_multi(multi, :promotion_audit, fn _ ->
      %{
        tenant_id: tenant_id,
        entity_type: "project",
        entity_id: target.id,
        action: if(promoted, do: "kind_promoted", else: "repo_claimed"),
        actor_type: Keyword.get(opts, :actor_type, "api_key"),
        actor_id: Keyword.get(opts, :actor_id),
        actor_label: Keyword.get(opts, :actor_label),
        metadata: %{"merged_from" => source.id},
        old_state: target |> Map.take(fields) |> audit_states(),
        new_state: changes |> Map.new() |> audit_states()
      }
    end)
  end

  defp audit_states(map) do
    Map.new(map, fn
      {k, v} when is_atom(v) and not is_boolean(v) and not is_nil(v) ->
        {to_string(k), to_string(v)}

      {k, v} ->
        {to_string(k), v}
    end)
  end
end
