defmodule LoopctlWeb.ChangeEventControllerTest do
  @moduledoc """
  US-47.3: `POST /api/v1/change_events/:source_id`, chg-server's event webhook — the wire half.
  The context's rules are `Loopctl.Changes.EventsTest`.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  setup do
    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{})
    %{secret: secret, source: source, root: root, tenant_id: source.tenant_id}
  end

  # Whitespace a re-encoder would drop, so a verifier reading parsed params instead of the raw
  # bytes would compute a different HMAC.
  defp encode(event), do: Jason.encode!(event, pretty: true) <> "\n"

  defp post_event(conn, ctx, raw, opts \\ []) do
    ts = Keyword.get(opts, :timestamp, Integer.to_string(System.os_time(:second)))
    secret = Keyword.get(opts, :secret, ctx.secret)

    signature =
      Keyword.get(opts, :signature, Signature.header(secret, Signature.delivery_string(ts, raw)))

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-chg-timestamp", ts)
    |> then(fn c ->
      if signature, do: put_req_header(c, "x-chg-signature", signature), else: c
    end)
    |> post("/api/v1/change_events/#{Keyword.get(opts, :source_id, ctx.source.id)}", raw)
  end

  defp event(change_id, seq, attrs \\ %{}),
    do: build(:chg_event, Map.merge(%{change_id: change_id, event_seq: seq}, attrs))

  defp event_rows(tenant_id),
    do: AdminRepo.aggregate(from(e in Event, where: e.tenant_id == ^tenant_id), :count)

  defp audit_rows(tenant_id) do
    AdminRepo.aggregate(
      from(e in Entry, where: e.tenant_id == ^tenant_id and e.action == "change_event_applied"),
      :count
    )
  end

  @unauthorized %{
    "error" => %{
      "status" => 401,
      "code" => "invalid_signature",
      "message" => "The event could not be authenticated."
    }
  }

  describe "AC-47.3.1 / TC-47.3.1: one 401 for every refusal" do
    test "unknown source, wrong HMAC and a 6-minute-old timestamp answer identically",
         %{
           conn: conn
         } = ctx do
      raw = encode(event("C1", 1))
      stale = Integer.to_string(System.os_time(:second) - 360)

      bodies =
        for opts <- [
              [source_id: Ecto.UUID.generate()],
              [signature: "sha256=" <> String.duplicate("0", 64)],
              [timestamp: stale]
            ] do
          conn |> post_event(ctx, raw, opts) |> json_response(401)
        end

      assert Enum.uniq(bodies) == [@unauthorized]
      assert event_rows(ctx.tenant_id) == 0
    end

    test "a missing signature header is the same 401", %{conn: conn} = ctx do
      assert conn |> post_event(ctx, encode(event("C1", 1)), signature: nil) |> json_response(401) ==
               @unauthorized
    end
  end

  describe "AC-47.3.7 / TC-47.3.6: a revoked root refuses the event" do
    test "401 with the same body as TC-47.3.1, no event row and no audit entry",
         %{conn: conn} = ctx do
      {1, _} =
        AdminRepo.update_all(from(d in Dispatch, where: d.id == ^ctx.root.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert conn |> post_event(ctx, encode(event("C1", 1))) |> json_response(401) ==
               @unauthorized

      assert event_rows(ctx.tenant_id) == 0
      assert audit_rows(ctx.tenant_id) == 0
    end
  end

  describe "AC-47.3.2 / TC-47.3.2: redelivery" do
    test "200 duplicate: true and one audit entry", %{conn: conn} = ctx do
      raw = encode(event("C1", 1))

      assert %{"status" => "ok", "outcome" => "applied", "duplicate" => false, "applied_seq" => 1} =
               conn |> post_event(ctx, raw) |> json_response(200)

      assert %{
               "status" => "ok",
               "outcome" => "duplicate",
               "duplicate" => true,
               "applied_seq" => 1
             } =
               build_conn() |> post_event(ctx, raw) |> json_response(200)

      assert audit_rows(ctx.tenant_id) == 1
    end

    test "the same key with different content is 409 event_conflict", %{conn: conn} = ctx do
      e = event("C1", 1)
      assert conn |> post_event(ctx, encode(e)) |> json_response(200)

      assert %{"error" => %{"code" => "event_conflict"}} =
               build_conn()
               |> post_event(ctx, encode(Map.put(e, "revision", 9)))
               |> json_response(409)
    end
  end

  describe "AC-47.3.3 / TC-47.3.3: out of order" do
    test "seq 2 applies only after seq 1", %{conn: conn} = ctx do
      assert %{"outcome" => "held", "applied_seq" => 0} =
               conn |> post_event(ctx, encode(event("C1", 2))) |> json_response(200)

      assert [%Event{applied_at: nil}] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")

      assert %{"outcome" => "applied", "applied_seq" => 2} =
               build_conn() |> post_event(ctx, encode(event("C1", 1))) |> json_response(200)
    end
  end

  describe "AC-47.3.6 / TC-47.3.5: an unmapped kind keeps ordering whole" do
    test "review_requested answers 2xx and is recorded; review_findings applies at once",
         %{conn: conn} = ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})
      submitted = event("C1", 1, %{kind: "submitted", data: %{"story_id" => story.id}})
      requested = event("C1", 2, %{kind: "review_requested"})

      findings =
        event("C1", 3, %{kind: "review_findings", data: %{"findings" => 1, "round" => 1}})

      assert %{"applied_seq" => 1} =
               conn |> post_event(ctx, encode(submitted)) |> json_response(200)

      assert %{"outcome" => "applied", "applied_seq" => 2} =
               build_conn() |> post_event(ctx, encode(requested)) |> json_response(200)

      assert %{"outcome" => "applied", "applied_seq" => 3} =
               build_conn() |> post_event(ctx, encode(findings)) |> json_response(200)
    end
  end

  describe "the body" do
    test "a signed but malformed envelope is 400 invalid_event", %{conn: conn} = ctx do
      assert %{"error" => %{"code" => "invalid_event"}} =
               conn
               |> post_event(ctx, encode(Map.delete(event("C1", 1), "kind")))
               |> json_response(400)
    end

    test "AC-47.3.5: a body over the cap is 413 before anything is read", %{conn: conn} = ctx do
      max = Events.max_body_bytes()
      raw = encode(event("C1", 1, %{data: %{"pad" => String.duplicate("x", max)}}))

      assert %{"error" => %{"code" => "payload_too_large", "message" => message}} =
               conn |> post_event(ctx, raw) |> json_response(413)

      assert message =~ "A change event body may be at most #{max} bytes"
      assert event_rows(ctx.tenant_id) == 0
    end

    test "a body at the cap is read", %{conn: conn} = ctx do
      base = encode(event("C1", 1, %{data: %{"pad" => ""}}))
      pad = Events.max_body_bytes() - byte_size(base)
      raw = encode(event("C1", 1, %{data: %{"pad" => String.duplicate("x", pad)}}))
      assert byte_size(raw) == Events.max_body_bytes()

      assert %{"outcome" => "applied"} = conn |> post_event(ctx, raw) |> json_response(200)
    end
  end

  describe "AC-47.3.5: the request makes no outbound call" do
    test "not even for an event held ahead of a gap", %{conn: conn} = ctx do
      # Zero calls allowed: verify_on_exit! fails the test if the request reached chg-server.
      Mox.expect(Loopctl.MockChgClient, :events_after, 0, fn _, _, _, _ -> {:ok, []} end)

      assert %{"outcome" => "held"} =
               conn |> post_event(ctx, encode(event("C1", 5))) |> json_response(200)
    end
  end

  describe "AC-47.3.5: the operation spec" do
    test "documents the 401, the 500, the duplicate answer and the body cap" do
      spec = Loopctl.ApiSpec.spec()
      op = spec.paths["/api/v1/change_events/{source_id}"].post

      assert Map.has_key?(op.responses, 401)
      assert Map.has_key?(op.responses, 413)

      # The 500 a failed apply answers, with the message the response carries.
      assert %{description: failed} = op.responses[500]
      assert failed =~ "change_event_failed"
      assert failed =~ "The event could not be recorded. Redeliver it."
      assert op.description =~ "duplicate: true"
      assert op.description =~ "at most #{Events.max_body_bytes()} bytes"
      assert op.security == []
    end
  end

  describe "the per-IP throttle" do
    test "is on the route, in a bucket of its own, and fail-closed", %{conn: conn} = ctx do
      parent = self()

      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
        send(parent, {:bucket, bucket})
        {:error, :limiter_down}
      end)

      denied =
        conn
        |> put_req_header("fly-client-ip", "203.0.113.61")
        |> post_event(ctx, encode(event("C1", 1)))

      assert denied.status == 429
      assert_received {:bucket, "change_events_ip:203.0.113.61"}
      assert event_rows(ctx.tenant_id) == 0
    end
  end

  describe "tenant isolation" do
    test "another tenant's source id, signed with this source's secret, is the same 401",
         %{conn: conn} = ctx do
      %{source: other} = fixture(:chg_source, %{})

      assert conn
             |> post_event(ctx, encode(event("C1", 1)), source_id: other.id)
             |> json_response(401) == @unauthorized

      assert event_rows(other.tenant_id) == 0
      assert event_rows(ctx.tenant_id) == 0
    end
  end
end
