defmodule LoopctlE2e.LiveTest do
  @moduledoc """
  TC-52.9.6: one issue through the real factory on the sandbox repository. Tagged :live and
  excluded unless LOOPCTL_E2E_ORCH_KEY is set (test_helper.exs). Every stage line goes to
  stage-log/<run_id>.log, which the workflow uploads when the run fails (AC-52.9.7).
  """
  use ExUnit.Case, async: true

  alias LoopctlE2e.Client
  alias LoopctlE2e.Run

  @moduletag :live
  @moduletag timeout: :infinity

  test "an issue opened on the sandbox goes from intake to done with nothing left open" do
    {sandbox, _} = Code.eval_file(Path.expand("../../config/sandbox.exs", __DIR__))
    assert {:ok, client} = Client.Req.from_env()

    run_id = Run.run_id()
    File.mkdir_p!("stage-log")
    log_path = Path.join("stage-log", "#{run_id}.log")

    log = fn line ->
      stamped = "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{line}\n"
      File.write!(log_path, stamped, [:append])
      IO.write(stamped)
    end

    case Run.execute(client, sandbox, run_id, log: log) do
      {:ok, ctx} -> log.("done: story #{ctx.story["id"]}, PR ##{ctx.pr}")
      {:error, failure} -> flunk(Run.describe(failure))
    end
  end
end
