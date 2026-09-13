defmodule Loopctl.ApiSpec.RunnerContractTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.RunnerDispatchReply
  alias Loopctl.ApiSpec.RunnerContract.RunnerTraceBatch
  alias Loopctl.ApiSpec.RunnerContract.RunnerTraceEvent

  @join %{
    "contract_version" => "1.0.0",
    "machine" => "minis",
    "cores" => 16,
    "memory_mb" => 28_000,
    "repos" => ["mkreyman/home_care_billing"],
    "max_sessions" => 2,
    "in_flight" => 0,
    "draining" => false
  }

  @sample %{
    "sampled_at" => "2026-09-12T20:00:00Z",
    "loadavg_1m" => 0.5,
    "free_ram_mb" => 1_000,
    "free_disk_mb" => 5_000
  }

  describe "the checked-in export" do
    test "matches the declarations — run `mix loopctl.runner_contract` if this fails" do
      path = Path.join(File.cwd!(), RunnerContract.export_path())
      assert File.read!(path) == RunnerContract.encoded_json_schema()
    end

    test "declares every schema the contract names, and requires parent on trace events" do
      defs = RunnerContract.json_schema()["$defs"]

      for mod <- RunnerContract.schema_modules() do
        assert Map.has_key?(defs, mod.schema().title)
      end

      assert "parent" in defs["RunnerTraceEvent"]["required"]
      assert defs["RunnerTraceEvent"]["properties"]["parent"]["type"] == ["string", "null"]
      assert "claim_epoch" in defs["RunnerDispatch"]["required"]
    end

    test "is contract 1.1.0 and names the 1.1 events, replies, errors and limits" do
      schema = RunnerContract.json_schema()
      connection = schema["x-connection"]

      assert RunnerContract.version() == "1.1.0"
      assert schema["x-contract-version"] == "1.1.0"

      assert %{
               "dispatch_reply" => "RunnerDispatchReply",
               "trace" => "RunnerTraceBatch",
               "trace_cursor" => "RunnerTraceCursor"
             } = connection["events"]

      assert connection["replies"] == %{
               "trace" => "RunnerTraceAck",
               "trace_cursor" => "RunnerTraceAck"
             }

      assert connection["errors"] == RunnerContract.error_reasons()

      assert connection["limits"]["trace_max_events"] == RunnerTraceBatch.max_events()

      assert connection["limits"]["trace_max_event_data_bytes"] ==
               RunnerTraceEvent.max_data_bytes()

      assert schema["$defs"]["RunnerTraceBatch"]["properties"]["events"]["maxItems"] ==
               RunnerTraceBatch.max_events()
    end

    test "uses only the JSON Schema keywords the runner's vendored validator implements" do
      # mkreyman/loopctl-runner's LoopctlRunner.Contract FAILS a definition carrying a keyword
      # it does not know, so a new keyword here breaks every runner validating that message.
      known =
        ~w(type required properties minimum maximum minLength maxLength pattern enum items
           maxItems minProperties description format additionalProperties)

      for {title, definition} <- RunnerContract.json_schema()["$defs"] do
        assert unknown_keywords(definition, known) == [], "#{title} uses an unknown keyword"
      end
    end

    test "a worst-case trace batch fits inside the runner socket's frame cap" do
      {_path, _socket, opts} =
        Enum.find(LoopctlWeb.Endpoint.__sockets__(), &match?({"/runner/socket", _, _}, &1))

      frame_cap = opts |> Keyword.fetch!(:websocket) |> Keyword.fetch!(:max_frame_size)
      run_id = Ecto.UUID.generate()
      data_bytes = RunnerTraceEvent.max_data_bytes()
      # {"k":"<padding>"} is 8 bytes of framing around the padding.
      data = %{"k" => String.duplicate("x", data_bytes - 8)}
      assert byte_size(Jason.encode!(data)) == data_bytes

      event = %{
        "run_id" => run_id,
        "seq" => 9_223_372_036_854_775_807,
        "event_id" => String.duplicate("e", 128),
        "parent" => String.duplicate("p", 128),
        "ts" => "2026-09-12T20:36:46.485123+00:00",
        "type" => String.duplicate("t", 64),
        "data" => data
      }

      batch = %{
        "run_id" => run_id,
        "dispatch_id" => Ecto.UUID.generate(),
        "claim_epoch" => 9_223_372_036_854_775_807,
        "events" => List.duplicate(event, RunnerTraceBatch.max_events())
      }

      assert {:ok, _} = RunnerContract.cast_trace_batch(batch)

      # The V2 serializer's frame: [join_ref, ref, topic, event, payload].
      frame =
        Jason.encode!([
          "1",
          "999999",
          "runner:" <> Ecto.UUID.generate(),
          "trace",
          batch
        ])

      assert byte_size(frame) < frame_cap
    end
  end

  defp unknown_keywords(%{} = schema, known) do
    own = Map.keys(schema) -- known

    nested =
      Enum.flat_map(
        Map.get(schema, "properties", %{}),
        fn {_k, sub} -> unknown_keywords(sub, known) end
      ) ++
        case schema["items"] do
          %{} = items -> unknown_keywords(items, known)
          nil -> []
        end

    own ++ nested
  end

  describe "cast_join/1" do
    test "accepts a valid payload and keeps only declared fields" do
      payload = @join |> Map.put("sample", @sample) |> Map.put("smuggled", "x")

      assert {:ok, join} = RunnerContract.cast_join(payload)
      assert join.machine == "minis"
      assert join.sample.free_disk_mb == 5_000
      refute Map.has_key?(join, :smuggled)
      refute Enum.any?(Map.keys(join), &is_binary/1)
    end

    test "drops undeclared keys inside nested objects too" do
      sample = Map.put(@sample, "padding", String.duplicate("x", 1_000))

      assert {:ok, join} = RunnerContract.cast_join(Map.put(@join, "sample", sample))

      assert Map.keys(join.sample) |> Enum.sort() ==
               [:free_disk_mb, :free_ram_mb, :loadavg_1m, :sampled_at]

      assert {:ok, status} = RunnerContract.cast_status(%{"sample" => sample})
      refute Enum.any?(Map.keys(status.sample), &is_binary/1)
    end

    test "accepts any minor or patch of the spoken major" do
      assert {:ok, _} = RunnerContract.cast_join(%{@join | "contract_version" => "1.9.3"})
    end

    test "refuses another major" do
      assert {:error, {:unsupported_contract_version, "2.0.0", _}} =
               RunnerContract.cast_join(%{@join | "contract_version" => "2.0.0"})

      assert {:error, {:unsupported_contract_version, "11.0.0", _}} =
               RunnerContract.cast_join(%{@join | "contract_version" => "11.0.0"})
    end

    test "refuses every missing required field" do
      for field <- Map.keys(@join) do
        assert {:error, {:invalid, _}} = RunnerContract.cast_join(Map.delete(@join, field)),
               "expected missing #{field} to be refused"
      end
    end

    test "refuses out-of-bound values" do
      for {field, value} <- [
            {"cores", 0},
            {"max_sessions", 65},
            {"in_flight", -1},
            {"machine", "Mac Mini"},
            {"repos", ["not-a-repo"]},
            {"repos", Enum.map(1..51, &"o/r#{&1}")},
            {"contract_version", "1.0"}
          ] do
        assert {:error, {:invalid, _}} = RunnerContract.cast_join(Map.put(@join, field, value)),
               "expected #{field}=#{inspect(value)} to be refused"
      end
    end

    test "refuses a partial health sample" do
      assert {:error, {:invalid, _}} =
               RunnerContract.cast_join(
                 Map.put(@join, "sample", Map.delete(@sample, "free_disk_mb"))
               )
    end

    test "refuses a non-object" do
      assert {:error, {:invalid, _}} = RunnerContract.cast_join("minis")
      assert {:error, {:invalid, _}} = RunnerContract.cast_join(nil)
    end
  end

  describe "cast_dispatch/1" do
    test "accepts a valid dispatch and returns declared fields only, with atom keys" do
      payload = build(:runner_dispatch, %{"token_budget" => 200_000})

      assert {:ok, dispatch} = RunnerContract.cast_dispatch(payload)
      assert dispatch.kind == "implement"
      assert dispatch.claim_epoch == 0
      assert dispatch.token_budget == 200_000
      refute Enum.any?(Map.keys(dispatch), &is_binary/1)
    end

    test "drops undeclared keys, including ones that look internal" do
      payload =
        build(:runner_dispatch, %{"tenant_id" => Ecto.UUID.generate(), "prompt" => "rm -rf ~"})

      assert {:ok, dispatch} = RunnerContract.cast_dispatch(payload)

      assert Map.keys(dispatch) |> Enum.sort() ==
               Enum.sort([
                 :base_branch,
                 :branch,
                 :claim_epoch,
                 :dispatch_id,
                 :kind,
                 :max_turns,
                 :repo,
                 :story_id,
                 :wall_clock_seconds
               ])
    end

    test "refuses every missing required field" do
      payload = build(:runner_dispatch)

      for field <- Map.keys(payload) do
        assert {:error, {:invalid, _}} = RunnerContract.cast_dispatch(Map.delete(payload, field)),
               "expected missing #{field} to be refused"
      end
    end

    test "refuses out-of-bound values" do
      for {field, value} <- [
            {"kind", "shell"},
            {"repo", "not-a-repo"},
            {"dispatch_id", "not-a-uuid"},
            {"claim_epoch", -1},
            {"wall_clock_seconds", 0},
            {"max_turns", 0},
            {"branch", ""},
            {"token_budget", 0}
          ] do
        assert {:error, {:invalid, _}} =
                 RunnerContract.cast_dispatch(Map.put(build(:runner_dispatch), field, value)),
               "expected #{field}=#{inspect(value)} to be refused"
      end
    end

    test "refuses a non-object" do
      assert {:error, {:invalid, _}} = RunnerContract.cast_dispatch(nil)
      assert {:error, {:invalid, _}} = RunnerContract.cast_dispatch([build(:runner_dispatch)])
    end
  end

  describe "cast_status/1" do
    test "accepts any subset of the status fields" do
      assert {:ok, %{in_flight: 1}} = RunnerContract.cast_status(%{"in_flight" => 1})
      assert {:ok, %{draining: true}} = RunnerContract.cast_status(%{"draining" => true})
      assert {:ok, %{sample: _}} = RunnerContract.cast_status(%{"sample" => @sample})
    end

    test "refuses a status carrying no declared field" do
      assert {:error, {:invalid, _}} = RunnerContract.cast_status(%{})
      assert {:error, {:invalid, _}} = RunnerContract.cast_status(%{"machine" => "mac-mini"})
    end
  end

  describe "cast_join/1 across minor versions" do
    test "a runner built against 1.0.0 still joins a 1.1.0 server" do
      assert {:ok, %{contract_version: "1.0.0"}} = RunnerContract.cast_join(@join)
    end
  end

  describe "cast_dispatch_reply/1" do
    @reply %{
      "dispatch_id" => "7a0d3b0e-5c3e-4f5a-9d0e-2b8f3a1c4d5e",
      "claim_epoch" => 2,
      "decision" => "accepted"
    }

    test "accepts an accepted reply and a refusal with a reason, declared fields only" do
      assert {:ok, reply} = RunnerContract.cast_dispatch_reply(Map.put(@reply, "extra", 1))
      assert reply == %{dispatch_id: @reply["dispatch_id"], claim_epoch: 2, decision: "accepted"}

      for reason <- RunnerDispatchReply.refusal_reasons() -- ["other"] do
        assert {:ok, %{reason: ^reason}} =
                 RunnerContract.cast_dispatch_reply(
                   Map.merge(@reply, %{"decision" => "refused", "reason" => reason})
                 )
      end

      assert {:ok, %{detail: "quota"}} =
               RunnerContract.cast_dispatch_reply(
                 Map.merge(@reply, %{
                   "decision" => "refused",
                   "reason" => "other",
                   "detail" => "quota"
                 })
               )
    end

    test "refuses the cross-field shapes JSON Schema cannot state" do
      for payload <- [
            Map.put(@reply, "decision", "refused"),
            Map.merge(@reply, %{"decision" => "refused", "reason" => "other"}),
            Map.put(@reply, "reason", "draining"),
            Map.put(@reply, "detail", "why")
          ] do
        assert {:error, {:invalid, [_ | _]}} = RunnerContract.cast_dispatch_reply(payload),
               "expected #{inspect(payload)} to be refused"
      end
    end

    test "refuses missing fields, an unknown decision or reason, and an overlong detail" do
      for field <- Map.keys(@reply) do
        assert {:error, {:invalid, _}} =
                 RunnerContract.cast_dispatch_reply(Map.delete(@reply, field))
      end

      too_long = String.duplicate("x", RunnerDispatchReply.max_detail_length() + 1)

      for {field, value} <- [
            {"decision", "maybe"},
            {"reason", "bored"},
            {"claim_epoch", -1},
            {"dispatch_id", "nope"},
            {"detail", too_long}
          ] do
        payload =
          Map.merge(@reply, %{"decision" => "refused", "reason" => "other", "detail" => "d"})

        assert {:error, {:invalid, _}} =
                 RunnerContract.cast_dispatch_reply(Map.put(payload, field, value)),
               "expected #{field}=#{inspect(value)} to be refused"
      end

      assert {:error, {:invalid, _}} = RunnerContract.cast_dispatch_reply(nil)
    end
  end

  describe "cast_trace_batch/1" do
    test "accepts a batch and casts events, keeping free-form data" do
      batch = build(:runner_trace_batch, %{:seqs => [0, 1], "extra" => true})

      assert {:ok, cast} = RunnerContract.cast_trace_batch(batch)
      refute Map.has_key?(cast, :extra)

      assert [%{seq: 0, parent: nil, ts: %DateTime{}, data: %{"tool" => "Read"}}, %{seq: 1}] =
               cast.events
    end

    test "refuses more events than max_events, before casting any" do
      max = RunnerTraceBatch.max_events()

      assert {:ok, _} =
               RunnerContract.cast_trace_batch(
                 build(:runner_trace_batch, %{seqs: Enum.to_list(1..max)})
               )

      oversize = build(:runner_trace_batch, %{seqs: Enum.to_list(0..max)})
      assert {:error, {:batch_too_large, ^max}} = RunnerContract.cast_trace_batch(oversize)
    end

    test "refuses an event whose data exceeds max_data_bytes, naming its seq" do
      max = RunnerTraceEvent.max_data_bytes()
      batch = build(:runner_trace_batch, %{seqs: [0, 1]})
      fits = %{"k" => String.duplicate("x", max - 8)}
      over = %{"k" => String.duplicate("x", max - 7)}

      at_cap = put_in(batch, ["events", Access.at(1), "data"], fits)
      assert {:ok, _} = RunnerContract.cast_trace_batch(at_cap)

      over_cap = put_in(batch, ["events", Access.at(1), "data"], over)

      assert {:error, {:event_data_too_large, 1, ^max}} =
               RunnerContract.cast_trace_batch(over_cap)
    end

    test "refuses an event of another run, a seq beyond bigint, and malformed events" do
      batch = build(:runner_trace_batch, %{seqs: [0]})

      for event_change <- [
            %{"run_id" => Ecto.UUID.generate()},
            %{"seq" => 9_223_372_036_854_775_808},
            %{"seq" => -1},
            %{"parent" => ""},
            %{"ts" => "yesterday"}
          ] do
        payload = update_in(batch, ["events", Access.at(0)], &Map.merge(&1, event_change))

        assert {:error, {:invalid, _}} = RunnerContract.cast_trace_batch(payload),
               "expected #{inspect(event_change)} to be refused"
      end

      for field <- ["run_id", "dispatch_id", "claim_epoch", "events"] do
        assert {:error, {:invalid, _}} = RunnerContract.cast_trace_batch(Map.delete(batch, field))
      end

      assert {:error, {:invalid, _}} =
               RunnerContract.cast_trace_batch(
                 update_in(batch, ["events", Access.at(0)], &Map.delete(&1, "parent"))
               )
    end
  end

  describe "cast_trace_cursor/1" do
    test "accepts a run id and refuses anything else" do
      run_id = Ecto.UUID.generate()
      assert {:ok, %{run_id: ^run_id}} = RunnerContract.cast_trace_cursor(%{"run_id" => run_id})
      assert {:error, {:invalid, _}} = RunnerContract.cast_trace_cursor(%{"run_id" => "x"})
      assert {:error, {:invalid, _}} = RunnerContract.cast_trace_cursor(%{})
    end
  end
end
