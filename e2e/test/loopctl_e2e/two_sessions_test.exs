defmodule LoopctlE2e.TwoSessionsTest do
  @moduledoc """
  The scenario's logic against a scripted world: two fake sessions answering the MCP tools
  the way loopctl does, and a clock that advances on each sleep, so the bounded waits are
  tested in microseconds. The live run is `LoopctlE2e.TwoSessionsLiveTest`.
  """
  use ExUnit.Case, async: true

  alias LoopctlE2e.TwoSessions

  @cfg %{project_id: "p1", repo_url: "https://github.com/o/sandbox.git", run_id: "r1", dir: "/x"}

  # The world: holders, which branch each worktree is on, when A was killed, the clock.
  defp world(overrides \\ %{}) do
    {:ok, pid} =
      Agent.start_link(fn ->
        Map.merge(
          %{
            now: 0,
            branch: %{a: nil, b: nil},
            killed_at: nil,
            b_ended: false,
            lapse_after_s: 400,
            holders: %{a: "ha", b: "hb"},
            hosts: %{a: "minis", b: "minis"},
            b_verb: :refuse,
            open_items: true,
            claim_done: true,
            git: [],
            stopped: []
          },
          overrides
        )
      end)

    pid
  end

  defp get(w, key), do: Agent.get(w, &Map.fetch!(&1, key))
  defp put(w, key, fun), do: Agent.update(w, &Map.update!(&1, key, fun))

  defp deps(w) do
    %{
      start_session: fn %{name: name} -> {:ok, name} end,
      call: fn session, tool, args -> answer(w, session, tool, args) end,
      kill: fn :a ->
        now = get(w, :now)
        put(w, :killed_at, fn _ -> now end)
      end,
      stop: fn session -> put(w, :stopped, &[session | &1]) end,
      git: fn args ->
        put(w, :git, &[args | &1])

        case args do
          [_, wt, "switch", "--quiet", "-c", branch] ->
            name = if String.ends_with?(wt, "wt-a"), do: :a, else: :b
            put(w, :branch, &Map.put(&1, name, branch))

          _ ->
            :ok
        end

        :ok
      end,
      now_ms: fn -> get(w, :now) end,
      utc_now: fn -> DateTime.add(~U[2026-11-20 00:00:00Z], div(get(w, :now), 1000), :second) end,
      sleep: fn ms -> put(w, :now, &(&1 + ms)) end,
      log: fn _ -> :ok end
    }
  end

  defp item_id(:a), do: "item-a"
  defp item_id(:b), do: "item-b"

  defp holder_of(w, name) do
    killed = get(w, :killed_at)

    cond do
      name == :a and killed != nil and get(w, :now) - killed >= get(w, :lapse_after_s) * 1000 ->
        nil

      name == :b and get(w, :b_ended) ->
        nil

      true ->
        get(w, :holders)[name]
    end
  end

  defp story(w, name) do
    %{
      "id" => item_id(name),
      "title" => get(w, :branch)[name],
      "assigned_holder_id" => holder_of(w, name),
      "claim_epoch" => 1
    }
  end

  defp refusal(code, extra \\ %{}),
    do:
      {:error,
       %{
         "error" => true,
         "status" => 409,
         "body" => %{"error" => Map.merge(%{"code" => code}, extra)}
       }}

  defp answer(w, session, "holder_heartbeat", _args) do
    if session == :a and get(w, :killed_at), do: raise("A is dead")

    lease_until =
      DateTime.add(~U[2026-11-20 00:00:00Z], div(get(w, :now), 1000) + 300, :second)

    {:ok,
     %{
       "holder" => %{
         "id" => get(w, :holders)[session],
         "agent_id" => "agent-1",
         "host" => get(w, :hosts)[session],
         "kind" => "interactive"
       },
       "using_holder_credential" => true,
       "lease" => %{"lease_until" => DateTime.to_iso8601(lease_until), "heartbeat_seconds" => 60}
     }}
  end

  defp answer(w, _session, "list_stories", %{agent_status: "implementing"}) do
    rows =
      if get(w, :open_items),
        do: for(name <- [:a, :b], get(w, :branch)[name], do: story(w, name)),
        else: []

    {:ok, %{"data" => rows}}
  end

  defp answer(w, _session, "get_story", %{story_id: id}) do
    name = if id == "item-a", do: :a, else: :b
    {:ok, %{"story" => story(w, name)}}
  end

  defp answer(_w, :a, "channel_claim", _args), do: {:ok, %{"created" => true}}
  defp answer(_w, :b, "channel_claim", _args), do: refusal("already_claimed")
  defp answer(_w, :a, "channel_done", _args), do: {:ok, %{"done" => true}}
  # The shape GET /api/v1/channel/claims answers: A's claim on the scenario's ref, done unless
  # the world says the done never landed.
  defp answer(w, :b, "channel_claims", _args) do
    row = %{"ref" => TwoSessions.ref(@cfg), "done" => get(w, :claim_done), "expired" => false}
    {:ok, %{"claims" => [row], "meta" => %{"count" => 1}}}
  end

  defp answer(w, :b, verb, _args)
       when verb in ["claim_story", "start_story", "renew_story_claim", "work_item_note"] do
    case get(w, :b_verb) do
      :refuse -> refusal("held_by_other_holder", %{"holder_id" => "ha"})
      :accept -> {:ok, %{"story" => %{}}}
    end
  end

  defp answer(w, :b, "holder_end", _args) do
    put(w, :b_ended, fn _ -> true end)
    {:ok, %{"holder" => %{"id" => "hb", "ended_at" => "2026-11-20T01:00:00Z"}}}
  end

  defp run(w), do: TwoSessions.run(@cfg, deps(w))

  test "TC-52.20.1..4, .6: the whole scenario passes against a world that behaves" do
    w = world()
    assert {:ok, ctx} = run(w)
    assert ctx.holder_a == "ha" and ctx.holder_b == "hb"
    assert ctx.item_a["id"] == "item-a" and ctx.item_b["assigned_holder_id"] == "hb"
    assert get(w, :branch) == %{a: "e2e/a-r1", b: "e2e/b-r1"}
    # Both processes are stopped whatever happened.
    assert Enum.sort(get(w, :stopped)) == [:a, :b]
  end

  test "the clone is local and detached until the scenario switches each worktree" do
    w = world()
    assert {:ok, _} = run(w)
    git = Enum.reverse(get(w, :git))
    assert ["init" | _] = hd(git)

    assert Enum.any?(
             git,
             &match?([_, _, "worktree", "add", "--quiet", "--detach", "/x/wt-a"], &1)
           )

    refute Enum.any?(git, &("push" in &1 or "fetch" in &1 or "clone" in &1))
  end

  test "one holder for both sessions fails at holders" do
    w = world(%{holders: %{a: "h", b: "h"}})
    assert {:error, %{step: :holders, last_state: "both sessions are holder h"}} = run(w)
    assert Enum.sort(get(w, :stopped)) == [:a, :b]
  end

  test "B failing to start still stops A" do
    w = world()

    deps =
      Map.put(deps(w), :start_session, fn
        %{name: :a} -> {:ok, :a}
        %{name: :b} -> {:error, :enoent}
      end)

    assert {:error, %{step: :start_b}} = TwoSessions.run(@cfg, deps)
    assert get(w, :stopped) == [:a]
  end

  test "a step that raises still stops both sessions" do
    w = world()
    deps = Map.put(deps(w), :call, fn _s, _t, _a -> raise "transport gone" end)

    assert_raise RuntimeError, fn -> TwoSessions.run(@cfg, deps) end
    assert Enum.sort(get(w, :stopped)) == [:a, :b]
  end

  test "two hosts fail at holders" do
    w = world(%{hosts: %{a: "minis", b: "x1"}})
    assert {:error, %{step: :holders}} = run(w)
  end

  test "an item that never opens fails at items_opened after two heartbeats plus the margin" do
    w = world(%{open_items: false})

    assert {:error, %{step: :items_opened, last_state: "no implementing item titled e2e/a-r1"}} =
             run(w)

    assert get(w, :now) == (2 * 60 + 60) * 1000
  end

  test "B's verb accepted on A's item fails at verb_refusals" do
    w = world(%{b_verb: :accept})

    assert {:error, %{step: :verb_refusals, last_state: "claim_story was not refused" <> _}} =
             run(w)
  end

  test "A's item never released fails at lapse, bounded by lease + two sweeps + 60 s" do
    w = world(%{lapse_after_s: 100_000})
    assert {:error, %{step: :lapse, last_state: "A's item still held by ha"}} = run(w)
    killed = get(w, :killed_at)
    assert get(w, :now) - killed == (300 + 2 * 300 + 60) * 1000
  end

  test "the lapse wait follows the deployed lease rather than a constant" do
    w = world(%{lapse_after_s: 950})
    # 950 s is inside 300 + 600 + 60 = 960 s, so it passes.
    assert {:ok, _} = run(w)
  end

  test "a channel claim left live fails at clean" do
    w = world(%{claim_done: false})
    assert {:error, %{step: :clean, last_state: state}} = run(w)
    assert state =~ "channel claim e2e-ref-r1 is live"
  end

  test "names carry the run id" do
    assert TwoSessions.session_id(@cfg, :a) == "e2e-a-r1"
    assert TwoSessions.branch(@cfg, :b) == "e2e/b-r1"
    assert TwoSessions.ref(@cfg) == "e2e-ref-r1"
  end

  test "TC-52.20.3: the scenario reads loopctl only through its API" do
    mix = File.read!(Path.expand("../../mix.exs", __DIR__))
    runtime = Regex.scan(~r/\{:(\w+),\s*"[^"]+"(,[^}]*)?\}/, mix)

    runtime_deps =
      for [_, name | rest] <- runtime, not String.contains?(Enum.join(rest), "only:"), do: name

    assert Enum.sort(runtime_deps) == ["jason", "req"]

    for file <- ["lib/loopctl_e2e/two_sessions.ex", "lib/loopctl_e2e/mcp.ex"] do
      source = File.read!(Path.expand("../../" <> file, __DIR__))
      refute source =~ ~r/Postgrex|Ecto|Repo\b/, "#{file} reaches past the API"
    end
  end
end
