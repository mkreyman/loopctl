defmodule LoopctlE2e.TwoSessions do
  @moduledoc """
  Scenario `two_sessions_one_repo` (US-52.20): two sessions on one machine and one repo
  never collide.

  Two real MCP server processes (`LoopctlE2e.Mcp`) start with the same LOOPCTL_AGENT_KEY,
  different session ids and two worktrees of one local clone of the sandbox repo. Each is a
  holder (US-52.13); each switches its worktree to its own branch, and its heartbeat opens
  that branch's work item (US-52.18). Then session B reaches for A's item on every claimant
  verb and for A's channel claim, and is refused each time (US-52.14). Then A is SIGKILLed,
  and the server ends A's holder by its lease and frees A's item without touching B's
  (US-52.19). B ends its holder, and nothing the scenario opened is left open.

  Every loopctl read goes through the two sessions' MCP tools (AC-52.20.5): no database, no
  server config. The clone is local: the branch open reads only the branch name and the
  `origin` URL, so nothing is pushed and nothing needs a GitHub token.

  Waits are bounded: the item open by two heartbeat intervals plus a margin, the lapse by
  the deployed lease (read from B's heartbeat answer) plus two reclaim sweeps
  (`@sweep_interval_s`, the ReclaimExpiredClaimsWorker cron, lib/loopctl/oban_config.ex)
  plus 60 s. A wait past its bound fails naming what it last saw.

  Everything effectful is an argument, so the unit test drives the scenario with fake
  sessions: `deps.start_session`, `deps.call`, `deps.kill`, `deps.stop`, `deps.git`,
  `deps.now_ms`, `deps.utc_now`, `deps.sleep`, `deps.log`.
  """

  @sweep_interval_s 300
  @margin_s 60
  @poll_ms 10_000

  @type failure :: %{step: atom(), last_state: String.t()}

  @doc """
  Runs the scenario. `cfg` carries `:project_id`, `:repo_url` (the sandbox's origin URL),
  `:run_id` and `:dir` (an empty directory the clone goes in).
  """
  @spec run(map(), map()) :: {:ok, map()} | {:error, failure()}
  def run(cfg, deps) do
    with {:ok, wts} <- clone(cfg, deps),
         {:ok, a} <- start(deps, cfg, :a, wts.a) do
      # Every session that started is stopped, whatever the steps after it did (a failed
      # start of B, a step that raised): an unstopped one keeps heartbeating its holder.
      try do
        with {:ok, b} <- start(deps, cfg, :b, wts.b) do
          try do
            steps(deps, %{cfg: cfg, a: a, b: b}, wts)
          after
            deps.stop.(b)
          end
        end
      after
        # A killed session's port is already closed; stop/1 on it is a no-op.
        deps.stop.(a)
      end
    end
  end

  defp steps(deps, ctx, wts) do
    with {:ok, ctx} <- holders(deps, ctx),
         {:ok, ctx} <- open_items(deps, ctx, wts),
         {:ok, ctx} <- channel_refusal(deps, ctx),
         {:ok, ctx} <- verb_refusals(deps, ctx),
         {:ok, ctx} <- lapse(deps, ctx),
         do: finish(deps, ctx)
  end

  # --- setup ---

  defp clone(cfg, deps) do
    base = Path.join(cfg.dir, "sandbox")
    wt_a = Path.join(cfg.dir, "wt-a")
    wt_b = Path.join(cfg.dir, "wt-b")

    steps = [
      ["init", "--quiet", "--initial-branch=master", base],
      ["-C", base, "remote", "add", "origin", cfg.repo_url],
      [
        "-C",
        base,
        "-c",
        "user.name=loopctl-e2e",
        "-c",
        "user.email=e2e@loopctl.invalid",
        "commit",
        "--quiet",
        "--allow-empty",
        "-m",
        "e2e #{cfg.run_id}"
      ],
      # Detached, so neither session has a branch to open until the scenario switches it.
      ["-C", base, "worktree", "add", "--quiet", "--detach", wt_a],
      ["-C", base, "worktree", "add", "--quiet", "--detach", wt_b]
    ]

    case run_git(deps, steps) do
      :ok -> {:ok, %{a: wt_a, b: wt_b}}
      {:error, why} -> fail(:clone, why)
    end
  end

  defp run_git(deps, steps) do
    Enum.reduce_while(steps, :ok, fn args, :ok ->
      case deps.git.(args) do
        :ok -> {:cont, :ok}
        {:error, why} -> {:halt, {:error, "git #{Enum.join(args, " ")}: #{why}"}}
      end
    end)
  end

  defp start(deps, cfg, name, worktree) do
    case deps.start_session.(%{name: name, worktree: worktree, session_id: session_id(cfg, name)}) do
      {:ok, session} -> {:ok, session}
      {:error, why} -> fail(:"start_#{name}", inspect(why))
    end
  end

  @doc "The Claude session id each scenario process runs as: unique per run and per session."
  @spec session_id(map(), :a | :b) :: String.t()
  def session_id(cfg, name), do: "e2e-#{name}-#{cfg.run_id}"

  @doc "The branch each session works on."
  @spec branch(map(), :a | :b) :: String.t()
  def branch(cfg, name), do: "e2e/#{name}-#{cfg.run_id}"

  @doc "The channel ref session A claims."
  @spec ref(map()) :: String.t()
  def ref(cfg), do: "e2e-ref-#{cfg.run_id}"

  # --- AC-52.20.1 ---

  defp holders(deps, ctx) do
    with {:ok, ha} <- beat(deps, ctx.a, :holder_a),
         {:ok, hb} <- beat(deps, ctx.b, :holder_b) do
      a = ha["holder"]
      b = hb["holder"]

      cond do
        not ha["using_holder_credential"] or not hb["using_holder_credential"] ->
          fail(:holders, "a session is not on a holder credential: #{inspect({ha, hb})}")

        a["id"] == b["id"] ->
          fail(:holders, "both sessions are holder #{a["id"]}")

        a["agent_id"] != b["agent_id"] or a["host"] != b["host"] ->
          fail(:holders, "agent or host differ: #{inspect({a, b})}")

        a["kind"] != "interactive" or b["kind"] != "interactive" ->
          fail(:holders, "kinds #{a["kind"]}, #{b["kind"]}")

        true ->
          deps.log.(
            "holders: A #{a["id"]}, B #{b["id"]}, agent #{a["agent_id"]}, host #{a["host"]}"
          )

          {:ok,
           Map.merge(ctx, %{holder_a: a["id"], holder_b: b["id"], heartbeat_s: heartbeat_s(ha)})}
      end
    end
  end

  defp beat(deps, session, step) do
    case deps.call.(session, "holder_heartbeat", %{}) do
      {:ok, %{"holder" => %{"id" => _}} = status} -> {:ok, status}
      other -> fail(step, "holder_heartbeat: #{inspect(other, limit: 8)}")
    end
  end

  defp heartbeat_s(%{"lease" => %{"heartbeat_seconds" => s}}) when is_integer(s), do: s
  defp heartbeat_s(_status), do: 60

  # --- AC-52.20.2 ---

  defp open_items(deps, ctx, wts) do
    with :ok <- switch(deps, ctx.cfg, :a, wts.a),
         :ok <- switch(deps, ctx.cfg, :b, wts.b) do
      bound_ms = (2 * ctx.heartbeat_s + @margin_s) * 1000
      deadline = deps.now_ms.() + bound_ms

      poll(deps, :items_opened, deadline, fn -> items_held(deps, ctx) end)
    end
  end

  defp items_held(deps, ctx) do
    with {:ok, a} <- item(deps, ctx, :a),
         {:ok, b} <- item(deps, ctx, :b) do
      cond do
        a["assigned_holder_id"] != ctx.holder_a ->
          {:wait, "A's item held by #{inspect(a["assigned_holder_id"])}"}

        b["assigned_holder_id"] != ctx.holder_b ->
          {:wait, "B's item held by #{inspect(b["assigned_holder_id"])}"}

        true ->
          deps.log.("items: A #{a["id"]}, B #{b["id"]}")
          {:done, Map.merge(ctx, %{item_a: a, item_b: b})}
      end
    end
  end

  defp switch(deps, cfg, name, worktree) do
    case deps.git.(["-C", worktree, "switch", "--quiet", "-c", branch(cfg, name)]) do
      :ok -> :ok
      {:error, why} -> fail(:"switch_#{name}", why)
    end
  end

  # The item for a session's branch, read through that session's own MCP: the open names the
  # item after its branch (Loopctl.WorkItems.Open), and it is implementing from its creation.
  defp item(deps, ctx, name) do
    session = Map.fetch!(ctx, name)
    title = branch(ctx.cfg, name)
    args = %{project_id: ctx.cfg.project_id, agent_status: "implementing", limit: 500}

    case deps.call.(session, "list_stories", args) do
      {:ok, %{"data" => rows}} ->
        case Enum.filter(rows, &(&1["title"] == title)) do
          [%{"id" => id}] -> story(deps, session, id)
          [] -> {:wait, "no implementing item titled #{title}"}
          many -> {:fail, "#{length(many)} items titled #{title}"}
        end

      other ->
        {:wait, "list_stories: #{inspect(other, limit: 5)}"}
    end
  end

  defp story(deps, session, id) do
    case deps.call.(session, "get_story", %{story_id: id}) do
      {:ok, %{"story" => story}} -> {:ok, story}
      other -> {:wait, "get_story #{id}: #{inspect(other, limit: 5)}"}
    end
  end

  # --- AC-52.20.4 ---

  defp channel_refusal(deps, ctx) do
    args = %{project_id: ctx.cfg.project_id, ref: ref(ctx.cfg), lease_seconds: 3600}

    with {:ok, %{"created" => true}} <- deps.call.(ctx.a, "channel_claim", args),
         {:error, refused} <- deps.call.(ctx.b, "channel_claim", args),
         "already_claimed" <- code(refused),
         {:ok, _} <- deps.call.(ctx.a, "channel_done", Map.delete(args, :lease_seconds)) do
      deps.log.("channel: B refused already_claimed on #{ref(ctx.cfg)}")
      {:ok, ctx}
    else
      other -> fail(:channel_claim, inspect(other, limit: 8))
    end
  end

  # --- AC-52.20.3 ---

  defp verb_refusals(deps, ctx) do
    id = ctx.item_a["id"]
    epoch = ctx.item_a["claim_epoch"]

    verbs = [
      {"claim_story", %{story_id: id}},
      {"start_story", %{story_id: id}},
      {"renew_story_claim", %{story_id: id, claim_epoch: epoch}},
      {"work_item_note", %{story_id: id, section: "progress", body: "e2e #{ctx.cfg.run_id}: B"}}
    ]

    refused = Enum.find_value(verbs, fn {verb, args} -> not_refused(deps, ctx, verb, args) end)

    with nil <- refused,
         {:ok, after_a} <- unchanged(deps, ctx.a, ctx.item_a) do
      deps.log.("verbs: B refused held_by_other_holder on all four; A's item unchanged")
      {:ok, %{ctx | item_a: after_a}}
    else
      {:error, _} = error -> error
      why when is_binary(why) -> fail(:verb_refusals, why)
    end
  end

  # nil when B's verb was refused held_by_other_holder naming A's holder; else what it got.
  defp not_refused(deps, ctx, verb, args) do
    case deps.call.(ctx.b, verb, args) do
      {:error, body} ->
        if code(body) == "held_by_other_holder" and holder_named(body) == ctx.holder_a,
          do: nil,
          else: "#{verb}: #{inspect(body, limit: 8)}"

      other ->
        "#{verb} was not refused: #{inspect(other, limit: 8)}"
    end
  end

  defp unchanged(deps, session, before) do
    case story(deps, session, before["id"]) do
      {:ok, now} ->
        if Map.take(now, ["claim_epoch", "assigned_holder_id"]) ==
             Map.take(before, ["claim_epoch", "assigned_holder_id"]),
           do: {:ok, now},
           else:
             fail(
               :unchanged,
               "#{before["id"]} moved: #{inspect(Map.take(now, ["claim_epoch", "assigned_holder_id"]))}"
             )

      {:wait, why} ->
        fail(:unchanged, why)
    end
  end

  # --- AC-52.20.6 ---

  defp lapse(deps, ctx) do
    with {:ok, hb} <- beat(deps, ctx.b, :lease),
         {:ok, lease_s} <- lease_s(deps, hb) do
      deps.kill.(ctx.a)
      bound_s = lease_s + 2 * @sweep_interval_s + @margin_s
      deps.log.("killed A; waiting at most #{bound_s} s for its item to be released")
      after_kill(deps, ctx, deps.now_ms.() + bound_s * 1000)
    end
  end

  defp after_kill(deps, ctx, deadline) do
    with {:ok, ctx} <- poll(deps, :lapse, deadline, fn -> released(deps, ctx) end),
         {:ok, _} <- beat(deps, ctx.b, :b_after_lapse),
         {:ok, after_b} <- unchanged(deps, ctx.b, ctx.item_b) do
      deps.log.("lapse: A's item released, B's heartbeat answered and B's item unchanged")
      {:ok, %{ctx | item_b: after_b}}
    end
  end

  defp lease_s(deps, %{"lease" => %{"lease_until" => until}}) do
    case DateTime.from_iso8601(until) do
      {:ok, at, _} -> {:ok, max(DateTime.diff(at, deps.utc_now.()), 0)}
      _ -> fail(:lease, "unparseable lease_until #{inspect(until)}")
    end
  end

  defp lease_s(_deps, status), do: fail(:lease, "no lease in #{inspect(status, limit: 5)}")

  # Read through B: A's process is gone.
  defp released(deps, ctx) do
    case story(deps, ctx.b, ctx.item_a["id"]) do
      {:ok, %{"assigned_holder_id" => nil}} -> {:done, ctx}
      {:ok, %{"assigned_holder_id" => holder}} -> {:wait, "A's item still held by #{holder}"}
      {:wait, why} -> {:wait, why}
    end
  end

  # --- AC-52.20.8 ---

  defp finish(deps, ctx) do
    case deps.call.(ctx.b, "holder_end", %{}) do
      {:ok, %{"holder" => %{"ended_at" => ended}}} when is_binary(ended) ->
        case leftovers(deps, ctx) do
          [] -> {:ok, ctx}
          left -> fail(:clean, Enum.join(left, "; "))
        end

      other ->
        fail(:holder_end, inspect(other, limit: 8))
    end
  end

  @doc """
  What the scenario left open: an item still held, or a live claim on its ref. A's holder is
  ended by the lapse that released its item, and B's by its holder_end; neither has a read
  of its own (there is no holder read route), so the items are the evidence.
  """
  @spec leftovers((... -> term()) | map(), map()) :: [String.t()]
  def leftovers(deps, ctx) do
    items =
      for {name, item} <- [a: ctx.item_a, b: ctx.item_b],
          held = held(deps, ctx.b, item),
          do: "#{name}'s item #{item["id"]} #{held}"

    items ++ live_claims(deps, ctx)
  end

  defp held(deps, session, item) do
    case story(deps, session, item["id"]) do
      {:ok, %{"assigned_holder_id" => nil}} -> nil
      {:ok, %{"assigned_holder_id" => holder}} -> "is still held by #{holder}"
      {:wait, why} -> "is unread: #{why}"
    end
  end

  defp live_claims(deps, ctx) do
    case deps.call.(ctx.b, "channel_claims", %{project_id: ctx.cfg.project_id}) do
      # GET /api/v1/channel/claims answers {claims: [...], meta: {...}}.
      {:ok, %{"claims" => rows}} ->
        for %{"ref" => ref} = row <- rows,
            ref == ref(ctx.cfg),
            row["done"] != true and row["expired"] != true,
            do: "channel claim #{ref} is live"

      other ->
        ["channel claims unread: #{inspect(other, limit: 5)}"]
    end
  end

  # --- helpers ---

  defp poll(deps, step, deadline, check) do
    case check.() do
      {:done, ctx} ->
        {:ok, ctx}

      {:fail, why} ->
        fail(step, why)

      {:wait, why} ->
        left = deadline - deps.now_ms.()

        if left <= 0 do
          fail(step, why)
        else
          deps.sleep.(min(@poll_ms, left))
          poll(deps, step, deadline, check)
        end
    end
  end

  defp code(%{"body" => %{"error" => %{"code" => code}}}), do: code
  defp code(%{"error" => %{"code" => code}}), do: code
  defp code(_), do: nil

  defp holder_named(%{"body" => %{"error" => error}}), do: error["holder_id"]
  defp holder_named(%{"error" => error}), do: error["holder_id"]
  defp holder_named(_), do: nil

  defp fail(step, why), do: {:error, %{step: step, last_state: why}}

  @doc "The failure as one line."
  @spec describe(failure()) :: String.t()
  def describe(%{step: step, last_state: why}),
    do: "two_sessions_one_repo failed at #{step}: #{why}"
end
