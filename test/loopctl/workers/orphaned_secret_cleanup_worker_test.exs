defmodule Loopctl.Workers.OrphanedSecretCleanupWorkerTest do
  @moduledoc """
  US-26.7.1 (#1/#2) — durable retry of a failed compensating secret op.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Workers.OrphanedSecretCleanupWorker, as: Worker

  setup :verify_on_exit!

  describe "delete op" do
    test "retries Secrets.delete and succeeds" do
      test_pid = self()

      Mox.expect(Loopctl.MockSecrets, :delete, fn name ->
        send(test_pid, {:deleted, name})
        :ok
      end)

      assert :ok =
               Worker.perform(%Oban.Job{
                 args: %{"op" => "delete", "secret_name" => "TENANT_AUDIT_KEY_X"}
               })

      assert_received {:deleted, "TENANT_AUDIT_KEY_X"}
    end

    test "treats :not_found as success (already gone)" do
      Mox.expect(Loopctl.MockSecrets, :delete, fn _name -> {:error, :not_found} end)

      assert :ok =
               Worker.perform(%Oban.Job{
                 args: %{"op" => "delete", "secret_name" => "TENANT_AUDIT_KEY_X"}
               })
    end

    test "returns {:error, reason} so Oban retries on a real failure" do
      Mox.expect(Loopctl.MockSecrets, :delete, fn _name -> {:error, :fly_down} end)

      assert {:error, :fly_down} =
               Worker.perform(%Oban.Job{
                 args: %{"op" => "delete", "secret_name" => "TENANT_AUDIT_KEY_X"}
               })
    end
  end

  describe "restore op" do
    test "decrypts the Cloak-wrapped value and restores it via Secrets.set" do
      old_value = :crypto.strong_rand_bytes(32)
      encoded = Worker.encode_secret_value(old_value)
      test_pid = self()

      # The encoded value must NOT be the plaintext key (encrypted at rest).
      refute encoded == Base.encode64(old_value)

      Mox.expect(Loopctl.MockSecrets, :set, fn name, value ->
        send(test_pid, {:restored, name, value})
        :ok
      end)

      assert :ok =
               Worker.perform(%Oban.Job{
                 args: %{
                   "op" => "restore",
                   "secret_name" => "TENANT_AUDIT_KEY_X",
                   "value" => encoded
                 }
               })

      # The worker restored the ORIGINAL plaintext key.
      assert_received {:restored, "TENANT_AUDIT_KEY_X", ^old_value}
    end

    test "returns {:error, reason} so Oban retries when the restore set fails" do
      encoded = Worker.encode_secret_value(:crypto.strong_rand_bytes(32))
      Mox.expect(Loopctl.MockSecrets, :set, fn _name, _value -> {:error, :fly_down} end)

      assert {:error, :fly_down} =
               Worker.perform(%Oban.Job{
                 args: %{
                   "op" => "restore",
                   "secret_name" => "TENANT_AUDIT_KEY_X",
                   "value" => encoded
                 }
               })
    end
  end
end
