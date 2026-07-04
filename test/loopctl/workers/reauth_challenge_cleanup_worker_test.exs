defmodule Loopctl.Workers.ReauthChallengeCleanupWorkerTest do
  @moduledoc """
  crypto-01 / US-26.7.2 (AC-26.7.2.1) — regression test proving the hourly
  cleanup worker sweeps BOTH `webauthn_reauth_challenges` and
  `webauthn_enrollment_challenges`, so neither table grows unbounded.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.WebAuthn.EnrollmentChallenge
  alias Loopctl.WebAuthn.ReauthChallenge
  alias Loopctl.Workers.ReauthChallengeCleanupWorker

  defp insert_reauth_challenge(tenant_id, expires_at, used_at \\ nil) do
    %ReauthChallenge{tenant_id: tenant_id}
    |> ReauthChallenge.create_changeset(%{
      purpose: "rotate_audit_key",
      challenge: :erlang.term_to_binary(%{bytes: :crypto.strong_rand_bytes(16)}),
      expires_at: expires_at
    })
    |> AdminRepo.insert!()
    |> then(fn row ->
      if used_at do
        row |> Ecto.Changeset.change(used_at: used_at) |> AdminRepo.update!()
      else
        row
      end
    end)
  end

  defp insert_enrollment_challenge(tenant_id, expires_at, used_at \\ nil) do
    %EnrollmentChallenge{tenant_id: tenant_id}
    |> EnrollmentChallenge.create_changeset(%{
      purpose: "enroll_authenticator",
      challenge: :erlang.term_to_binary(%{bytes: :crypto.strong_rand_bytes(16)}),
      expires_at: expires_at
    })
    |> AdminRepo.insert!()
    |> then(fn row ->
      if used_at do
        row |> Ecto.Changeset.change(used_at: used_at) |> AdminRepo.update!()
      else
        row
      end
    end)
  end

  test "deletes expired and used rows from both challenge tables, keeps live unused rows" do
    tenant = fixture(:tenant)
    now = DateTime.utc_now()
    future = DateTime.add(now, 300, :second)
    past = DateTime.add(now, -60, :second)

    expired_reauth = insert_reauth_challenge(tenant.id, past)
    used_reauth = insert_reauth_challenge(tenant.id, future, now)
    live_reauth = insert_reauth_challenge(tenant.id, future)

    expired_enrollment = insert_enrollment_challenge(tenant.id, past)
    used_enrollment = insert_enrollment_challenge(tenant.id, future, now)
    live_enrollment = insert_enrollment_challenge(tenant.id, future)

    assert :ok = ReauthChallengeCleanupWorker.perform(%Oban.Job{args: %{}})

    refute AdminRepo.get(ReauthChallenge, expired_reauth.id)
    refute AdminRepo.get(ReauthChallenge, used_reauth.id)
    assert AdminRepo.get(ReauthChallenge, live_reauth.id)

    refute AdminRepo.get(EnrollmentChallenge, expired_enrollment.id)
    refute AdminRepo.get(EnrollmentChallenge, used_enrollment.id)
    assert AdminRepo.get(EnrollmentChallenge, live_enrollment.id)
  end

  test "is a no-op when both tables are empty of stale rows" do
    tenant = fixture(:tenant)
    future = DateTime.add(DateTime.utc_now(), 300, :second)

    live_reauth = insert_reauth_challenge(tenant.id, future)
    live_enrollment = insert_enrollment_challenge(tenant.id, future)

    assert :ok = ReauthChallengeCleanupWorker.perform(%Oban.Job{args: %{}})

    assert AdminRepo.get(ReauthChallenge, live_reauth.id)
    assert AdminRepo.get(EnrollmentChallenge, live_enrollment.id)
  end
end
