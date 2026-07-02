defmodule Loopctl.Workers.PendingEnrollmentCleanupWorker do
  @moduledoc """
  US-26.0.1 — Oban worker that deletes half-finished tenant signups.

  A tenant row enters `:pending_enrollment` status the moment the
  signup ceremony inserts it, and flips to `:active` only once every
  authenticator verification succeeds. Any tenant still in
  `:pending_enrollment` after the TTL (15 minutes by default) is
  assumed to be an abandoned ceremony and deleted.

  Scheduled every 5 minutes via the Oban Cron plugin. See
  `config/config.exs`.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant

  @impl Oban.Worker
  def perform(_job) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-Tenants.pending_enrollment_ttl_seconds(), :second)

    # Fetch the abandoned tenants first purely so we can log their IDs.
    # The SELECT is observability only — it is NOT a source of truth for
    # the DELETE. A tenant whose WebAuthn activation Multi commits in the
    # (sub-millisecond) window between this SELECT and the DELETE below
    # would flip to `:active`; re-selecting by id alone would then destroy
    # a legitimately-activated tenant. So `delete_abandoned/2` re-checks
    # the FULL predicate (`:pending_enrollment` AND older than the cutoff)
    # atomically at delete time — an activated tenant is excluded.
    abandoned =
      from(t in Tenant,
        where: t.status == :pending_enrollment,
        where: t.inserted_at < ^cutoff,
        select: %{id: t.id, slug: t.slug, inserted_at: t.inserted_at}
      )
      |> AdminRepo.all()

    if abandoned != [] do
      ids = Enum.map(abandoned, & &1.id)

      {deleted_count, _} = delete_abandoned(ids, cutoff)

      Logger.warning(
        "PendingEnrollmentCleanupWorker deleted #{deleted_count} abandoned " <>
          "signup tenants (of #{length(ids)} candidates): #{inspect(ids)}"
      )
    end

    :ok
  end

  @doc """
  Atomically deletes the candidate tenants that are STILL abandoned.

  The DELETE re-checks the full abandonment predicate — `:pending_enrollment`
  status AND `inserted_at` older than `cutoff` — bounded to the observed
  `ids`. This closes the SELECT-then-DELETE race: a candidate that activated
  (or was otherwise transitioned out of `:pending_enrollment`) after the
  observing SELECT no longer matches and is left untouched. Deleting a still
  pending tenant cascades to its `root_authenticators` / reauth challenges via
  `on_delete: :delete_all`, which is the intended cleanup of an abandoned
  ceremony.

  Returns the `{count, nil}` tuple from `delete_all/1`.
  """
  @spec delete_abandoned([binary()], DateTime.t()) :: {non_neg_integer(), nil}
  def delete_abandoned(ids, cutoff) do
    from(t in Tenant,
      where: t.id in ^ids,
      where: t.status == :pending_enrollment,
      where: t.inserted_at < ^cutoff
    )
    |> AdminRepo.delete_all()
  end
end
