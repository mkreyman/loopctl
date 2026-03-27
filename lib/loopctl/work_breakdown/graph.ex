defmodule Loopctl.WorkBreakdown.Graph do
  @moduledoc """
  Graph utilities for dependency cycle detection.

  Provides a reusable DFS-based cycle detection algorithm used by both
  epic dependencies and story dependencies.
  """

  @doc """
  Checks if adding an edge from `from_id` to `to_id` would create a cycle
  in the directed graph defined by `edges`.

  The edge represents: `from_id` depends on `to_id`.
  A cycle exists if `from_id` is reachable from `to_id` by following
  existing edges.

  ## Parameters

  - `edges` -- list of `{source, target}` tuples representing existing edges
               where source depends on target
  - `from_id` -- the node that will depend on `to_id`
  - `to_id` -- the node that `from_id` will depend on

  ## Returns

  - `true` if the new edge would create a cycle
  - `false` if the edge is safe to add
  """
  @spec would_create_cycle?([{binary(), binary()}], binary(), binary()) :: boolean()
  def would_create_cycle?(edges, from_id, to_id) do
    # Self-loop is always a cycle
    if from_id == to_id do
      true
    else
      # Build adjacency list: for each node, what nodes does it depend on?
      # Edge (A, B) means A depends on B, so following B's dependencies
      # we look for edges where epic_id == B, to find what B depends on.
      adjacency = build_adjacency_list(edges)

      # We need to check: is from_id reachable from to_id?
      # If to_id depends on X, and X depends on from_id (directly or transitively),
      # then adding from_id -> to_id creates a cycle.
      reachable?(adjacency, to_id, from_id, MapSet.new())
    end
  end

  # Build adjacency list: node -> set of nodes it depends on
  defp build_adjacency_list(edges) do
    Enum.reduce(edges, %{}, fn {source, target}, acc ->
      Map.update(acc, source, MapSet.new([target]), &MapSet.put(&1, target))
    end)
  end

  # DFS: can we reach `target` from `current` by following dependency edges?
  defp reachable?(_adjacency, current, target, _visited) when current == target, do: true

  defp reachable?(adjacency, current, target, visited) do
    if MapSet.member?(visited, current) do
      false
    else
      visited = MapSet.put(visited, current)
      neighbors = Map.get(adjacency, current, MapSet.new())

      Enum.any?(neighbors, fn neighbor ->
        reachable?(adjacency, neighbor, target, visited)
      end)
    end
  end
end
