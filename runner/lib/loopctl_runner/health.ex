defmodule LoopctlRunner.Health do
  @moduledoc """
  Self-measured facts about this machine, for the join payload and `status` samples.

  "Connected" is not "able to build" (design §7): a wedged machine answers heartbeats
  while it thrashes, so the control plane treats a stale sample as a breached threshold.
  A sample therefore carries its own `sampled_at`, and a metric this module cannot read
  makes the whole sample `nil` rather than inventing a healthy-looking zero.

  Linux reads `/proc`; macOS reads `sysctl` and `vm_stat`. Free disk is measured on the
  filesystem that holds the worktrees and runs, which is what fills up.
  """

  @type sample :: %{required(String.t()) => term()}

  @doc "Logical cores and total memory in MB, or an error naming what could not be read."
  @spec capacity() :: {:ok, %{String.t() => pos_integer()}} | {:error, String.t()}
  def capacity do
    with {:ok, memory_mb} <- total_memory_mb() do
      {:ok,
       %{
         "cores" => :erlang.system_info(:logical_processors_available) |> cores(),
         "memory_mb" => memory_mb
       }}
    end
  end

  defp cores(:unknown), do: System.schedulers_online()
  defp cores(n), do: n

  @doc "A health sample for the filesystem holding `path`, or nil when any metric is unreadable."
  @spec sample(String.t(), String.t() | nil) :: sample() | nil
  def sample(path, last_build_at) do
    with {:ok, load} <- loadavg_1m(),
         {:ok, free_ram} <- free_ram_mb(),
         {:ok, free_disk} <- free_disk_mb(path) do
      %{
        "sampled_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "loadavg_1m" => load,
        "free_ram_mb" => free_ram,
        "free_disk_mb" => free_disk,
        "last_build_at" => last_build_at
      }
    else
      _ -> nil
    end
  end

  defp darwin?, do: :os.type() == {:unix, :darwin}

  defp loadavg_1m do
    if darwin?() do
      # "{ 1.23 1.10 1.05 }"
      with {:ok, out} <- cmd("sysctl", ["-n", "vm.loadavg"]),
           [_, one | _] <- String.split(out),
           {load, _} <- Float.parse(one) do
        {:ok, load}
      else
        _ -> :error
      end
    else
      with {:ok, raw} <- File.read("/proc/loadavg"),
           [one | _] <- String.split(raw),
           {load, _} <- Float.parse(one) do
        {:ok, load}
      else
        _ -> :error
      end
    end
  end

  defp total_memory_mb do
    if darwin?() do
      with {:ok, out} <- cmd("sysctl", ["-n", "hw.memsize"]),
           {bytes, _} <- Integer.parse(out) do
        {:ok, div(bytes, 1_048_576)}
      else
        _ -> {:error, "cannot read hw.memsize"}
      end
    else
      case meminfo_kb("MemTotal") do
        {:ok, kb} -> {:ok, div(kb, 1024)}
        :error -> {:error, "cannot read MemTotal from /proc/meminfo"}
      end
    end
  end

  defp free_ram_mb do
    if darwin?(), do: darwin_free_ram_mb(), else: linux_free_ram_mb()
  end

  defp linux_free_ram_mb do
    case meminfo_kb("MemAvailable") do
      {:ok, kb} -> {:ok, div(kb, 1024)}
      :error -> :error
    end
  end

  # macOS has no MemAvailable; free + inactive + purgeable pages is the closest match.
  defp darwin_free_ram_mb do
    with {:ok, out} <- cmd("vm_stat", []),
         [_, page] <- Regex.run(~r/page size of (\d+) bytes/, out) do
      pages = ~w(free inactive purgeable) |> Enum.map(&vm_stat_pages(out, &1)) |> Enum.sum()

      {:ok, div(pages * String.to_integer(page), 1_048_576)}
    else
      _ -> :error
    end
  end

  defp vm_stat_pages(out, name) do
    case Regex.run(~r/Pages #{name}:\s+(\d+)/, out) do
      [_, n] -> String.to_integer(n)
      nil -> 0
    end
  end

  defp meminfo_kb(key) do
    with {:ok, raw} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/^#{key}:\s+(\d+) kB/m, raw) do
      {:ok, String.to_integer(kb)}
    else
      _ -> :error
    end
  end

  defp free_disk_mb(path) do
    # POSIX `df -Pk`: header, then "fs 1024-blocks used available capacity mount".
    with {:ok, out} <- cmd("df", ["-Pk", existing_ancestor(path)]),
         [_header, row | _] <- String.split(out, "\n", trim: true),
         [_fs, _size, _used, avail | _] <- String.split(row),
         {kb, ""} <- Integer.parse(avail) do
      {:ok, div(kb, 1024)}
    else
      _ -> :error
    end
  end

  defp existing_ancestor(path) do
    if File.exists?(path) or path in ["/", "."],
      do: path,
      else: existing_ancestor(Path.dirname(path))
  end

  defp cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end
end
