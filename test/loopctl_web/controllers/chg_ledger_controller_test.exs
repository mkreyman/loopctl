defmodule LoopctlWeb.ChgLedgerControllerTest do
  @moduledoc """
  US-50.1: `POST /api/v1/chg_ledger/:source_id`, the fleet chg senders' ledger batch.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Ledger
  alias Loopctl.Changes.LedgerRow
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches.Dispatch

  setup :verify_on_exit!

  setup do
    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{})
    %{secret: secret, source: source, root: root, tenant_id: source.tenant_id}
  end

  @unauthorized %{
    "error" => %{
      "status" => 401,
      "code" => "invalid_signature",
      "message" => "The event could not be authenticated."
    }
  }

  defp post_batch(conn, ctx, raw, opts \\ []) do
    ts = Integer.to_string(System.os_time(:second))
    secret = Keyword.get(opts, :secret, ctx.secret)

    signature =
      Keyword.get(opts, :signature, Signature.header(secret, Signature.delivery_string(ts, raw)))

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-chg-timestamp", ts)
    |> put_req_header("x-chg-signature", signature)
    |> post("/api/v1/chg_ledger/#{Keyword.get(opts, :source_id, ctx.source.id)}", raw)
  end

  defp batch(rows), do: Jason.encode!(%{rows: rows}, pretty: true) <> "\n"

  defp row(kind, attrs \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "kind" => kind,
        "repo" => "mkreyman/infra",
        "host" => "minis",
        "sha" => "0123456789abcdef0123456789abcdef01234567",
        "at_ms" => 1_763_400_000_000,
        "verdict" => "pass",
        "ms" => 1234
      },
      attrs
    )
  end

  defp rows(tenant_id),
    do: AdminRepo.all(from(r in LedgerRow, where: r.tenant_id == ^tenant_id))

  describe "TC-50.1.1: a batch inserts and a redelivery is all duplicates" do
    test "inserted 2, then duplicates 2", %{conn: conn} = ctx do
      raw = batch([row("chg"), row("gate", %{"ms" => 99})])

      assert %{"inserted" => 2, "duplicates" => 0, "rejected" => []} =
               conn |> post_batch(ctx, raw) |> json_response(200)

      assert %{"inserted" => 0, "duplicates" => 2, "rejected" => []} =
               build_conn() |> post_batch(ctx, raw) |> json_response(200)

      stored = rows(ctx.tenant_id)
      assert length(stored) == 2
      assert Enum.all?(stored, &(&1.source_id == ctx.source.id and &1.repo == "mkreyman/infra"))
      assert Enum.any?(stored, &(&1.kind == "gate" and &1.ms == 99 and &1.verdict == "pass"))
    end

    test "the same row twice in one batch is written once", %{conn: conn} = ctx do
      assert %{"inserted" => 1, "duplicates" => 1} =
               conn |> post_batch(ctx, batch([row("chg"), row("chg")])) |> json_response(200)
    end

    test "key order does not change the row's identity", %{conn: conn} = ctx do
      first = ~s({"rows":[{"v":1,"kind":"runner","repo":"mkreyman/infra","host":"x1","at_ms":5}]})

      second =
        ~s({"rows":[{"at_ms":5,"host":"x1","repo":"mkreyman/infra","kind":"runner","v":1}]})

      assert %{"inserted" => 1} = conn |> post_batch(ctx, first) |> json_response(200)
      assert %{"duplicates" => 1} = build_conn() |> post_batch(ctx, second) |> json_response(200)
    end
  end

  describe "TC-50.1.2: one bad row does not fail the batch" do
    test "invalid_row and repo_mismatch by index", %{conn: conn} = ctx do
      raw =
        batch([
          row("chg"),
          Map.delete(row("chg"), "sha"),
          row("gate", %{"repo" => "mkreyman/loopctl"})
        ])

      assert %{
               "inserted" => 1,
               "duplicates" => 0,
               "rejected" => [
                 %{"index" => 1, "reason" => "invalid_row"},
                 %{"index" => 2, "reason" => "repo_mismatch"}
               ]
             } = conn |> post_batch(ctx, raw) |> json_response(200)

      assert length(rows(ctx.tenant_id)) == 1
    end

    test "a bad verdict, a non-object and a missing at_ms are invalid_row", %{conn: conn} = ctx do
      raw =
        batch([row("gate", %{"verdict" => "maybe"}), "nope", Map.delete(row("flaky"), "at_ms")])

      assert %{"inserted" => 0, "rejected" => rejected} =
               conn |> post_batch(ctx, raw) |> json_response(200)

      assert Enum.map(rejected, & &1["reason"]) == ["invalid_row", "invalid_row", "invalid_row"]
    end

    test "a U+0000 in a value or key is invalid_row and the rest are stored",
         %{conn: conn} = ctx do
      raw =
        batch([
          row("chg"),
          row("flaky", %{"note" => "a" <> <<0>> <> "b"}),
          row("flaky", %{("k" <> <<0>>) => 1}),
          # A literal backslash-u text is not a NUL and is stored.
          row("flaky", %{"note" => "\\u0000 is text"})
        ])

      assert %{"inserted" => 2, "rejected" => rejected} =
               conn |> post_batch(ctx, raw) |> json_response(200)

      assert rejected == [
               %{"index" => 1, "reason" => "invalid_row"},
               %{"index" => 2, "reason" => "invalid_row"}
             ]

      assert length(rows(ctx.tenant_id)) == 2
    end

    test "the repo is matched case-insensitively", %{conn: conn} = ctx do
      assert %{"inserted" => 1} =
               conn
               |> post_batch(ctx, batch([row("chg", %{"repo" => "MKreyman/Infra"})]))
               |> json_response(200)
    end
  end

  describe "the batch" do
    test "not {rows: [...]}, empty, or over the cap is 400 invalid_batch", %{conn: conn} = ctx do
      too_many = batch(List.duplicate(row("runner"), Ledger.max_batch() + 1))

      for raw <- [~s({"rows": {}}), ~s({"rows": []}), "not json", too_many] do
        assert %{"error" => %{"code" => "invalid_batch"}} =
                 conn |> post_batch(ctx, raw) |> json_response(400)
      end

      assert rows(ctx.tenant_id) == []
    end
  end

  describe "TC-50.1.3: refusals share the 401" do
    test "a wrong signature and an unknown source answer identically", %{conn: conn} = ctx do
      raw = batch([row("chg")])

      bodies =
        for opts <- [
              [signature: "sha256=" <> String.duplicate("0", 64)],
              [source_id: Ecto.UUID.generate()]
            ] do
          conn |> post_batch(ctx, raw, opts) |> json_response(401)
        end

      assert Enum.uniq(bodies) == [@unauthorized]
      assert rows(ctx.tenant_id) == []
    end

    test "a revoked root is the same 401", %{conn: conn} = ctx do
      {1, _} =
        AdminRepo.update_all(from(d in Dispatch, where: d.id == ^ctx.root.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert conn |> post_batch(ctx, batch([row("chg")])) |> json_response(401) == @unauthorized
      assert rows(ctx.tenant_id) == []
    end

    test "an oversized body is 413 and writes nothing", %{conn: conn} = ctx do
      raw = String.duplicate(" ", Ledger.max_body_bytes() + 1)

      assert %{"error" => %{"code" => "payload_too_large"}} =
               conn |> post_batch(ctx, raw) |> json_response(413)

      assert rows(ctx.tenant_id) == []
    end
  end

  describe "TC-50.1.4: an unknown kind is stored" do
    test "cache_sample with only the common fields", %{conn: conn} = ctx do
      raw =
        batch([
          %{
            "v" => 1,
            "kind" => "cache_sample",
            "repo" => "mkreyman/infra",
            "host" => "ryzen",
            "at_ms" => 1_763_400_000_000,
            "hits" => 9
          }
        ])

      assert %{"inserted" => 1} = conn |> post_batch(ctx, raw) |> json_response(200)

      assert [%LedgerRow{kind: "cache_sample", sha: nil, verdict: nil, raw: %{"hits" => 9}}] =
               rows(ctx.tenant_id)
    end
  end

  describe "AC-50.1.5: the operation spec" do
    test "documents the caps and the rejection reasons from the module attributes" do
      op = LoopctlWeb.ChgLedgerController.open_api_operation(:create)

      assert op.description =~ "#{Ledger.max_body_bytes()}"
      assert op.description =~ "#{Ledger.max_batch()}"
      assert op.description =~ "repo_mismatch"
      assert Map.has_key?(op.responses, 401)
      assert Map.has_key?(op.responses, 413)
    end
  end

  describe "AC-50.1.6 / TC-50.1.6: tenant isolation" do
    test "B's source cannot write A's repository and B lists none of A's rows",
         %{conn: conn} = ctx do
      other = fixture(:chg_source, %{repo_full_name: "mkreyman/other"})

      assert %{"inserted" => 1} =
               conn |> post_batch(ctx, batch([row("chg")])) |> json_response(200)

      # B's own secret, B's source, a row naming A's repository.
      assert %{"inserted" => 0, "rejected" => [%{"reason" => "repo_mismatch"}]} =
               build_conn()
               |> post_batch(ctx, batch([row("chg")]),
                 source_id: other.source.id,
                 secret: other.secret
               )
               |> json_response(200)

      # A's secret on B's source is the 401.
      assert build_conn()
             |> post_batch(ctx, batch([row("chg")]), source_id: other.source.id)
             |> json_response(401) == @unauthorized

      assert Ledger.list_rows(other.source.tenant_id) == []
      assert [%LedgerRow{}] = Ledger.list_rows(ctx.tenant_id)
    end
  end
end
