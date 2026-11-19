defmodule Loopctl.Repo.Migrations.AddRepoKeyToProjects do
  use Ecto.Migration

  import Ecto.Query

  alias Loopctl.Projects.RepoUrl

  # US-52.1: a repo has one project. `repo_key` is the repo's identity derived from
  # `repo_url` by `RepoUrl.key/1`, the same parser `Projects.resolve_project/2` uses, and at
  # most one ACTIVE project of a tenant may hold a key. The backfill raises, naming the
  # colliding projects, rather than skipping a row: an index that silently left a duplicate
  # active would be the bug this column exists to end.
  def up do
    alter table(:projects) do
      add :repo_key, :string
    end

    flush()

    rows =
      repo().all(
        from(p in "projects",
          where: not is_nil(p.repo_url),
          select: %{id: p.id, tenant_id: p.tenant_id, repo_url: p.repo_url, status: p.status}
        )
      )

    keyed = Enum.map(rows, &Map.put(&1, :repo_key, RepoUrl.key(&1.repo_url)))

    collisions =
      keyed
      |> Enum.filter(&(&1.status == "active" and &1.repo_key))
      |> Enum.group_by(&{&1.tenant_id, &1.repo_key})
      |> Enum.filter(fn {_key, group} -> length(group) > 1 end)

    if collisions != [] do
      detail =
        Enum.map_join(collisions, "; ", fn {{_tenant, key}, group} ->
          "#{key}: " <> Enum.map_join(group, ", ", &Ecto.UUID.cast!(&1.id))
        end)

      raise "two active projects of one tenant share a repo; merge or archive one first: " <>
              detail
    end

    Enum.each(keyed, fn %{id: id, repo_key: key} ->
      if key do
        repo().update_all(from(p in "projects", where: p.id == ^id), set: [repo_key: key])
      end
    end)

    create unique_index(:projects, [:tenant_id, :repo_key],
             name: :projects_tenant_repo_key_active_uidx,
             where: "status = 'active' AND repo_key IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:projects, [:tenant_id, :repo_key],
                     name: :projects_tenant_repo_key_active_uidx
                   )

    alter table(:projects) do
      remove :repo_key
    end
  end
end
