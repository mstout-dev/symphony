defmodule SymphonyElixir.WayfinderGraph do
  @moduledoc """
  Deterministic layout for the server-rendered Wayfinder dependency graph.

  Cyclic relations are isolated from the DAG so one malformed chain cannot make
  the rest of a map unreadable.
  """

  @horizontal_gap 260
  @vertical_gap 128
  @left 40
  @top 40
  @node_width 220
  @node_height 88

  @spec layout([map()], [map()]) :: map()
  def layout(tickets, dependencies) when is_list(tickets) and is_list(dependencies) do
    tickets_by_id = Map.new(tickets, &{&1.id, &1})
    ids = Map.keys(tickets_by_id) |> MapSet.new()
    graph_edges = internal_edges(dependencies, ids)
    adjacency = adjacency(ids, graph_edges)

    repair_ids =
      ids
      |> Enum.filter(&cyclic?(&1, adjacency))
      |> MapSet.new()

    valid_ids = MapSet.difference(ids, repair_ids)

    valid_edges =
      Enum.filter(graph_edges, fn {from_id, to_id} ->
        MapSet.member?(valid_ids, from_id) and MapSet.member?(valid_ids, to_id)
      end)

    levels = dependency_levels(valid_ids, valid_edges)
    nodes = positioned_nodes(tickets_by_id, valid_ids, levels)
    nodes_by_id = Map.new(nodes, &{&1.ticket.id, &1})

    %{
      nodes: nodes,
      edges: positioned_edges(valid_edges, nodes_by_id),
      repair_tickets:
        repair_ids
        |> Enum.map(&Map.fetch!(tickets_by_id, &1))
        |> Enum.sort_by(&ticket_sort_key/1),
      width: graph_width(nodes),
      height: graph_height(nodes)
    }
  end

  defp internal_edges(dependencies, ids) do
    dependencies
    |> Enum.reject(&Map.get(&1, :external, false))
    |> Enum.map(&{get_in(&1, [:from, :id]), get_in(&1, [:to, :id])})
    |> Enum.filter(fn {from_id, to_id} ->
      MapSet.member?(ids, from_id) and MapSet.member?(ids, to_id)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp adjacency(ids, edges) do
    base = Map.new(ids, &{&1, []})

    edges
    |> Enum.reduce(base, fn {from_id, to_id}, graph ->
      Map.update!(graph, from_id, &[to_id | &1])
    end)
    |> Map.new(fn {id, outgoing} -> {id, Enum.sort(outgoing)} end)
  end

  defp cyclic?(id, adjacency) do
    adjacency
    |> Map.get(id, [])
    |> Enum.any?(fn next_id -> next_id == id or reachable?(next_id, id, adjacency, MapSet.new([id])) end)
  end

  defp reachable?(current_id, target_id, _adjacency, _visited) when current_id == target_id,
    do: true

  defp reachable?(current_id, target_id, adjacency, visited) do
    if MapSet.member?(visited, current_id) do
      false
    else
      visited = MapSet.put(visited, current_id)

      adjacency
      |> Map.get(current_id, [])
      |> Enum.any?(&reachable?(&1, target_id, adjacency, visited))
    end
  end

  defp dependency_levels(ids, edges) do
    indegree = Map.new(ids, &{&1, 0})

    indegree =
      Enum.reduce(edges, indegree, fn {_from_id, to_id}, acc ->
        Map.update!(acc, to_id, &(&1 + 1))
      end)

    outgoing = adjacency(ids, edges)
    queue = indegree |> Enum.filter(fn {_id, degree} -> degree == 0 end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    walk_levels(queue, indegree, outgoing, Map.new(ids, &{&1, 0}))
  end

  defp walk_levels([], _indegree, _outgoing, levels), do: levels

  defp walk_levels([id | rest], indegree, outgoing, levels) do
    {indegree, levels, newly_ready} =
      outgoing
      |> Map.get(id, [])
      |> Enum.reduce({indegree, levels, []}, fn to_id, {degrees, current_levels, ready} ->
        degrees = Map.update!(degrees, to_id, &(&1 - 1))
        current_levels = Map.update!(current_levels, to_id, &max(&1, Map.fetch!(current_levels, id) + 1))
        ready = if Map.fetch!(degrees, to_id) == 0, do: [to_id | ready], else: ready
        {degrees, current_levels, ready}
      end)

    walk_levels(Enum.sort(rest ++ newly_ready), indegree, outgoing, levels)
  end

  defp positioned_nodes(tickets_by_id, valid_ids, levels) do
    valid_ids
    |> Enum.map(&Map.fetch!(tickets_by_id, &1))
    |> Enum.sort_by(&{Map.fetch!(levels, &1.id), ticket_sort_key(&1)})
    |> Enum.group_by(&Map.fetch!(levels, &1.id))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {level, tickets} ->
      tickets
      |> Enum.sort_by(&ticket_sort_key/1)
      |> Enum.with_index()
      |> Enum.map(fn {ticket, index} ->
        %{
          ticket: ticket,
          level: level,
          x: @left + level * @horizontal_gap,
          y: @top + index * @vertical_gap
        }
      end)
    end)
  end

  defp positioned_edges(edges, nodes_by_id) do
    Enum.map(edges, fn {from_id, to_id} ->
      from = Map.fetch!(nodes_by_id, from_id)
      to = Map.fetch!(nodes_by_id, to_id)
      from_x = from.x + @node_width
      from_y = from.y + div(@node_height, 2)
      to_x = to.x
      to_y = to.y + div(@node_height, 2)
      bend = max(div(to_x - from_x, 2), 24)

      %{
        from_id: from_id,
        to_id: to_id,
        path: "M #{from_x} #{from_y} C #{from_x + bend} #{from_y}, #{to_x - bend} #{to_y}, #{to_x} #{to_y}"
      }
    end)
  end

  defp graph_width([]), do: @node_width + @left * 2
  defp graph_width(nodes), do: Enum.max_by(nodes, & &1.x).x + @node_width + @left

  defp graph_height([]), do: @node_height + @top * 2
  defp graph_height(nodes), do: max(Enum.max_by(nodes, & &1.y).y + @node_height + @top, 220)

  defp ticket_sort_key(ticket), do: {ticket.identifier || "", ticket.id || ""}
end
