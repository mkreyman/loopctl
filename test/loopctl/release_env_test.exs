defmodule Loopctl.ReleaseEnvTest do
  @moduledoc """
  `rel/env.sh.eex` names the release node and picks its distribution protocol. On Fly the
  two machines can only form a cluster when the node is named after its 6PN address and
  distribution runs over IPv6; off Fly it must stay exactly as it was. The file is plain
  shell (no EEx tags), so it is sourced here as the release sources it.
  """

  use ExUnit.Case, async: true

  @fly_ip "fdaa:0:1:a7b:2b8:36e4:711e:2"

  # Sources the file with `env` layered over a cleared set of the variables it reads, and
  # returns what it exported.
  defp render(env) do
    base = [
      {"RELEASE_NAME", "loopctl"},
      {"FLY_PRIVATE_IP", nil},
      {"FLY_IMAGE_REF", nil},
      {"ERL_AFLAGS", nil},
      {"RELEASE_NODE", nil}
    ]

    script =
      ~S(. ./rel/env.sh.eex; printf '%s\n%s\n%s\n' "$RELEASE_NODE" "$ERL_AFLAGS" "$RELEASE_DISTRIBUTION")

    {out, 0} = System.cmd("sh", ["-c", script], env: base ++ env)
    [node, aflags, distribution] = String.split(out, "\n", trim: false) |> Enum.take(3)
    %{node: node, aflags: aflags, distribution: distribution}
  end

  test "off Fly the node stays on 127.0.0.1 and distribution is not switched to IPv6" do
    assert render([]) == %{node: "loopctl@127.0.0.1", aflags: "", distribution: "name"}
  end

  test "on Fly the node is named after the machine's 6PN address, with IPv6 distribution" do
    rendered =
      render([
        {"FLY_PRIVATE_IP", @fly_ip},
        {"FLY_IMAGE_REF", "registry.fly.io/loopctl:deployment-01K4ZQXYZ123ABC"}
      ])

    assert rendered.node == "loopctl-01K4ZQXYZ123ABC@#{@fly_ip}"
    assert rendered.aflags == "-proto_dist inet6_tcp"
    assert rendered.distribution == "name"
  end

  test "an ERL_AFLAGS already in the environment is kept after the IPv6 flag" do
    rendered =
      render([{"FLY_PRIVATE_IP", @fly_ip}, {"ERL_AFLAGS", "-kernel shell_history enabled"}])

    assert rendered.aflags == "-proto_dist inet6_tcp -kernel shell_history enabled"
  end

  test "machines of one image share a DNSCluster basename; two images do not" do
    ref = "registry.fly.io/loopctl:deployment-01K4ZQXYZ123ABC"
    other = "registry.fly.io/loopctl:deployment-01K5AAAAAAAAAAA"

    a = render([{"FLY_PRIVATE_IP", @fly_ip}, {"FLY_IMAGE_REF", ref}]).node
    b = render([{"FLY_PRIVATE_IP", "fdaa:0:1:a7b:2ba:b95f:8c10:2"}, {"FLY_IMAGE_REF", ref}]).node

    c =
      render([{"FLY_PRIVATE_IP", "fdaa:0:1:a7b:2ba:b95f:8c10:2"}, {"FLY_IMAGE_REF", other}]).node

    basename = &DNSCluster.Resolver.basename(String.to_atom(&1))
    assert basename.(a) == basename.(b)
    refute basename.(a) == basename.(c)
  end

  test "an image reference without a deployment suffix still yields a legal node name" do
    rendered =
      render([{"FLY_PRIVATE_IP", @fly_ip}, {"FLY_IMAGE_REF", "registry.fly.io/loopctl:latest"}])

    [basename, host] = String.split(rendered.node, "@")
    assert basename =~ ~r/\Aloopctl-[A-Za-z0-9_]+\z/
    assert host == @fly_ip
  end
end
