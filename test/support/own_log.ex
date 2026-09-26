defmodule Loopctl.OwnLog do
  @moduledoc """
  Captures only the log entries the CALLING process emits.

  `ExUnit.CaptureLog` installs a VM-global handler, so under `async: true` every concurrent
  test's log lands in the captured string. A `refute log =~ ...` over that string then fails
  whenever some other test happens to log the refuted text at the same moment.

  This keys each entry on the pid that emitted it rather than on its wording, and splits on
  entry boundaries rather than on newlines, so a multi-line entry (a pretty-printed reason, a
  stacktrace) is kept whole: every continuation line belongs to the entry that emitted it.
  Only code that runs in the calling process is captured — a line logged from a spawned task
  is not, which is the price of the key.
  """

  import ExUnit.CaptureLog, only: [with_log: 2]

  # ASCII record separator: starts every entry, never appears in a log message.
  @sep "\u001E"

  @doc """
  Runs `fun`, returning `{result, own_log}` where `own_log` joins, in order, every entry the
  calling process logged while it ran. `opts` go to `ExUnit.CaptureLog.with_log/2`.
  """
  @spec with_own_log(keyword(), (-> result)) :: {result, String.t()} when result: term()
  def with_own_log(opts \\ [], fun) do
    # The formatter renders a pid as "pid=<0.1.0>", without the "#PID" of inspect/1.
    me = "pid=#{:erlang.pid_to_list(self())} "

    formatter = [
      format: "#{@sep}$metadata| $message\n",
      metadata: [:pid],
      colors: [enabled: false]
    ]

    {result, log} = with_log(Keyword.merge(opts, formatter), fun)

    own =
      log
      |> String.split(@sep, trim: true)
      |> Enum.filter(&String.starts_with?(&1, me))
      |> Enum.join()

    {result, own}
  end

  @doc "Like `with_own_log/2`, returning only the captured log."
  @spec capture_own_log(keyword(), (-> term())) :: String.t()
  def capture_own_log(opts \\ [], fun) do
    {_result, log} = with_own_log(opts, fun)
    log
  end
end
