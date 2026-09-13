defmodule Loopctl.Delivery.StoryStage do
  @moduledoc """
  Schema for the `story_stages` table — where one story is in the delivery loop (issue #803,
  design §3). One row per `(tenant_id, story_id)`.

  - `stage` — one of `Loopctl.Delivery.StageMachine.stages/0`.
  - `claim_epoch` — the `stories.claim_epoch` the row was last written under. A row behind
    the story's is stale: the claim that drove it has been released.
  - side-effect identities — `runner_id`, `worktree_path`, `branch`, `pr_number`,
    `head_sha`, `merge_sha`, `release_id`, each written by its stage BEFORE the effect.
  - `attempts` — how many times each failure edge has been taken, keyed by edge name.
  - `escalation_reason` — why the story last escalated (required while `escalated`).
  - `lock_version` — incremented by every write, so an observer can tell two reads of the
    same stage apart.

  ## Trust boundary

  Every field is set programmatically by `Loopctl.Delivery.Stages`; there is no caller
  changeset, so nothing here can be mass-assigned.

  ## Isolation

  Read and written through `Loopctl.Delivery.Stages` on the RLS-enforced `Loopctl.Repo`
  with an explicit `tenant_id` predicate as well. The one exception is the runner-lost
  release hook, which runs inside each claim release's `AdminRepo` transaction — see
  `Loopctl.Delivery.Stages.follow_release/5`.
  """

  use Loopctl.Schema

  alias Loopctl.Delivery.StageMachine

  @type t :: %__MODULE__{}

  schema "story_stages" do
    tenant_field()
    field :story_id, :binary_id
    field :stage, Ecto.Enum, values: StageMachine.stages()
    field :claim_epoch, :integer
    field :runner_id, :binary_id
    field :worktree_path, :string
    field :branch, :string
    field :pr_number, :integer
    field :head_sha, :string
    field :merge_sha, :string
    field :release_id, :string
    field :attempts, :map, default: %{}
    field :escalation_reason, :string
    field :lock_version, :integer, default: 0

    timestamps()
  end
end
