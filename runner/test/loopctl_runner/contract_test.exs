defmodule LoopctlRunner.ContractTest do
  use ExUnit.Case, async: false

  alias LoopctlRunner.{Contract, Health}

  defp join(overrides \\ %{}) do
    Map.merge(
      %{
        "contract_version" => "1.30.0",
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

  test "the vendored contract is v1.30.0 and names the socket and header the client uses" do
    assert Contract.version() == "1.30.0"

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

  test "triage arrives with its own bounds, readable from the contract rather than prose" do
    # 1.7.0 carries the triage dispatch and the verdict this runner emits. What this asserts is
    # that the bounds an emitter must respect are machine-readable, so the emitter reads them from
    # the contract the way DispatchRun reads the story's.
    limits = Contract.connection()["limits"]
    assert %{"fields" => triage_fields, "max_bytes" => triage_bytes} = limits["triage"]
    assert %{"untrusted" => %{"max_length" => untrusted}} = triage_fields
    assert is_integer(untrusted) and untrusted > 0 and untrusted < triage_bytes

    assert %{"fields" => verdict_fields, "max_bytes" => verdict_bytes} = limits["triage_verdict"]
    assert is_map(verdict_fields) and map_size(verdict_fields) > 0
    assert is_integer(verdict_bytes) and verdict_bytes > 0

    assert %{"properties" => %{"outcome" => %{"enum" => outcomes}}} =
             Contract.schema_def("RunnerTriageVerdict")

    assert "story" in outcomes
  end

  test "the published limits match the schema at EVERY depth, elements under item_fields" do
    # At 1.7.0 this table covered three array fields and was silent about the draft story and
    # contradicts, so a test pinned the gap and went red when loopctl closed it in 1.8.0. What it
    # asserts now is the property that makes the table usable by an emitter: every bound the
    # schema declares is published, with the same number, at every depth — a top-level check
    # would pass while a nested entry (story.fields.touches, contradicts.item_fields.why) was
    # dropped, which is the same regression one level down. The nesting itself carries meaning:
    # an ARRAY OF OBJECTS publishes ELEMENT bounds under `item_fields`, an OBJECT its own under
    # `fields`, and a reader that confused them would apply a per-element cap to the array.
    assert_published(
      Contract.connection()["limits"]["triage_verdict"]["fields"],
      Contract.schema_def("RunnerTriageVerdict")["properties"],
      "triage_verdict"
    )

    assert_published(
      Contract.connection()["limits"]["triage"]["fields"],
      Contract.schema_def("RunnerTriage")["properties"],
      "triage"
    )

    # The one table production code compiles in: DispatchRun builds its bounds from
    # limits.story.fields and then Map.takes the story down to those keys, so a dropped entry
    # would silently strip the field from the story a session is handed, not merely unbound it.
    assert_published(
      Contract.connection()["limits"]["story"]["fields"],
      Contract.schema_def("RunnerStory")["properties"],
      "story"
    )
  end

  # Both directions, at every depth: every bounded property is published, every published entry
  # and every ATTRIBUTE of one corresponds to a bound the schema declares, and the numbers agree.
  # One direction is not enough — a published `max_item_length` beside `item_fields` (a character
  # cap on an object element) is meaningless, and an emitter reading the table would apply it.
  defp assert_published(published, props, path) do
    bounded =
      props
      |> Enum.filter(fn {_name, sub} -> bounded?(sub) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert Enum.sort(Map.keys(published)) == bounded, "#{path}: published set differs"

    for {name, limit} <- published do
      sub = Map.fetch!(props, name)
      assert Enum.sort(Map.keys(limit)) == expected_attributes(sub), "#{path}.#{name}: attributes"
      assert_bounds(limit, sub, "#{path}.#{name}")
    end
  end

  # What the schema's shape entitles a published entry to carry, and nothing else.
  defp expected_attributes(sub) do
    [
      {"max_length", sub["maxLength"]},
      {"max_items", sub["maxItems"]},
      {"max_item_length", get_in(sub, ["items", "maxLength"])},
      {"fields", sub["properties"]},
      {"item_fields", get_in(sub, ["items", "properties"])}
    ]
    |> Enum.filter(fn {_key, declared} -> declared != nil end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # Bounded by what the schema DECLARES, not by shape: an object counts when something inside it
  # is bounded (an object of unbounded fields has nothing to publish), and an array of bounded
  # elements counts even with no maxItems of its own.
  defp bounded?(sub) do
    cond do
      Map.has_key?(sub, "maxLength") or Map.has_key?(sub, "maxItems") -> true
      props = sub["properties"] -> Enum.any?(props, fn {_name, s} -> bounded?(s) end)
      items = sub["items"] -> bounded?(items)
      true -> false
    end
  end

  defp assert_bounds(limit, sub, path) do
    if max = sub["maxLength"], do: assert(limit["max_length"] == max, "#{path}: max_length")
    if max = sub["maxItems"], do: assert(limit["max_items"] == max, "#{path}: max_items")

    if max = get_in(sub, ["items", "maxLength"]),
      do: assert(limit["max_item_length"] == max, "#{path}: max_item_length")

    # An object's own fields; never item_fields, which would say "each element" of a thing that
    # has no elements.
    if props = sub["properties"] do
      assert Map.has_key?(limit, "fields"), "#{path}: a bounded object published no fields"
      assert_published(limit["fields"], props, path)
    end

    # An array of objects: its ELEMENT bounds, and never under `fields`.
    if props = get_in(sub, ["items", "properties"]) do
      assert Map.has_key?(limit, "item_fields"), "#{path}: an array published no item_fields"
      assert_published(limit["item_fields"], props, path <> "[]")
    end
  end

  test "the validator cannot enforce the verdict's conditional shape, so the emitter must" do
    # "story is REQUIRED when outcome is story" is prose in the description: required lists only
    # outcome and confidence, and JSON Schema's if/then is outside what this validator implements.
    # A verdict claiming a story and carrying none passes here and is refused there.
    assert Contract.validate("RunnerTriageVerdict", %{
             "outcome" => "story",
             "confidence" => "high"
           }) ==
             :ok

    assert Contract.schema_def("RunnerTriageVerdict")["required"] == ["outcome", "confidence"]
  end

  test "field maxima alone do not keep a verdict inside the object cap" do
    # Every field at its published maximum fits, with little room; the same verdict written in
    # astral-plane characters (an emoji in a drafted title is ordinary) does not, because the byte
    # rule charges double for them. So the emitter checks ByteRule against max_bytes, the way
    # TraceShip does for a batch, and never field-by-field lengths alone.
    max_bytes = Contract.connection()["limits"]["triage_verdict"]["max_bytes"]
    bmp = maximal_verdict("a")
    astral = maximal_verdict(<<0x1F600::utf8>>)

    # Every property the schema declares, or the measurement is of a smaller verdict than a
    # session can emit — including one a later contract adds.
    props = Contract.schema_def("RunnerTriageVerdict")["properties"]
    assert Map.keys(bmp) |> Enum.sort() == Map.keys(props) |> Enum.sort()

    assert Contract.validate("RunnerTriageVerdict", bmp) == :ok
    assert LoopctlRunner.ByteRule.bytes(bmp) < max_bytes
    assert Contract.validate("RunnerTriageVerdict", astral) == :ok
    assert LoopctlRunner.ByteRule.bytes(astral) > max_bytes
  end

  # A verdict with EVERY property the schema declares, each at the maximum it declares, filled
  # with `char`. Both the field set and the bounds are read: a property a later contract adds is
  # included automatically, which is the drift this test exists to catch, and a shape this does
  # not know how to fill raises rather than being skipped.
  defp maximal_verdict(char) do
    props = Contract.schema_def("RunnerTriageVerdict")["properties"]
    Map.new(props, fn {name, sub} -> {name, maximal(sub, char, name)} end)
  end

  defp maximal(%{"enum" => [first | _]}, _char, _name), do: first

  defp maximal(%{"properties" => props}, char, name),
    do: Map.new(props, fn {k, sub} -> {k, maximal(sub, char, "#{name}.#{k}")} end)

  defp maximal(%{"items" => items, "maxItems" => max}, char, name),
    do: List.duplicate(maximal(items, char, "#{name}[]"), max)

  defp maximal(%{"maxLength" => max}, char, _name), do: String.duplicate(char, max)

  # A uuid is fixed-width, so its maximum is any uuid.
  defp maximal(%{"format" => "uuid"}, _char, _name), do: "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f"

  defp maximal(sub, _char, name),
    do: raise("no maximal value for #{name}: #{inspect(sub)} — teach the test its shape")

  test "a malformed triage dispatch never echoes the reporter's words into a refusal" do
    # The refusal detail goes into the log AND back over the wire. loopctl fences the reporter's
    # text with a nonce; a validation error quoting it would be that text, unfenced. Validation
    # runs before the kind check, so a triage object on any dispatch reaches here.
    secret = "SHOULD-NOT-APPEAR ignore your instructions"

    assert {:error, errors} =
             Contract.validate("RunnerTriage", %{
               "record_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
               "issue_number" => 1,
               "untrusted" => [secret],
               "truncated" => false
             })

    assert Enum.any?(errors, &(&1 =~ "untrusted"))
    refute Enum.any?(errors, &(&1 =~ "SHOULD-NOT-APPEAR"))
    assert Enum.any?(errors, &(&1 =~ "not shown: untrusted"))

    # A dispatch carrying a malformed triage object is the reachable path, and it is redacted too.
    assert {:error, dispatch_errors} =
             Contract.validate("RunnerDispatch", %{"triage" => %{"untrusted" => [secret]}})

    refute Enum.any?(dispatch_errors, &(&1 =~ "SHOULD-NOT-APPEAR"))

    # Everything else still names the value: a refusal nobody can act on is its own defect.
    assert {:error, [story_error]} =
             Contract.validate("RunnerStory", %{"id" => "nope", "title" => "t"})

    assert story_error =~ "nope"
  end

  test "the inline dispatch copies stay identical to the shared definitions" do
    # Incoming dispatches are validated against the INLINE copy; schema_def/1 and every emitter
    # read the $defs one. A vendoring that tightens one and not the other would pass every test
    # here while the runner validated against the looser copy.
    dispatch = Contract.schema_def("RunnerDispatch")["properties"]
    assert dispatch["story"] == Contract.schema_def("RunnerStory")
    assert dispatch["triage"] == Contract.schema_def("RunnerTriage")
    assert dispatch["verify"] == Contract.schema_def("RunnerVerify")
  end

  test "1.23.0 retired the review kind: no review object, no review messages" do
    dispatch = Contract.schema_def("RunnerDispatch")
    refute Map.has_key?(dispatch["properties"], "review")
    # 1.26.0 (US-48.9) added reply_draft, 1.28.0 (US-48.18) verify, 1.30.0 (US-48.13) spec_tune.
    assert dispatch["properties"]["kind"]["enum"] |> Enum.sort() ==
             ["implement", "reply_draft", "spec_tune", "triage", "verify"]

    connection = Contract.connection()

    for event <- ~w(checkpoint review_finding review_verdict thread_entry) do
      refute Map.has_key?(connection["events"], event), event
      refute Map.has_key?(connection["errors"], event), event
    end
  end

  test "the declaration is exactly the kinds the accept path can actually run" do
    # Widening @kinds declares a capability loopctl then sends, and a declared kind with no accept
    # path of its own is refused as `other` — suppressing nothing, recording nothing, and soaking
    # that kind for as long as it is declared. `implement` and `triage` each have one; `triage` is
    # declared because its verdict carries the `lens_verdicts` Gate A reads (1.15.0), without which
    # every triage would escalate. `review` left `dispatchable_kinds` in 1.23.0, and `reply_draft`
    # joined it in 1.26.0, run on triage's detached-tree accept path and answered by agent_result.
    # `verify` joined in 1.28.0 on the same path, over the story and the pull request's head, and
    # `spec_tune` in 1.30.0, the one story-less kind, over the repo at its base.
    assert LoopctlRunner.Control.kinds() == [
             "implement",
             "triage",
             "reply_draft",
             "verify",
             "spec_tune"
           ]

    # And they are every kind loopctl sends, so nothing it sends is soaked as undeclared.
    dispatchable = Contract.connection()["dispatchable_kinds"]
    assert Enum.sort(LoopctlRunner.Control.kinds()) == Enum.sort(dispatchable)
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

  test "every NESTED schema is reached, so an unimplemented keyword inside one cannot hide" do
    # validate/2 with %{} never descends: `properties` only checks a key the VALUE carries, so a
    # keyword inside a nested definition is never visited. That is the shape of the 1.6.0
    # regression this validator's known-list exists to prevent, one level down. A probe value
    # built from each schema reaches every nested schema in the file, including definitions a
    # later contract adds, which hand-written payloads would not.
    for {name, schema} <- vendored()["$defs"] do
      errors =
        case Contract.validate(name, probe(schema)) do
          :ok -> []
          {:error, errors} -> errors
        end

      refute Enum.any?(errors, &(&1 =~ "does not implement")), "#{name}: #{inspect(errors)}"
    end
  end

  defp vendored do
    Path.expand("../../priv/runner_contract/v1.json", __DIR__) |> File.read!() |> Jason.decode!()
  end

  # A value that visits every branch of `schema`: every property of an object, one item of an
  # array. It need not satisfy the constraints — only reach them.
  defp probe(%{"enum" => [first | _]}), do: first

  defp probe(%{"properties" => _} = schema),
    do: Map.merge(named_properties(schema), extra_property(schema))

  defp probe(%{"items" => items}), do: [probe(items)]

  # Before the bare `type` clause: an object schema with NO properties (RunnerTraceEvent.data is
  # exactly that) would otherwise probe as %{} and never reach its subschema.
  defp probe(%{"additionalProperties" => sub} = schema) when is_map(sub),
    do: Map.merge(named_properties(schema), extra_property(schema))

  defp probe(%{"type" => type}) do
    case List.wrap(type) |> Enum.reject(&(&1 == "null")) do
      ["integer" | _] -> 0
      ["number" | _] -> 0
      ["boolean" | _] -> true
      ["object" | _] -> %{}
      ["array" | _] -> []
      _ -> "x"
    end
  end

  defp probe(_schema), do: "x"

  defp named_properties(%{"properties" => props}),
    do: Map.new(props, fn {k, sub} -> {k, probe(sub)} end)

  defp named_properties(_schema), do: %{}

  # `additionalProperties` as a SUBSCHEMA is checked against properties `properties` does not
  # name, so a probe carrying only named keys never reaches it — and it is the one
  # subschema-bearing keyword this validator implements.
  defp extra_property(%{"additionalProperties" => sub}) when is_map(sub),
    do: %{"probe-extra" => probe(sub)}

  defp extra_property(_schema), do: %{}

  test "an unimplemented keyword at the TOP of a definition fails validation" do
    # validate/2 reports an unimplemented keyword as a failure. An empty map reaches only the
    # top level of each definition: `properties` descends into a key the VALUE carries, so this
    # says nothing about nested schemas. The probe test above is what covers those.
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

  test "every message and reply x-connection names is a schema the contract also defines" do
    # A dangling name is not a documentation slip: it is the envelope going unpublished. loopctl's
    # 1.9.0 named RunnerTriageVerdictMessage and RunnerTriageVerdictAck in x-connection and defined
    # neither, so the only way to build a triage_verdict from that file was to re-type its shape out
    # of the commit message that announced it — which is what publishing the bounds exists to end,
    # and how the two sides' enums drift apart with nothing able to notice. Vendoring is a copy, so
    # this is the first moment on this side that can catch it.
    connection = Contract.connection()

    # Per map, and by fetch!. Both halves are about the guard being able to fail: taken on the
    # concatenation, an exporter that emitted an empty `events` while `replies` kept its entries
    # would leave every event name unchecked with the assertion still green — the same shape as
    # the 1.6.0 exporter drop this validator already carries a comment about. And Access would
    # hand a missing map back as nil, so the red would be a BadMapError naming neither the key
    # nor the contract; every other reader of this document uses fetch! for that reason.
    for map <- ~w(events replies) do
      named = Map.fetch!(connection, map)
      assert named != %{}, "x-connection.#{map} names nothing at all"

      for {event, name} <- named do
        assert name in Contract.definitions(),
               "x-connection.#{map}.#{event} names #{name}, which $defs does not define"
      end
    end
  end

  describe "the triage verdict message" do
    @dispatch %{
      "dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
      "claim_epoch" => 3
    }

    test "an incomplete run may send verdict and detail as explicit nulls" do
      # The one the loopctl session flagged, and the reason it is worth a test on THIS side: its
      # first inlining dropped `nullable` from `verdict`, so a message carrying "verdict": null
      # beside a real `incomplete` would have been refused invalid_payload — which is in
      # x-connection.permanent_errors, so a conforming runner does not resend and the run's only
      # output is lost for good. An emitter that serialises every field of a struct sends exactly
      # that shape, and nothing about the failure is visible from here.
      message =
        Map.merge(@dispatch, %{
          "verdict" => nil,
          "incomplete" => "no_verdict_written",
          "detail" => nil
        })

      assert Contract.validate("RunnerTriageVerdictMessage", message) == :ok
    end

    test "the five incomplete reasons are the contract's, and checkout_unreadable is one" do
      # Transcribing this enum out of loopctl's commit message lost checkout_unreadable, which is
      # how this repo came to be missing a reason it had a verified condition for. Read from the
      # file now, and this test is what fails if the file and the code disagree again.
      %{"enum" => reasons} =
        Contract.schema_def("RunnerTriageVerdictMessage")
        |> get_in(["properties", "incomplete"])

      # null is a member too since 1.9.2, because the field is nullable — see the test below.
      assert Enum.sort(Enum.reject(reasons, &is_nil/1)) ==
               Enum.sort(~w(session_crashed wall_clock_exceeded checkout_unreadable
                            no_verdict_written verdict_invalid))

      assert nil in reasons

      for reason <- reasons do
        assert Contract.validate(
                 "RunnerTriageVerdictMessage",
                 Map.put(@dispatch, "incomplete", reason)
               ) ==
                 :ok
      end

      assert {:error, [error]} =
               Contract.validate(
                 "RunnerTriageVerdictMessage",
                 Map.put(@dispatch, "incomplete", "gave_up")
               )

      # And it NAMES the bad value. An incomplete reason is a runner-authored keyword from a
      # closed enum, never anyone's prose, so there is nothing here to suppress and a refusal that
      # hid it could not be acted on. This assertion used to be its opposite, passing only because
      # the suppression matched on a name prefix that 1.9.1's two new definitions happen to share
      # with the verdict's.
      assert error =~ "incomplete"
      assert error =~ "gave_up"
    end

    test "EXACTLY ONE OF verdict and incomplete is prose, so the sender owes the rule" do
      # The schema carries neither oneOf nor a conditional: `verdict` and `incomplete` are both
      # optional and both nullable, so a message with BOTH and a message with NEITHER validate
      # here and are refused invalid_payload on the wire — permanently, since that code is in
      # x-connection.permanent_errors. This is pinned rather than worked around: the rule belongs
      # in whatever builds the message, the way TriageVerdict already carries the conditional story
      # rule, and this test goes red the day loopctl publishes a keyword that would enforce it.
      verdict = %{"outcome" => "escalate", "confidence" => "high"}

      assert Contract.validate("RunnerTriageVerdictMessage", @dispatch) == :ok

      assert Contract.validate(
               "RunnerTriageVerdictMessage",
               Map.merge(@dispatch, %{"verdict" => verdict, "incomplete" => "verdict_invalid"})
             ) == :ok

      keywords = Map.keys(Contract.schema_def("RunnerTriageVerdictMessage"))
      assert Enum.sort(keywords) == ~w(description properties required type)
    end

    test "the envelope's own fields name their values; the verdict's leaves never do" do
      # The suppression exists for text a REPORTER or a session wrote. dispatch_id, claim_epoch,
      # recorded_at and replayed are loopctl's own, and a refusal that will not name a malformed
      # timestamp loopctl itself sent is unactionable — which is what a prefix match over
      # RunnerTriageVerdictMessage and RunnerTriageVerdictAck produced, since both names begin
      # with the verdict definition's.
      assert {:error, [error]} =
               Contract.validate("RunnerTriageVerdictMessage", %{
                 @dispatch
                 | "dispatch_id" => "nope"
               })

      assert error =~ "nope"

      assert {:error, [error]} =
               Contract.validate("RunnerTriageVerdictAck", %{
                 "recorded_at" => "not-a-time",
                 "replayed" => false
               })

      assert error =~ "not-a-time"

      # The verdict inlined into the message is still the session's, leaf by leaf.
      verdict = %{"outcome" => "escalate", "confidence" => "loud"}

      assert {:error, [error]} =
               Contract.validate(
                 "RunnerTriageVerdictMessage",
                 Map.put(@dispatch, "verdict", verdict)
               )

      assert error =~ "verdict.confidence"
      refute error =~ "loud"

      # And as the definition validated by its own name, which is where it arrives from disk.
      assert {:error, [error]} = Contract.validate("RunnerTriageVerdict", verdict)
      refute error =~ "loud"
    end

    test "incomplete may be sent as an explicit null, as verdict may" do
      # Until 1.9.2 it could not: the field was typed ["string","null"] while its enum listed only
      # the five reasons, and under 2020-12 an enum constrains every instance including null. So a
      # message carrying a real verdict beside "incomplete": null was refused invalid_payload —
      # permanent — while the same shape with the fields swapped was accepted, and an emitter that
      # serialises a struct whole sends both. This test asserted that refusal and pinned it as a
      # sender rule; 1.9.2 publishes null as a member of the enum, so the asymmetry is gone and
      # this is the direction that must now hold.
      message =
        Map.merge(@dispatch, %{
          "verdict" => %{"outcome" => "escalate", "confidence" => "high"},
          "incomplete" => nil
        })

      assert Contract.validate("RunnerTriageVerdictMessage", message) == :ok

      assert Contract.validate("RunnerTriageVerdictMessage", Map.delete(message, "incomplete")) ==
               :ok

      # A reason outside the enum is still refused, null or no null.
      assert {:error, _} =
               Contract.validate("RunnerTriageVerdictMessage", %{
                 message
                 | "incomplete" => "gave_up"
               })
    end

    test "the inlined verdict and the verdict definition are the same schema" do
      # The file now carries the verdict twice: TriageVerdict.read/1 validates what the session
      # wrote against the $def, and the wire message will be validated against the inline copy. A
      # vendor that updated one and not the other would make a verdict this runner accepts and
      # records refused invalid_payload on the wire — permanent, and invisible until it happened.
      inline =
        Contract.schema_def("RunnerTriageVerdictMessage") |> get_in(["properties", "verdict"])

      # Set aside only what MUST differ: the inline copy says what the field is for, and is
      # nullable because the message sends it or its counterpart.
      assert Map.drop(inline, ["description", "type"]) ==
               Map.drop(Contract.schema_def("RunnerTriageVerdict"), ["description", "type"])

      assert inline["type"] == ["object", "null"]
    end

    test "the reason lists Control keeps by hand agree with the contract's permanent_errors" do
      # Three hand-written lists decide whether a refusal is retried, and the contract publishes
      # the answer — the same re-typing the vendoring rule exists to prevent, one layer up. Today
      # they agree; this is what notices when a vendored contract moves one of them.
      permanent = Contract.connection() |> Map.fetch!("permanent_errors") |> Map.fetch!("*")

      for reason <- LoopctlRunner.Control.fatal_reasons() ++ LoopctlRunner.Control.given_up() do
        assert reason in permanent,
               "#{reason} is given up on, and the contract does not call it permanent"
      end

      # dispatch_not_accepted is in the flat list AND carries a condition, published as of 1.9.2:
      # permanence for it is conditional, because the refusal covers three ledger states and only
      # one of them is still moving. That is why the reason is not in given_up/0 and must not be
      # added to it — giving up at once would abandon the traces of runs whose accept is simply
      # still in flight. What READS the condition is `Control.accept_outstanding?/2`, and this
      # assertion does not check it: only that runner's own tests, driving real dispatch
      # sequences, can say whether it reads all three conjuncts. This is the contract half.
      assert "dispatch_not_accepted" in permanent

      assert Contract.connection()
             |> Map.fetch!("permanent_error_conditions")
             |> Map.fetch!("dispatch_not_accepted") =~ "claim_epoch"

      refute "dispatch_not_accepted" in LoopctlRunner.Control.given_up()
    end

    test "permanent_errors is the \"*\" codes and the event's own; event_permanent_errors only its own" do
      table = Contract.connection() |> Map.fetch!("permanent_errors")

      for {event, own} <- Map.delete(table, "*") do
        assert Contract.permanent_errors(event) == table["*"] ++ own
        assert Contract.event_permanent_errors(event) == own
      end

      refute Map.has_key?(table, "session_ended")
      assert Contract.permanent_errors("session_ended") == table["*"]
      assert Contract.event_permanent_errors("session_ended") == []

      # The distinction the second exists for: permanent outright for this event, conditional in "*".
      assert "stale_stage" in Contract.event_permanent_errors("triage_verdict")
    end

    test "claim_ending_errors reads the published table, and an unkeyed event ends no claim" do
      # 1.22.0. Every code in the table is published for its event and permanent for it: a claim
      # end that could clear would be the wrong answer to give up a dispatch on.
      connection = Contract.connection()
      table = Map.fetch!(connection, "claim_ending_errors")
      permanent = Map.fetch!(connection, "permanent_errors")
      assert map_size(table) > 0

      for {event, codes} <- table do
        assert Contract.claim_ending_errors(event) == codes

        for code <- codes do
          assert code in get_in(connection, ["errors", event]), "#{event} #{code}"
          assert code in (permanent["*"] ++ Map.get(permanent, event, [])), "#{event} #{code}"
        end
      end

      # Not keyed, so none: the session's own end is never a claim-ending refusal.
      refute Map.has_key?(table, "session_ended")
      assert Contract.claim_ending_errors("session_ended") == []
      assert Contract.claim_ending_errors("trace_cursor") == []

      # The two per-message codes 1.22.0 introduced are permanent everywhere and end no claim.
      for code <- ~w(claim_epoch_mismatch wrong_dispatch_kind) do
        assert code in permanent["*"]
        refute Enum.any?(Map.values(table), &(code in &1))
      end

      assert connection["claim_ending_remedy"] =~ "stop its session"
    end

    test "error_fields answers per event and per code, and raises rather than reading nil" do
      # The table is COMPLETE as of 1.11.0: a code that carries nothing publishes an explicit [].
      # So nothing found means the event or the code is not published, which must be loud — got
      # rather than fetched, a caller reading a field off a refusal would read nil off every
      # refusal from the next vendoring on, and fall back to whatever guess the field replaced.
      assert "stage" in Contract.error_fields("stage", "stale_stage")
      assert Contract.error_fields("stage", "internal_error") == []
      assert Contract.error_fields("join", "rate_limited") == ~w(max_joins window_ms)

      assert_raise KeyError, fn -> Contract.error_fields("stage", "no_such_code") end
      assert_raise KeyError, fn -> Contract.error_fields("no_such_event", "internal_error") end
    end

    test "a stale_stage refusal of a stage report carries the row, and its permanence is conditional" do
      # Both halves are what `Control` retries a terminal report on. Until 1.11.0 the refusal said
      # only `stale_stage`, so the runner walked a fixed list of the stages the story could be at;
      # on 2026-09-14 all three were refused in turn and not one could say where the row was.
      assert Contract.error_fields("stage", "stale_stage") ==
               ~w(stage claim_epoch lock_version attempts effects)

      condition =
        Contract.connection()
        |> Map.fetch!("permanent_error_conditions")
        |> Map.fetch!("stale_stage")

      assert condition =~ "stage_transitions"
      assert condition =~ "PERMANENT"

      # The condition turns on that table, so it must name a `from` for every stage a report can
      # leave — and leave `escalated` naming none, which is what makes the permanence reachable.
      froms = Contract.connection() |> Map.fetch!("stage_transitions") |> Enum.map(& &1["from"])

      assert "implementing" in froms
      refute "escalated" in froms
    end

    test "a length is counted in CODEPOINTS, the way loopctl counts it" do
      # String.length counts GRAPHEMES, which is the looser count: a family emoji is one grapheme
      # and seven code points. Checked that way, this validator passed payloads loopctl refuses
      # invalid_payload — permanent, so the run's only output is lost — which is the exact failure
      # validating on this side exists to prevent. The detail cap in TriageRun cuts by code
      # points; this is the check agreeing with it.
      schema = %{"type" => "string", "maxLength" => 5}

      one_grapheme = "👨‍👩‍👧‍👦"
      assert String.length(one_grapheme) == 1
      assert one_grapheme |> String.codepoints() |> length() == 7

      assert {:error, [error]} = Contract.validate_against(schema, one_grapheme, "detail")
      assert error =~ "longer than 5"

      assert Contract.validate_against(schema, String.duplicate("a", 5), "detail") == :ok
      assert {:error, _} = Contract.validate_against(schema, String.duplicate("a", 6), "detail")
    end

    test "the detail is untrusted, because the contract's own description says so" do
      # The narrowing that stopped suppressing loopctl's envelope fields freed this one with them.
      # TriageRun fills it from an escalating session's prose, and v1.json calls it "UNTRUSTED like
      # every other runner-authored string".
      assert Contract.schema_def("RunnerTriageVerdictMessage")
             |> get_in(["properties", "detail", "description"]) =~ "UNTRUSTED"

      assert {:error, [error]} =
               Contract.validate("RunnerTriageVerdictMessage", Map.put(@dispatch, "detail", 12))

      assert error =~ "detail"
      refute error =~ "12"
    end

    test "the ack says when the verdict was first recorded and whether this was a resend" do
      # `replayed` is what makes the idempotent resend observable here: an ok that applied nothing
      # and an ok that recorded the verdict are otherwise the same answer.
      ack = %{"recorded_at" => "2026-09-15T12:00:00Z", "replayed" => true}
      assert Contract.validate("RunnerTriageVerdictAck", ack) == :ok

      for missing <- ~w(recorded_at replayed) do
        assert {:error, _} = Contract.validate("RunnerTriageVerdictAck", Map.delete(ack, missing))
      end
    end
  end
end
