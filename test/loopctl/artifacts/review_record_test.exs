defmodule Loopctl.Artifacts.ReviewRecordTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Artifacts.ReviewRecord

  describe "create_changeset/2 completed_at future validation" do
    test "accepts completed_at at the current time" do
      changeset =
        ReviewRecord.create_changeset(%ReviewRecord{}, %{
          review_type: "enhanced",
          completed_at: DateTime.utc_now()
        })

      assert changeset.valid?
      refute Map.has_key?(errors_on(changeset), :completed_at)
    end

    test "accepts completed_at slightly in the future (within the 60-second skew tolerance)" do
      near_future = DateTime.add(DateTime.utc_now(), 30, :second)

      changeset =
        ReviewRecord.create_changeset(%ReviewRecord{}, %{
          review_type: "enhanced",
          completed_at: near_future
        })

      assert changeset.valid?
      refute Map.has_key?(errors_on(changeset), :completed_at)
    end

    test "rejects a far-future completed_at" do
      far_future = DateTime.add(DateTime.utc_now(), 3600, :second)

      changeset =
        ReviewRecord.create_changeset(%ReviewRecord{}, %{
          review_type: "enhanced",
          completed_at: far_future
        })

      refute changeset.valid?
      assert %{completed_at: [message]} = errors_on(changeset)
      assert message =~ "future"
    end

    test "rejects a completed_at just past the 60-second skew tolerance" do
      just_past_tolerance = DateTime.add(DateTime.utc_now(), 90, :second)

      changeset =
        ReviewRecord.create_changeset(%ReviewRecord{}, %{
          review_type: "enhanced",
          completed_at: just_past_tolerance
        })

      refute changeset.valid?
      assert %{completed_at: [message]} = errors_on(changeset)
      assert message =~ "future"
    end
  end
end
