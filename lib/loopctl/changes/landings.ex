defmodule Loopctl.Changes.Landings do
  @moduledoc """
  The two reads every chg custody gate must agree on (Epic 47): which of a story's change
  bindings is its NEWEST, and which `landed` event of that binding's change is its newest
  APPLIED one. `Loopctl.Changes.ReviewCustody` (US-47.5, the landed-review gate) and
  `Loopctl.Changes.TrunkEvidence` (US-47.6, the trunk gate) both read them here, so the two
  gates can never judge different landings of the same story.

  The newest binding is the current one when it is unsuperseded; a story whose newest binding
  is superseded has no current binding. Both reads are set-based, so a batch costs one query
  each, and tenant-scoped on `repo` (default `AdminRepo`), the custody-read convention.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.Event
  alias Loopctl.Intake.Source

  @type landing :: %{
          id: Ecto.UUID.t(),
          sha: String.t() | nil,
          event_seq: integer(),
          data: map(),
          source_repo: String.t() | nil
        }

  @doc "Each story's newest binding, keyed by story id; a story with none is absent."
  @spec newest_bindings(Ecto.Repo.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          %{optional(Ecto.UUID.t()) => Binding.t()}
  def newest_bindings(repo \\ AdminRepo, tenant_id, story_ids) do
    repo.all(
      from b in Binding,
        where: b.tenant_id == ^tenant_id and b.story_id in ^story_ids,
        distinct: [asc: b.story_id],
        order_by: [desc: is_nil(b.superseded_at), desc: b.inserted_at, desc: b.id]
    )
    |> Map.new(&{&1.story_id, &1})
  end

  @doc "`newest_bindings/3` for one story: the binding, or nil."
  @spec newest_binding(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: Binding.t() | nil
  def newest_binding(repo \\ AdminRepo, tenant_id, story_id),
    do: Map.get(newest_bindings(repo, tenant_id, [story_id]), story_id)

  @doc """
  The newest APPLIED `landed` event of each binding's change, keyed by `{repo, change_id}`,
  with the `repo_full_name` of the intake source that delivered it (`source_repo`).
  """
  @spec newest_applied_landings(Ecto.Repo.t(), Ecto.UUID.t(), [Binding.t()]) ::
          %{optional({String.t(), String.t()}) => landing()}
  def newest_applied_landings(repo \\ AdminRepo, tenant_id, bindings)

  def newest_applied_landings(_repo, _tenant_id, []), do: %{}

  def newest_applied_landings(repo, tenant_id, bindings) do
    keys = MapSet.new(bindings, &{&1.repo, &1.change_id})

    repo.all(
      from e in Event,
        left_join: s in Source,
        on: s.id == e.source_id and s.tenant_id == e.tenant_id,
        where:
          e.tenant_id == ^tenant_id and e.repo in ^Enum.map(bindings, & &1.repo) and
            e.change_id in ^Enum.map(bindings, & &1.change_id) and e.kind == "landed" and
            not is_nil(e.applied_at),
        distinct: [asc: e.repo, asc: e.change_id],
        order_by: [desc: e.event_seq],
        select: %{
          key: {e.repo, e.change_id},
          landing: %{
            id: e.id,
            sha: e.sha,
            event_seq: e.event_seq,
            data: e.data,
            source_repo: s.repo_full_name
          }
        }
    )
    |> Enum.filter(&MapSet.member?(keys, &1.key))
    |> Map.new(&{&1.key, &1.landing})
  end

  @doc "`newest_applied_landings/3` for one binding: the landing, or nil."
  @spec newest_applied_landing(Ecto.Repo.t(), Ecto.UUID.t(), Binding.t()) :: landing() | nil
  def newest_applied_landing(repo \\ AdminRepo, tenant_id, %Binding{} = binding),
    do:
      Map.get(
        newest_applied_landings(repo, tenant_id, [binding]),
        {binding.repo, binding.change_id}
      )
end
