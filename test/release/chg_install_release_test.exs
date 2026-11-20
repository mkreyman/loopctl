defmodule Loopctl.Release.ChgInstallReleaseTest do
  @moduledoc """
  US-52.7: `chg/scripts/install.sh --release factory-<n>` installs the chg artifact of
  mkreyman/loopctl's factory release, and refuses one whose sha256 does not match.

  `gh` is a stub first on PATH that writes the two release assets it is asked for; no
  network. The artifact exists for Linux x86_64 only, which is where this runs.
  """
  use ExUnit.Case, async: true

  @install Path.expand("chg/scripts/install.sh")
  @linux_x86_64 match?({:unix, :linux}, :os.type()) and
                  String.starts_with?(
                    to_string(:erlang.system_info(:system_architecture)),
                    "x86_64"
                  )

  @moduletag skip: not @linux_x86_64 && "release artifacts are Linux x86_64 only"

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Path.join(Loopctl.RealTmpDir.path!(), "chg-install-#{suffix}")
    bin = Path.join(root, "bin")
    dest = Path.join(root, "dest")
    log = Path.join(root, "gh.log")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    write_exec!(Path.join(bin, "gh"), """
    #!/bin/bash
    echo "$*" >> "#{log}"
    dir=""; prev=""
    for a in "$@"; do [ "$prev" = -D ] && dir=$a; prev=$a; done
    printf '#!/bin/sh\\necho "chg 0.1.0 (adapter contract 1)"\\n' > "$dir/chg-x86_64-unknown-linux-musl"
    (cd "$dir" && shasum -a 256 chg-x86_64-unknown-linux-musl > chg-x86_64-unknown-linux-musl.sha256)
    [ -z "${FAKE_TAMPER:-}" ] || echo tampered >> "$dir/chg-x86_64-unknown-linux-musl"
    """)

    %{bin: bin, dest: dest, log: log}
  end

  test "downloads factory-<n>'s artifact from mkreyman/loopctl and installs it", ctx do
    {out, status} = install(ctx, ["--release", "factory-1"])

    assert status == 0, out
    assert out =~ "installed: #{ctx.dest}/chg (chg 0.1.0"

    assert File.read!(ctx.log) ==
             "release download factory-1 -R mkreyman/loopctl -D " <>
               "#{download_dir(ctx)} -p chg-x86_64-unknown-linux-musl " <>
               "-p chg-x86_64-unknown-linux-musl.sha256\n"
  end

  test "refuses an artifact whose sha256 does not match, and installs nothing", ctx do
    {out, status} = install(ctx, ["--release", "factory-1"], [{"FAKE_TAMPER", "1"}])

    assert status == 1
    assert out =~ "does not match its .sha256; nothing installed"
    refute File.exists?(Path.join(ctx.dest, "chg"))
  end

  test "refuses a tag that is not a factory release", ctx do
    {out, status} = install(ctx, ["--release", "v0.1.0"])

    assert status == 2
    assert out =~ "factory release tag (factory-<n>)"
    refute File.exists?(ctx.log)
  end

  defp install(ctx, args, env \\ []) do
    System.cmd("bash", [@install, "--dest", ctx.dest, "--no-elixir-adapter" | args],
      env: [{"PATH", ctx.bin <> ":" <> System.get_env("PATH", "")} | env],
      stderr_to_stdout: true
    )
  end

  # install.sh downloads into a fresh mktemp -d; the log names it.
  defp download_dir(ctx) do
    [_, dir] = Regex.run(~r/-D (\S+)/, File.read!(ctx.log))
    dir
  end

  defp write_exec!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end
end
