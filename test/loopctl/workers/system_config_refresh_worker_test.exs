defmodule Loopctl.Workers.SystemConfigRefreshWorkerTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.SystemConfig
  alias Loopctl.Workers.SystemConfigRefreshWorker

  setup :verify_on_exit!

  test "perform/1 primes the SystemConfig cache from the DB and returns :ok" do
    # Uniquely-keyed row (async-safe): absent from the VM-global cache until a
    # refresh runs, so a hit proves the worker performed the reload.
    setting = fixture(:system_config, value: 8080)
    assert SystemConfig.get_int(setting.key, -1) == -1

    assert :ok = SystemConfigRefreshWorker.perform(%Oban.Job{args: %{}})
    assert SystemConfig.get_int(setting.key, -1) == 8080
  end
end
