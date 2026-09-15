defmodule LoopctlRunner.ContractTest do
  use ExUnit.Case, async: false

  alias LoopctlRunner.{Contract, Health}

  defp join(overrides \\ %{}) do
    Map.merge(
      %{
        "contract_version" => "1.6.0",
        "kinds" => ["implement"],
        "machine" => "minis",
        "cores" => 16,
        "memory_mb" => 28_000,
        "repos" => ["mkreyman/home_care_billing"],
        "max_sessions" => 2,
        "in_flight" => 0,
        "draining" => false
      },
      overrides
    )
  end

  test "the vendored contract is v1.6.0 and names the socket and header the client uses" do
    assert Contract.version() == "1.6.0"

    assert %{
             "credential_header" => "x-loopctl-runner-token",
             "socket_path" => "/runner/socket/websocket",
             "topic" => "runner:{runner_id}",
             "implied_kinds" => ["implement"]
           } = Contract.connection()
  end

  test "uuid and date-time formats are enforced, as loopctl casts them" do
    reply = %{
      "dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
      "claim_epoch" => 0,
      "decision" => "refused",
      "reason" => "dispatches_disabled"
    }

    assert Contract.validate("RunnerDispatchReply", reply) == :ok

    assert {:error, [msg]} =
             Contract.validate("RunnerDispatchReply", %{reply | "dispatch_id" => "d-1"})

    assert msg =~ "is not a uuid"

    assert {:error, [msg]} =
             Contract.validate("RunnerTraceCursor", %{"run_id" => "7d0c1f6e-3b1a-4f7e-9c2d"})

    assert msg =~ "is not a uuid"

    assert {:error, [msg]} =
             Contract.validate("RunnerStatus", %{
               "in_flight" => 0,
               "draining" => true,
               "sample" => %{
                 "sampled_at" => "yesterday",
                 "loadavg_1m" => 1.0,
                 "free_ram_mb" => 1,
                 "free_disk_mb" => 1,
                 "last_build_at" => nil
               }
             })

    assert msg =~ "is not an RFC 3339 date-time"
  end

  test "a complete join validates" do
    assert Contract.validate("RunnerJoin", join()) == :ok
  end

  test "the declared kinds are bounded by the contract, and this runner's fit" do
    kinds = LoopctlRunner.Control.kinds()
    assert Contract.validate("RunnerJoin", join(%{"kinds" => kinds})) == :ok

    # Absent and empty both mean implied_kinds; neither is refused on the wire.
    assert Contract.validate("RunnerJoin", Map.delete(join(), "kinds")) == :ok
    assert Contract.validate("RunnerJoin", join(%{"kinds" => []})) == :ok

    # The bounds come from the vendored file, never re-typed: a lowered one must fail here.
    schema = Contract.schema_def("RunnerJoin")
    max_items = schema["properties"]["kinds"]["maxItems"]
    max_length = schema["properties"]["kinds"]["items"]["maxLength"]

    assert {:error, [msg]} =
             Contract.validate(
               "RunnerJoin",
               join(%{"kinds" => [String.duplicate("k", max_length + 1)]})
             )

    assert msg =~ "longer than #{max_length}"

    assert {:error, [msg]} =
             Contract.validate(
               "RunnerJoin",
               join(%{"kinds" => List.duplicate("implement", max_items + 1)})
             )

    assert msg =~ "more than #{max_items} items"

    assert Enum.all?(kinds, &(String.length(&1) <= max_length))
    assert length(kinds) <= max_items
  end

  test "the declaration is exactly the kinds the accept path can actually run" do
    # Widening @kinds declares a capability loopctl then sends. The accept path requires a story
    # object, which the contract allows only on an implement dispatch, so any other declared kind
    # is refused as `other` — suppressing nothing, recording nothing, and soaking that kind for
    # as long as it is declared. A new kind needs its payload and its own accept path first.
    assert LoopctlRunner.Control.kinds() == ["implement"]
  end

  test "each constraint the contract declares is enforced" do
    assert {:error, [msg]} = Contract.validate("RunnerJoin", Map.delete(join(), "machine"))
    assert msg =~ "missing machine"

    assert {:error, [msg]} = Contract.validate("RunnerJoin", join(%{"machine" => "Minis!"}))
    assert msg =~ "does not match"

    assert {:error, [msg]} = Contract.validate("RunnerJoin", join(%{"max_sessions" => 65}))
    assert msg =~ "above maximum"

    assert {:error, [msg]} = Contract.validate("RunnerJoin", join(%{"cores" => "16"}))
    assert msg =~ "expected"

    assert {:error, [msg]} = Contract.validate("RunnerJoin", join(%{"repos" => ["not a repo"]}))
    assert msg =~ "repos[0]"

    assert {:error, [msg]} = Contract.validate("RunnerStatus", %{})
    assert msg =~ "fewer than 1 properties"

    assert {:error, [msg]} =
             Contract.validate("RunnerDispatch", %{
               "dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
               "story_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
               "kind" => "deploy",
               "repo" => "a/b",
               "base_branch" => "master",
               "branch" => "loop/x",
               "claim_epoch" => 0,
               "wall_clock_seconds" => 60,
               "max_turns" => 5
             })

    assert msg =~ "not in"
  end

  test "a sample from this machine satisfies RunnerSample" do
    sample = Health.sample(System.tmp_dir!(), nil)
    assert is_map(sample)
    assert Contract.validate("RunnerSample", sample) == :ok
    assert {:ok, %{"cores" => cores, "memory_mb" => mb}} = Health.capacity()
    assert cores >= 1 and mb >= 1
  end

  describe "with a PATH that cannot find the tools" do
    setup do
      original = System.get_env("PATH")
      # An empty directory: nothing is found by PATH, so only the fallback can succeed.
      System.put_env("PATH", LoopctlRunner.TestSupport.tmp_dir!("empty-path"))
      on_exit(fn -> System.put_env("PATH", original) end)
    end

    test "each tool the health check runs is still found at its standard location" do
      assert Health.executable("df") in ["/bin/df", "/usr/bin/df"]

      if :os.type() == {:unix, :darwin} do
        assert Health.executable("sysctl") in ["/usr/sbin/sysctl", "/sbin/sysctl"]
        assert Health.executable("vm_stat") == "/usr/bin/vm_stat"
      end

      assert Health.executable("no-such-tool") == nil
    end

    test "capacity and a sample are still readable" do
      assert {:ok, %{"memory_mb" => mb}} = Health.capacity()
      assert mb >= 1
      assert is_map(Health.sample(System.tmp_dir!(), nil))
    end
  end

  describe "list constraints, implemented before loopctl can publish them" do
    @kinds %{
      "type" => "array",
      "items" => %{"type" => "string", "enum" => ["implement", "triage"]},
      "minItems" => 1,
      "maxItems" => 2,
      "uniqueItems" => true
    }

    test "minItems, maxItems and uniqueItems each refuse, and a good list passes" do
      assert Contract.validate_against(@kinds, ["implement"], "kinds") == :ok
      assert Contract.validate_against(@kinds, ["implement", "triage"], "kinds") == :ok

      assert {:error, ["kinds: fewer than 1 items"]} =
               Contract.validate_against(@kinds, [], "kinds")

      assert {:error, ["kinds: items are not unique"]} =
               Contract.validate_against(@kinds, ["implement", "implement"], "kinds")

      # Every failing keyword is reported, not the first. Order follows map iteration, which
      # this validator does not fix, so the assertion is on membership.
      assert {:error, errors} =
               Contract.validate_against(@kinds, ["implement", "triage", "implement"], "kinds")

      assert Enum.sort(errors) ==
               Enum.sort(["kinds: more than 2 items", "kinds: items are not unique"])
    end

    test "uniqueItems false allows the very repeats true refuses" do
      repeats = ["implement", "implement"]
      permissive = %{@kinds | "uniqueItems" => false, "minItems" => 0}

      assert Contract.validate_against(permissive, repeats, "kinds") == :ok
      assert Contract.validate_against(permissive, [], "kinds") == :ok

      assert {:error, ["kinds: items are not unique"]} =
               Contract.validate_against(%{permissive | "uniqueItems" => true}, repeats, "kinds")
    end

    test "uniqueItems compares JSON values: 1 and 1.0 are the same number" do
      numbers = %{"type" => "array", "uniqueItems" => true}

      assert {:error, ["n: items are not unique"]} =
               Contract.validate_against(numbers, [1, 1.0], "n")

      assert {:error, ["n: items are not unique"]} =
               Contract.validate_against(numbers, [%{"a" => [1]}, %{"a" => [1.0]}], "n")

      assert Contract.validate_against(numbers, [1, 2, "1"], "n") == :ok
    end

    test "additionalProperties as a subschema validates the properties the schema does not name" do
      schema = %{
        "type" => "object",
        "properties" => %{"kind" => %{"type" => "string"}},
        "additionalProperties" => %{"type" => "string"}
      }

      assert Contract.validate_against(schema, %{"kind" => "implement", "note" => "x"}, "d") ==
               :ok

      assert {:error, [error]} =
               Contract.validate_against(schema, %{"kind" => "implement", "note" => 1}, "d")

      assert error =~ ~s(d.note: expected "string", got 1)
    end

    test "uniqueItems is exact on integers a float cannot hold, and does not raise on a bignum" do
      numbers = %{"type" => "array", "uniqueItems" => true}
      big = 9_007_199_254_740_993

      assert Contract.validate_against(numbers, [big, big - 1], "n") == :ok
      assert Contract.validate_against(numbers, [10 ** 400, 1], "n") == :ok

      assert {:error, ["n: items are not unique"]} =
               Contract.validate_against(numbers, [big, big], "n")
    end

    test "additionalProperties false refuses a property the schema does not name" do
      schema = %{
        "type" => "object",
        "properties" => %{"kind" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      assert Contract.validate_against(schema, %{"kind" => "implement"}, "d") == :ok

      assert {:error, [error]} =
               Contract.validate_against(schema, %{"kind" => "implement", "extra" => 1}, "d")

      assert error =~ "has extra, which the schema does not allow"

      assert Contract.validate_against(
               %{schema | "additionalProperties" => true},
               %{"x" => 1},
               "d"
             ) == :ok
    end

    test "a keyword the validator does not implement still fails rather than being skipped" do
      assert {:error, [error]} =
               Contract.validate_against(%{"type" => "array", "contains" => %{}}, [], "kinds")

      assert error =~ "does not implement contains"
    end
  end

  # One schema per keyword that MUST produce an error, so a keyword listed in @known without an
  # implementing clause fails here instead of silently passing every payload it appears in.
  @refusals %{
    "type" => {%{"type" => "string"}, 1},
    "required" => {%{"type" => "object", "required" => ["a"]}, %{}},
    "properties" => {%{"properties" => %{"a" => %{"type" => "string"}}}, %{"a" => 1}},
    "minimum" => {%{"minimum" => 2}, 1},
    "maximum" => {%{"maximum" => 2}, 3},
    "minLength" => {%{"minLength" => 2}, "a"},
    "maxLength" => {%{"maxLength" => 1}, "ab"},
    "pattern" => {%{"pattern" => "\\Aa\\z"}, "b"},
    "enum" => {%{"enum" => ["a"]}, "b"},
    "items" => {%{"items" => %{"type" => "string"}}, [1]},
    "minItems" => {%{"minItems" => 1}, []},
    "maxItems" => {%{"maxItems" => 1}, [1, 2]},
    "uniqueItems" => {%{"uniqueItems" => true}, [1, 1]},
    "minProperties" => {%{"minProperties" => 1}, %{}},
    "format" => {%{"format" => "uuid"}, "not-a-uuid"},
    "additionalProperties" => {%{"additionalProperties" => false}, %{"a" => 1}}
  }

  # `description` annotates and constrains nothing; it is the only known keyword with no refusal.
  @annotations ~w(description)

  test "every keyword in the known list is implemented, not merely listed" do
    assert Enum.sort(Map.keys(@refusals) ++ @annotations) == Enum.sort(Contract.known_keywords())

    for {keyword, {schema, value}} <- @refusals do
      assert {:error, [_ | _]} = Contract.validate_against(schema, value, keyword),
             "#{keyword} is in the known list but refuses nothing: it would pass every payload"
    end
  end

  test "every keyword the vendored file uses is one the validator implements" do
    # validate/2 reports an unimplemented keyword as a failure; walk every $defs entry
    # with a value that reaches every nested schema, and look for that message.
    schema =
      Path.expand("../../priv/runner_contract/v1.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    for {name, _} <- schema["$defs"] do
      {_, errors} =
        case Contract.validate(name, %{}) do
          :ok -> {:ok, []}
          other -> other
        end

      refute Enum.any?(errors, &(&1 =~ "does not implement")), "#{name}: #{inspect(errors)}"
    end

    nested = %{
      "sample" => %{
        "sampled_at" => "2026-09-13T05:00:00Z",
        "loadavg_1m" => 0,
        "free_ram_mb" => 0,
        "free_disk_mb" => 0
      }
    }

    assert Contract.validate("RunnerStatus", nested) == :ok

    # The trace batch nests its event schema under items; one event reaches it.
    run_id = "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f"

    batch = %{
      "run_id" => run_id,
      "dispatch_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
      "claim_epoch" => 0,
      "events" => [
        %{
          "run_id" => run_id,
          "seq" => 0,
          "event_id" => "0",
          "parent" => nil,
          "ts" => "2026-09-13T05:00:00Z",
          "type" => "run.started",
          "data" => %{}
        }
      ]
    }

    assert Contract.validate("RunnerTraceBatch", batch) == :ok
  end
end
