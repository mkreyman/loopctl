defmodule Loopctl.Workers.BulkDeleteTokenCleanupWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.BulkDeleteToken
  alias Loopctl.Workers.BulkDeleteTokenCleanupWorker

  describe "perform/1" do
    test "deletes expired bulk delete tokens" do
      tenant = fixture(:tenant)
      now = DateTime.utc_now()
      expired_at = DateTime.add(now, -3600, :second)
      future_at = DateTime.add(now, 3600, :second)
      article_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      # Insert an expired token
      AdminRepo.insert!(%BulkDeleteToken{
        tenant_id: tenant.id,
        article_ids: article_ids,
        expires_at: expired_at
      })

      # Insert a still-valid token
      valid_token =
        AdminRepo.insert!(%BulkDeleteToken{
          tenant_id: tenant.id,
          article_ids: article_ids,
          expires_at: future_at
        })

      assert :ok = BulkDeleteTokenCleanupWorker.perform(%Oban.Job{})

      # Valid token still exists
      assert AdminRepo.get!(BulkDeleteToken, valid_token.id) != nil

      # Only the valid token should remain
      remaining = AdminRepo.all(BulkDeleteToken)
      assert length(remaining) == 1
      assert hd(remaining).id == valid_token.id
    end

    test "succeeds when no expired tokens exist" do
      assert :ok = BulkDeleteTokenCleanupWorker.perform(%Oban.Job{})
    end
  end
end
