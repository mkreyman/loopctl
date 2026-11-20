defmodule Sandbox do
  @moduledoc """
  loopctl's e2e sandbox. Each nightly run adds `Sandbox.Runs.R<run_id>` under
  lib/sandbox/runs/, whose `value/0` returns its run id; nothing prunes them.
  """
end
