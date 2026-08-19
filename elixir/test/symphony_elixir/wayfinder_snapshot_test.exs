defmodule SymphonyElixir.WayfinderSnapshotTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{GroupReporter, WayfinderSnapshot}
  alias SymphonyElixir.Linear.Wayfinder

  test "fetches every wayfinder page and projects maps, tickets, dependencies, and resolution evidence" do
    tracker = %Schema.Tracker{kind: "linear", project_slug: "portfolio-ops"}

    graphql_fun = fn query, variables ->
      assert query =~ ~s(filter: {body: {contains: "## Resolution"}})
      assert query =~ "orderBy: updatedAt"
      send(self(), {:graphql, variables})

      case variables[:after] do
        nil ->
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [map_issue(), completed_edge_issue()],
                 "pageInfo" => %{"hasNextPage" => true, "endCursor" => "next-page"}
               }
             }
           }}

        "next-page" ->
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [waiting_edge_issue()],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }}
      end
    end

    assert {:ok, snapshot} = Wayfinder.fetch(tracker, graphql_fun: graphql_fun, now: ~U[2026-08-19 03:00:00Z])

    assert_received {:graphql, %{projectSlug: "portfolio-ops", first: 50, after: nil}}
    assert_received {:graphql, %{projectSlug: "portfolio-ops", first: 50, after: "next-page"}}

    assert %{
             status: "available",
             generated_at: "2026-08-19T03:00:00Z",
             orphaned_count: 0,
             maps: [%{id: "map-1", identifier: "OPS-100", ticket_ids: ["edge-1", "edge-2"]}],
             tickets: tickets,
             dependencies: [
               %{
                 from: %{id: "edge-1", identifier: "OPS-101"},
                 to: %{id: "edge-2", identifier: "OPS-102"},
                 kind: "blocks",
                 external: false
               }
             ]
           } = snapshot

    assert [completed, waiting] = tickets
    assert completed.wayfinder_type == "edge"
    assert completed.completion == %{completed: true, completed_at: "2026-08-18T18:00:00Z"}
    assert completed.resolution.excerpt == "Shipped the canonical map renderer."
    assert completed.resolution.comment_id == "comment-new"
    assert completed.artifacts == [%{id: "doc-1", title: "Renderer notes", url: "https://linear.app/doc/renderer"}]
    assert waiting.completion == %{completed: false, completed_at: nil}
  end

  test "counts child tickets whose parent is not a fetched wayfinder map" do
    tracker = %Schema.Tracker{kind: "linear", project_slug: "portfolio-ops"}

    graphql_fun = fn _query, _variables ->
      orphan = put_in(waiting_edge_issue(), ["parent"], %{"id" => "missing", "identifier" => "OPS-1"})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [orphan],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, %{maps: [], tickets: [], orphaned_count: 1}} =
             Wayfinder.fetch(tracker, graphql_fun: graphql_fun)
  end

  test "marks a blocking relation to another map as inspector-only" do
    tracker = %Schema.Tracker{kind: "linear", project_slug: "portfolio-ops"}

    second_map =
      map_issue()
      |> Map.merge(%{"id" => "map-2", "identifier" => "OPS-200", "title" => "Second map"})

    second_ticket =
      waiting_edge_issue()
      |> Map.merge(%{"id" => "edge-3", "identifier" => "OPS-201", "title" => "Other map edge"})
      |> put_in(["parent"], %{"id" => "map-2", "identifier" => "OPS-200"})

    first_ticket =
      completed_edge_issue()
      |> put_in(
        ["relations", "nodes"],
        [
          %{
            "type" => "blocks",
            "relatedIssue" => issue_ref("edge-3", "OPS-201", "Other map edge", "started")
          }
        ]
      )

    graphql_fun = fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [map_issue(), first_ticket, second_map, second_ticket],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, %{dependencies: [%{from: %{id: "edge-1"}, to: %{id: "edge-3"}, external: true}]}} =
             Wayfinder.fetch(tracker, graphql_fun: graphql_fun)
  end

  test "refresh replaces a previously available snapshot with unavailable data after failure" do
    test_pid = self()
    tracker = %Schema.Tracker{kind: "linear", project_slug: "portfolio-ops"}
    settings = %Schema{tracker: tracker, polling: %Schema.Polling{interval_ms: 60_000}}

    fetch_fun = fn _tracker ->
      send(test_pid, :fetched)

      case Process.get(:fetch_count, 0) do
        0 ->
          Process.put(:fetch_count, 1)
          {:ok, %{status: "available", generated_at: "first", maps: [%{id: "map-1"}], tickets: []}}

        _ ->
          {:error, :linear_down}
      end
    end

    {:ok, server} =
      start_supervised({WayfinderSnapshot, name: nil, settings_fun: fn -> {:ok, settings} end, fetch_fun: fetch_fun})

    assert_receive :fetched
    assert_eventually(fn -> WayfinderSnapshot.snapshot(server).status == "available" end)

    WayfinderSnapshot.refresh(server)
    assert_receive :fetched

    assert_eventually(fn ->
      assert %{
               status: "unavailable",
               maps: [],
               tickets: [],
               dependencies: [],
               orphaned_count: 0,
               error: %{code: "wayfinder_unavailable"}
             } = WayfinderSnapshot.snapshot(server)
    end)
  end

  test "non-Linear workflows report wayfinder as unsupported" do
    settings = %Schema{
      tracker: %Schema.Tracker{kind: "github"},
      polling: %Schema.Polling{interval_ms: 60_000}
    }

    {:ok, server} =
      start_supervised({WayfinderSnapshot, name: nil, settings_fun: fn -> {:ok, settings} end})

    assert_eventually(fn -> WayfinderSnapshot.snapshot(server).status == "unsupported" end)
  end

  test "group payload adds the child-owned wayfinder snapshot without changing runtime fields" do
    runtime = %{counts: %{running: 0}, generated_at: "runtime-time", running: []}

    wayfinder = %{
      status: "available",
      generated_at: "wayfinder-time",
      maps: [%{id: "map-1", identifier: "OPS-100"}],
      tickets: [
        %{
          id: "edge-1",
          identifier: "OPS-101",
          wayfinder_type: "edge",
          resolution: %{excerpt: "Done"}
        }
      ],
      dependencies: [%{kind: "blocks", from: %{id: "edge-1"}, to: %{id: "edge-2"}}]
    }

    assert %{counts: %{running: 0}, generated_at: "runtime-time", wayfinder: ^wayfinder} =
             GroupReporter.decorate_payload(runtime, wayfinder)

    encoded = GroupReporter.encode_snapshot(GroupReporter.decorate_payload(runtime, wayfinder))

    assert {:ok,
            %{
              wayfinder: %{
                status: "available",
                maps: [%{id: "map-1", identifier: "OPS-100"}],
                tickets: [
                  %{
                    id: "edge-1",
                    identifier: "OPS-101",
                    wayfinder_type: "edge",
                    resolution: %{excerpt: "Done"}
                  }
                ],
                dependencies: [%{kind: "blocks", from: %{id: "edge-1"}, to: %{id: "edge-2"}}]
              }
            }} = GroupReporter.decode_snapshot(encoded)
  end

  defp map_issue do
    %{
      "id" => "map-1",
      "identifier" => "OPS-100",
      "title" => "Portfolio wayfinder",
      "url" => "https://linear.app/issue/OPS-100",
      "state" => %{"name" => "In Progress", "type" => "started"},
      "labels" => %{"nodes" => [%{"name" => "wayfinder:map"}]},
      "parent" => nil,
      "relations" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []},
      "comments" => %{"nodes" => []},
      "documents" => %{"nodes" => []},
      "completedAt" => nil,
      "createdAt" => "2026-08-18T10:00:00Z",
      "updatedAt" => "2026-08-18T20:00:00Z"
    }
  end

  defp completed_edge_issue do
    %{
      "id" => "edge-1",
      "identifier" => "OPS-101",
      "title" => "Render dependency edges",
      "url" => "https://linear.app/issue/OPS-101",
      "state" => %{"name" => "Done", "type" => "completed"},
      "labels" => %{"nodes" => [%{"name" => "wayfinder:edge"}]},
      "parent" => %{"id" => "map-1", "identifier" => "OPS-100"},
      "relations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "relatedIssue" => issue_ref("edge-2", "OPS-102", "Build map graph", "started")
          }
        ]
      },
      "inverseRelations" => %{"nodes" => []},
      "comments" => %{
        "nodes" => [
          %{
            "id" => "comment-old",
            "body" => "## Resolution\nOld notes.",
            "updatedAt" => "2026-08-18T17:00:00Z"
          },
          %{
            "id" => "comment-new",
            "body" => "Preface\n\n## Resolution\nShipped the canonical map renderer.\n\n## Follow-up\nNone.",
            "updatedAt" => "2026-08-18T19:00:00Z"
          }
        ]
      },
      "documents" => %{
        "nodes" => [
          %{"id" => "doc-1", "title" => "Renderer notes", "url" => "https://linear.app/doc/renderer"}
        ]
      },
      "completedAt" => "2026-08-18T18:00:00Z",
      "createdAt" => "2026-08-18T11:00:00Z",
      "updatedAt" => "2026-08-18T19:00:00Z"
    }
  end

  defp waiting_edge_issue do
    %{
      "id" => "edge-2",
      "identifier" => "OPS-102",
      "title" => "Build map graph",
      "url" => "https://linear.app/issue/OPS-102",
      "state" => %{"name" => "In Progress", "type" => "started"},
      "labels" => %{"nodes" => [%{"name" => "wayfinder:edge"}]},
      "parent" => %{"id" => "map-1", "identifier" => "OPS-100"},
      "relations" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []},
      "comments" => %{"nodes" => []},
      "documents" => %{"nodes" => []},
      "completedAt" => nil,
      "createdAt" => "2026-08-18T12:00:00Z",
      "updatedAt" => "2026-08-18T20:00:00Z"
    }
  end

  defp issue_ref(id, identifier, title, state_type) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => title,
      "state" => %{"name" => String.capitalize(state_type), "type" => state_type},
      "url" => "https://linear.app/issue/#{identifier}"
    }
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end

defmodule SymphonyElixir.WayfinderGraphTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WayfinderGraph

  test "lays out a dependency graph deterministically from left to right" do
    tickets = [ticket("a", "OPS-1"), ticket("b", "OPS-2"), ticket("c", "OPS-3")]

    dependencies = [
      dependency("a", "OPS-1", "b", "OPS-2"),
      dependency("b", "OPS-2", "c", "OPS-3")
    ]

    assert %{
             nodes: [
               %{ticket: %{id: "a"}, level: 0, x: 40},
               %{ticket: %{id: "b"}, level: 1, x: 300},
               %{ticket: %{id: "c"}, level: 2, x: 560}
             ],
             edges: [%{from_id: "a", to_id: "b"}, %{from_id: "b", to_id: "c"}],
             repair_tickets: [],
             width: 820
           } = WayfinderGraph.layout(tickets, dependencies)
  end

  test "isolates cyclic tickets in the relation-repair lane" do
    tickets = [ticket("a", "OPS-1"), ticket("b", "OPS-2"), ticket("c", "OPS-3")]

    dependencies = [
      dependency("a", "OPS-1", "b", "OPS-2"),
      dependency("b", "OPS-2", "a", "OPS-1")
    ]

    assert %{
             nodes: [%{ticket: %{id: "c"}}],
             edges: [],
             repair_tickets: [%{id: "a"}, %{id: "b"}]
           } = WayfinderGraph.layout(tickets, dependencies)
  end

  test "returns a stable empty canvas size" do
    assert %{nodes: [], edges: [], repair_tickets: [], width: 300, height: 168} =
             WayfinderGraph.layout([], [])
  end

  defp ticket(id, identifier), do: %{id: id, identifier: identifier, title: identifier}

  defp dependency(from_id, from_identifier, to_id, to_identifier) do
    %{
      from: %{id: from_id, identifier: from_identifier},
      to: %{id: to_id, identifier: to_identifier},
      kind: "blocks",
      external: false
    }
  end
end
