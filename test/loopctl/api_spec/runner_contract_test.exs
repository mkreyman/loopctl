defmodule Loopctl.ApiSpec.RunnerContractTest do
  use ExUnit.Case, async: true

  import Bitwise
  import Loopctl.Fixtures

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.RunnerDispatchReply
  alias Loopctl.ApiSpec.RunnerContract.RunnerTraceBatch
  alias Loopctl.ApiSpec.RunnerContract.RunnerTraceEvent
  alias Loopctl.Delivery.StageMachine

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

    test "is the current contract version and names its events, replies, errors and limits" do
      schema = RunnerContract.json_schema()
      connection = schema["x-connection"]

      assert RunnerContract.version() == "1.4.0"
      assert schema["x-contract-version"] == "1.4.0"

      assert %{
               "dispatch_reply" => "RunnerDispatchReply",
               "trace" => "RunnerTraceBatch",
               "trace_cursor" => "RunnerTraceCursor",
               "stage" => "RunnerStageReport"
             } = connection["events"]

      assert connection["replies"] == %{
               "trace" => "RunnerTraceAck",
               "trace_cursor" => "RunnerTraceAck"
             }

      assert connection["errors"] == RunnerContract.error_reasons()
      assert "unknown_event" in connection["errors"]["unknown_event"]
      assert "machine_mismatch" in connection["errors"]["join"]
      assert RunnerContract.inbound_events() -- Map.keys(connection["errors"]) == []

      assert connection["limits"]["trace_max_events"] == RunnerTraceBatch.max_events()
      assert connection["limits"]["trace_max_batch_bytes"] == RunnerTraceBatch.max_bytes()
      assert connection["limits"]["trace_max_event_bytes"] == RunnerTraceEvent.max_bytes()
      assert connection["limits"]["frame_envelope_bytes"] == RunnerContract.frame_envelope_bytes()
      assert connection["limits"]["dispatch_reply_burst"] == RunnerContract.dispatch_reply_burst()
      assert connection["limits"]["stage_burst"] == RunnerContract.stage_burst()

      # #803: the stage transition table is published so a runner can refuse an impossible
      # transition locally. It is DERIVED from the server's machine — asserted here against
      # `StageMachine.runner_transitions/0` rather than against a copy, so an edge added to
      # the machine reaches the wire without anyone remembering to widen a list.
      assert connection["stage_transitions"] ==
               Enum.map(StageMachine.runner_transitions(), fn {from, to, edge} ->
                 %{"from" => to_string(from), "to" => to_string(to), "edge" => to_string(edge)}
               end)

      assert connection["limits"]["min_interval_ms"] ==
               Map.new(
                 ~w(status trace trace_cursor),
                 &{&1, RunnerContract.min_interval_ms(&1)}
               )

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

    test "the published byte rule is the implemented one, on random payloads" do
      rule = RunnerContract.json_schema()["x-connection"]["limits"]["json_byte_rule"]

      # An independent evaluator of the PUBLISHED constants, written from the rule's text.
      published = fn published, term ->
        cond do
          is_binary(term) ->
            units = term |> String.to_charlist() |> Enum.sum_by(&if(&1 > 0xFFFF, do: 2, else: 1))
            rule["per_string_char"] * units + rule["per_string"]

          is_number(term) or term in [true, false, nil] ->
            rule["per_scalar"]

          is_list(term) ->
            rule["per_container"] +
              Enum.sum_by(term, &(rule["per_member"] + published.(published, &1)))

          is_map(term) ->
            rule["per_container"] +
              Enum.sum_by(term, fn {k, v} ->
                rule["per_member"] + published.(published, k) + published.(published, v)
              end)
        end
      end

      :rand.seed(:exsss, {803, 3, 13})

      for _ <- 1..300 do
        term = random_json(4)
        assert published.(published, term) == RunnerContract.json_bytes_upper_bound(term)
      end

      # The text quotes the constants it is made of, and every byte-limited schema quotes it.
      for {key, value} <- Map.delete(rule, "text"), key != "per_string" do
        assert rule["text"] =~ Integer.to_string(value), "the rule text omits #{key}"
      end

      defs = RunnerContract.json_schema()["$defs"]
      assert defs["RunnerTraceBatch"]["description"] =~ rule["text"]
      assert defs["RunnerTraceEvent"]["description"] =~ rule["text"]
    end

    test "the byte rule on small values" do
      assert RunnerContract.json_bytes_upper_bound("") == 12
      assert RunnerContract.json_bytes_upper_bound("ab") == 24
      assert RunnerContract.json_bytes_upper_bound(<<0x1F600::utf8>>) == 24
      assert RunnerContract.json_bytes_upper_bound(123) == 32
      # {"k":[1,true,null]}: object 2, member 2, key 18, array 2 + 3 * (2 + 32).
      assert RunnerContract.json_bytes_upper_bound(%{"k" => [1, true, nil]}) == 126
    end

    test "the limits nest: a valid event fits an event, one event fits a batch, a batch fits a frame" do
      {_path, _socket, opts} =
        Enum.find(LoopctlWeb.Endpoint.__sockets__(), &match?({"/runner/socket", _, _}, &1))

      frame_cap = opts |> Keyword.fetch!(:websocket) |> Keyword.fetch!(:max_frame_size)
      bigint_max = 9_223_372_036_854_775_807

      # The largest schema-valid event: every string at its maxLength in astral characters,
      # data at its cap.
      worst = worst_event(Ecto.UUID.generate(), 0, <<0x1F600::utf8>>)

      assert RunnerContract.json_bytes_upper_bound(worst["data"]) <=
               RunnerTraceEvent.max_data_bytes()

      assert RunnerContract.json_bytes_upper_bound(worst) <= RunnerTraceEvent.max_bytes()

      one = one_event_batch(worst, bigint_max)
      assert {:ok, _} = RunnerContract.cast_trace_batch(one)

      # A batch of the largest event an event may be still fits the batch budget.
      at_event_cap = Map.put(worst, "pad", "")

      at_event_cap =
        Map.put(
          at_event_cap,
          "pad",
          String.duplicate(
            "x",
            div(
              RunnerTraceEvent.max_bytes() - RunnerContract.json_bytes_upper_bound(at_event_cap),
              6
            )
          )
        )

      assert RunnerContract.json_bytes_upper_bound(one_event_batch(at_event_cap, bigint_max)) <=
               RunnerTraceBatch.max_bytes()

      envelope = [
        "18446744073709551615",
        "18446744073709551615",
        "runner:" <> Ecto.UUID.generate(),
        "trace",
        %{}
      ]

      assert RunnerContract.json_bytes_upper_bound(envelope) <=
               RunnerContract.frame_envelope_bytes()

      assert RunnerTraceBatch.max_bytes() + RunnerContract.frame_envelope_bytes() < frame_cap
    end

    test "an admitted worst-case batch fits the frame even from an encoder that escapes every character" do
      {_path, _socket, opts} =
        Enum.find(LoopctlWeb.Endpoint.__sockets__(), &match?({"/runner/socket", _, _}, &1))

      frame_cap = opts |> Keyword.fetch!(:websocket) |> Keyword.fetch!(:max_frame_size)

      # Go's encoding/json escapes < > &, .NET escapes more; this escapes EVERY character,
      # which no real encoder exceeds.
      batches =
        for char <- [<<1>>, "<", "&", <<0xE9::utf8>>, <<0x1F600::utf8>>, "x"],
            count <- [1, 2, 4, 5, 10, RunnerTraceBatch.max_events()] do
          run_id = Ecto.UUID.generate()
          events = for seq <- 1..count, do: worst_event(run_id, seq, char)
          one_event_batch(hd(events), 0) |> Map.put("events", events)
        end

      outcomes =
        for batch <- batches do
          frame = [
            "18446744073709551615",
            "18446744073709551615",
            "runner:" <> Ecto.UUID.generate(),
            "trace",
            batch
          ]

          escaped = byte_size(escape_everything(frame))

          assert RunnerContract.json_bytes_upper_bound(frame) >= escaped

          case RunnerContract.cast_trace_batch(batch) do
            {:ok, _} ->
              assert escaped < frame_cap
              :admitted

            {:error, {:batch_too_large, _, _}} ->
              assert RunnerContract.json_bytes_upper_bound(batch) > RunnerTraceBatch.max_bytes()
              :refused
          end
        end

      assert :admitted in outcomes
      assert :refused in outcomes
    end

    test "a one-event batch over the budget is event_data_too_large naming its seq; a multi-event one is batch_too_large" do
      run_id = Ecto.UUID.generate()
      event = worst_event(run_id, 7, "x")
      budget = RunnerTraceBatch.max_bytes()

      # The event is inside its own limits; what pushes the batch over is sent beside it.
      one = one_event_batch(event, 0) |> Map.put("padding", String.duplicate("x", div(budget, 6)))
      assert RunnerContract.json_bytes_upper_bound(one) > budget
      assert {:error, {:event_data_too_large, 7, _, _}} = RunnerContract.cast_trace_batch(one)

      two = Map.put(one, "events", [event, %{event | "seq" => 8}])
      assert {:error, {:batch_too_large, _, ^budget}} = RunnerContract.cast_trace_batch(two)

      # An event over its OWN limit is named, in any batch.
      fat =
        Map.put(
          %{event | "seq" => 9},
          "padding",
          String.duplicate("x", div(RunnerTraceEvent.max_bytes(), 6))
        )

      assert {:error, {:event_data_too_large, 9, _, _}} =
               RunnerContract.cast_trace_batch(
                 Map.put(one_event_batch(event, 0), "events", [event, fat])
               )
    end

    test "a number wider than the byte rule's scalar is invalid" do
      digits =
        RunnerContract.json_schema()["x-connection"]["limits"]["json_byte_rule"][
          "max_number_digits"
        ]

      batch = build(:runner_trace_batch, %{seqs: [0]})
      fits = String.duplicate("9", digits) |> String.to_integer()

      ok = put_in(batch, ["events", Access.at(0), "data"], %{"n" => fits})
      assert {:ok, _} = RunnerContract.cast_trace_batch(ok)

      wide = put_in(batch, ["events", Access.at(0), "data"], %{"n" => [fits + 1]})
      assert {:error, {:invalid, [message]}} = RunnerContract.cast_trace_batch(wide)
      assert message =~ "digits"
    end
  end

  # The largest schema-valid event made of `char`: every string at its maxLength, `data` a
  # single string sized to the per-event data cap under the byte rule.
  defp worst_event(run_id, seq, char) do
    data_chars = div(RunnerTraceEvent.max_data_bytes() - 34, 6 * utf16_units(char))

    %{
      "run_id" => run_id,
      "seq" => seq,
      "event_id" => String.duplicate(char, 128),
      "parent" => String.duplicate(char, 128),
      "ts" => "2026-09-12T20:36:46.485123+00:00",
      "type" => String.duplicate(char, 64),
      "data" => %{"k" => String.duplicate(char, data_chars)}
    }
  end

  defp utf16_units(<<c::utf8>>) when c > 0xFFFF, do: 2
  defp utf16_units(_char), do: 1

  defp one_event_batch(event, claim_epoch) do
    %{
      "run_id" => event["run_id"],
      "dispatch_id" => Ecto.UUID.generate(),
      "claim_epoch" => claim_epoch,
      "events" => [event]
    }
  end

  # Compact JSON with every string character written as \\uXXXX (a surrogate pair outside
  # the BMP): more bytes than any real encoder spends.
  defp escape_everything(term) when is_binary(term) do
    body =
      for <<c::utf8 <- term>>, into: "" do
        if c > 0xFFFF do
          v = c - 0x10000
          hex4(0xD800 + (v >>> 10)) <> hex4(0xDC00 + (v &&& 0x3FF))
        else
          hex4(c)
        end
      end

    ~s(") <> body <> ~s(")
  end

  defp escape_everything(term) when is_integer(term), do: Integer.to_string(term)
  defp escape_everything(true), do: "true"
  defp escape_everything(false), do: "false"
  defp escape_everything(nil), do: "null"

  defp escape_everything(term) when is_list(term),
    do: "[" <> Enum.map_join(term, ",", &escape_everything/1) <> "]"

  defp escape_everything(term) when is_map(term) do
    "{" <>
      Enum.map_join(term, ",", fn {k, v} ->
        escape_everything(k) <> ":" <> escape_everything(v)
      end) <>
      "}"
  end

  defp hex4(n), do: "\\u" <> String.pad_leading(Integer.to_string(n, 16), 4, "0")

  # A random JSON-shaped term, `depth` levels deep at most.
  defp random_json(0), do: random_scalar()

  defp random_json(depth) do
    case :rand.uniform(4) do
      1 -> random_scalar()
      2 -> for _ <- 1..:rand.uniform(4), do: random_json(depth - 1)
      _ -> Map.new(1..:rand.uniform(4), fn _ -> {random_string(), random_json(depth - 1)} end)
    end
  end

  defp random_scalar do
    Enum.random([
      random_string(),
      :rand.uniform(1_000_000) - 500_000,
      :rand.uniform() * 1.0e6,
      true,
      false,
      nil
    ])
  end

  defp random_string do
    alphabet = [?a, ?<, ?&, ?", ?\\, 1, 0xE9, 0x4E2D, 0x1F600]
    for _ <- 1..:rand.uniform(8), into: "", do: <<Enum.random(alphabet)::utf8>>
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

    test "refuses a wall clock past the bound, and accepts it at the bound" do
      max = RunnerContract.RunnerDispatch.max_wall_clock_seconds()

      assert {:ok, %{wall_clock_seconds: ^max}} =
               RunnerContract.cast_dispatch(
                 build(:runner_dispatch, %{"wall_clock_seconds" => max})
               )

      # Unbounded, this reaches an integer column as an out-of-range value and raises out of
      # dispatch/3 instead of being refused as the invalid payload it is.
      for over <- [max + 1, 2_147_483_648, 9_999_999_999_999] do
        assert {:error, {:invalid, messages}} =
                 RunnerContract.cast_dispatch(
                   build(:runner_dispatch, %{"wall_clock_seconds" => over})
                 )

        assert Enum.any?(messages, &(&1 =~ "maximum #{max}"))
      end
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

      assert {:error, {:batch_too_large, ^max, _max_bytes}} =
               RunnerContract.cast_trace_batch(oversize)
    end

    test "refuses an event whose data exceeds max_data_bytes, naming its seq" do
      max = RunnerTraceEvent.max_data_bytes()
      batch = build(:runner_trace_batch, %{seqs: [0, 1]})
      # %{"k" => s} under the byte rule: container 2, member 2, key 6 + 12, value 6n + 12.
      chars = div(max - 34, 6)
      fits = %{"k" => String.duplicate("x", chars)}
      over = %{"k" => String.duplicate("x", chars + 1)}
      assert RunnerContract.json_bytes_upper_bound(fits) <= max
      assert RunnerContract.json_bytes_upper_bound(over) > max

      at_cap = put_in(batch, ["events", Access.at(1), "data"], fits)
      assert {:ok, _} = RunnerContract.cast_trace_batch(at_cap)

      over_cap = put_in(batch, ["events", Access.at(1), "data"], over)

      assert {:error, {:event_data_too_large, 1, ^max, _max_event}} =
               RunnerContract.cast_trace_batch(over_cap)
    end

    test "refuses an event of another run, a seq beyond bigint, and malformed events" do
      batch = build(:runner_trace_batch, %{seqs: [0]})

      for event_change <- [
            %{"run_id" => Ecto.UUID.generate()},
            %{"seq" => RunnerContract.max_seq() + 1},
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

  describe "the seq bound" do
    test "max_seq is accepted and one past it refused, and the bound leaves room for seq + 1" do
      max = RunnerContract.max_seq()
      bigint_max = 9_223_372_036_854_775_807
      assert max + 1 <= bigint_max

      at_max =
        update_in(
          build(:runner_trace_batch, %{seqs: [0]}),
          ["events", Access.at(0)],
          &Map.put(&1, "seq", max)
        )

      assert {:ok, %{events: [%{seq: ^max}]}} = RunnerContract.cast_trace_batch(at_max)

      for seq <- [max + 1, bigint_max] do
        past = update_in(at_max, ["events", Access.at(0)], &Map.put(&1, "seq", seq))
        assert {:error, {:invalid, _}} = RunnerContract.cast_trace_batch(past)
      end

      assert RunnerContract.json_schema()["x-connection"]["limits"]["trace_max_seq"] == max
    end
  end

  describe "UUID normalization" do
    test "every UUID a runner or a caller sends is returned lowercase" do
      run_id = Ecto.UUID.generate()
      dispatch_id = Ecto.UUID.generate()
      story_id = Ecto.UUID.generate()
      up = &String.upcase/1

      batch =
        build(:runner_trace_batch, %{
          :seqs => [0, 1],
          "run_id" => up.(run_id),
          "dispatch_id" => up.(dispatch_id)
        })
        |> update_in(["events", Access.all()], &Map.put(&1, "run_id", up.(run_id)))

      assert {:ok, cast} = RunnerContract.cast_trace_batch(batch)
      assert cast.run_id == run_id
      assert cast.dispatch_id == dispatch_id
      assert Enum.all?(cast.events, &(&1.run_id == run_id))

      assert {:ok, %{run_id: ^run_id}} =
               RunnerContract.cast_trace_cursor(%{"run_id" => up.(run_id)})

      assert {:ok, %{dispatch_id: ^dispatch_id}} =
               RunnerContract.cast_dispatch_reply(%{
                 "dispatch_id" => up.(dispatch_id),
                 "claim_epoch" => 0,
                 "decision" => "accepted"
               })

      assert {:ok, %{dispatch_id: ^dispatch_id, story_id: ^story_id}} =
               RunnerContract.cast_dispatch(
                 build(:runner_dispatch, %{
                   "dispatch_id" => up.(dispatch_id),
                   "story_id" => up.(story_id)
                 })
               )
    end
  end

  describe "NUL refusal" do
    test "a NUL in any string of a trace event, at any depth of data, is invalid" do
      nul = "a" <> <<0>> <> "b"
      batch = build(:runner_trace_batch, %{seqs: [0]})

      for change <- [
            %{"event_id" => nul},
            %{"parent" => nul},
            %{"type" => nul},
            %{"data" => %{"k" => nul}},
            %{"data" => %{nul => "v"}},
            %{"data" => %{"list" => [1, %{"deep" => [nul]}]}}
          ] do
        payload = update_in(batch, ["events", Access.at(0)], &Map.merge(&1, change))

        assert {:error, {:invalid, [message]}} = RunnerContract.cast_trace_batch(payload),
               "expected #{inspect(change)} to be refused"

        assert message =~ "NUL"
      end

      assert {:ok, _} = RunnerContract.cast_trace_batch(batch)
    end

    test "a NUL in a refusal's detail is invalid" do
      reply = %{
        "dispatch_id" => Ecto.UUID.generate(),
        "claim_epoch" => 0,
        "decision" => "refused",
        "reason" => "other"
      }

      assert {:ok, _} = RunnerContract.cast_dispatch_reply(Map.put(reply, "detail", "fine"))

      assert {:error, {:invalid, [message]}} =
               RunnerContract.cast_dispatch_reply(Map.put(reply, "detail", "a" <> <<0>>))

      assert message =~ "NUL"
    end
  end

  describe "disconnecting (1.2.0)" do
    test "the export declares the event, its schema and every reason the channel uses" do
      schema = RunnerContract.json_schema()
      assert schema["x-connection"]["events"]["disconnecting"] == "RunnerDisconnecting"

      definition = schema["$defs"]["RunnerDisconnecting"]
      assert definition["required"] == ["reason"]

      assert definition["properties"]["reason"]["enum"] ==
               RunnerContract.RunnerDisconnecting.reasons()

      assert Enum.sort(RunnerContract.RunnerDisconnecting.reasons()) ==
               Enum.sort(
                 ~w(join_refused_not_authorized no_longer_authorized runner_revoked server_shutdown)
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
