defmodule SymphonyElixir.Linear.Wayfinder do
  @moduledoc """
  Builds a read-only Wayfinder snapshot from project-scoped Linear issues.

  The module owns the provider query and returns a small, deterministic data
  contract. Raw issue descriptions and comments never leave this boundary.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Client

  @page_size 50
  @relation_page_size 50
  @evidence_page_size 20
  @resolution_limit 600

  @query """
  query SymphonyLinearWayfinder($projectSlug: String!, $first: Int!, $relationFirst: Int!, $evidenceFirst: Int!, $after: String) {
    issues(
      filter: {
        project: {slugId: {eq: $projectSlug}}
        labels: {name: {startsWith: "wayfinder:"}}
      }
      first: $first
      after: $after
    ) {
      nodes {
        id
        identifier
        title
        url
        state { name type }
        labels { nodes { name } }
        parent { id identifier }
        relations(first: $relationFirst) {
          nodes {
            type
            relatedIssue { id identifier title url state { name type } }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue { id identifier title url state { name type } }
          }
        }
        comments(
          filter: {body: {contains: "## Resolution"}}
          first: $evidenceFirst
          orderBy: updatedAt
        ) { nodes { id body updatedAt } }
        documents(first: $evidenceFirst) { nodes { id title url } }
        completedAt
        createdAt
        updatedAt
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @spec fetch(Schema.Tracker.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(%Schema.Tracker{} = tracker, opts \\ []) when is_list(opts) do
    case tracker.project_slug do
      project_slug when is_binary(project_slug) ->
        graphql_fun =
          Keyword.get(opts, :graphql_fun, fn query, variables ->
            Client.graphql(query, variables, tracker_settings: tracker)
          end)

        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

        with {:ok, issues} <- fetch_pages(project_slug, graphql_fun, nil, []) do
          {:ok, project_snapshot(issues, now)}
        end

      _missing_slug ->
        {:error, :missing_linear_project_slug}
    end
  end

  defp fetch_pages(project_slug, graphql_fun, after_cursor, acc) do
    variables = %{
      projectSlug: project_slug,
      first: @page_size,
      relationFirst: @relation_page_size,
      evidenceFirst: @evidence_page_size,
      after: after_cursor
    }

    with {:ok, body} <- graphql_fun.(@query, variables),
         {:ok, nodes, page_info} <- decode_page(body) do
      updated = acc ++ nodes

      case page_info do
        %{"hasNextPage" => true, "endCursor" => cursor} when is_binary(cursor) ->
          fetch_pages(project_slug, graphql_fun, cursor, updated)

        %{"hasNextPage" => false} ->
          {:ok, updated}

        _ ->
          {:error, :invalid_wayfinder_page_info}
      end
    end
  end

  defp decode_page(%{"errors" => errors}) when is_list(errors) and errors != [],
    do: {:error, {:linear_graphql_errors, errors}}

  defp decode_page(%{
         "data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}
       })
       when is_list(nodes) and is_map(page_info),
       do: {:ok, nodes, page_info}

  defp decode_page(_body), do: {:error, :invalid_wayfinder_response}

  defp project_snapshot(issues, now) do
    map_issues = issues |> Enum.filter(&map_issue?/1) |> Map.new(&{&1["id"], &1})

    {child_issues, orphaned_count} =
      issues
      |> Enum.reject(&map_issue?/1)
      |> Enum.reduce({[], 0}, fn issue, {children, orphaned} ->
        parent_id = get_in(issue, ["parent", "id"])

        if is_binary(parent_id) and Map.has_key?(map_issues, parent_id) do
          {[issue | children], orphaned}
        else
          {children, orphaned + 1}
        end
      end)

    child_issues = Enum.sort_by(child_issues, &issue_sort_key/1)
    tickets = Enum.map(child_issues, &ticket_payload/1)
    ticket_map_ids = Map.new(tickets, &{&1.id, &1.map_id})

    %{
      status: "available",
      generated_at: now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      orphaned_count: orphaned_count,
      maps: map_payloads(map_issues, child_issues),
      tickets: tickets,
      dependencies: dependency_payloads(child_issues, ticket_map_ids)
    }
  end

  defp map_payloads(map_issues, child_issues) do
    ticket_ids_by_parent = Enum.group_by(child_issues, &get_in(&1, ["parent", "id"]), & &1["id"])

    map_issues
    |> Map.values()
    |> Enum.sort_by(&issue_sort_key/1)
    |> Enum.map(fn issue ->
      issue
      |> common_issue_payload()
      |> Map.put(:ticket_ids, Map.get(ticket_ids_by_parent, issue["id"], []))
      |> Map.put(:completion, completion_payload(issue))
    end)
  end

  defp ticket_payload(issue) do
    issue
    |> common_issue_payload()
    |> Map.merge(%{
      map_id: get_in(issue, ["parent", "id"]),
      wayfinder_type: wayfinder_type(issue),
      completion: completion_payload(issue),
      resolution: resolution_payload(issue),
      artifacts: artifact_payloads(issue)
    })
  end

  defp common_issue_payload(issue) do
    %{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      url: issue["url"],
      state: state_payload(issue["state"]),
      created_at: issue["createdAt"],
      updated_at: issue["updatedAt"]
    }
  end

  defp state_payload(%{"name" => name, "type" => type}), do: %{name: name, type: type}
  defp state_payload(_state), do: %{name: "Unknown", type: "unknown"}

  defp completion_payload(issue) do
    completed_at = issue["completedAt"]
    %{completed: is_binary(completed_at), completed_at: completed_at}
  end

  defp artifact_payloads(issue) do
    issue
    |> get_in(["documents", "nodes"])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.take(&1, ["id", "title", "url"]))
    |> Enum.map(fn artifact ->
      %{id: artifact["id"], title: artifact["title"], url: artifact["url"]}
    end)
    |> Enum.sort_by(&{&1.title || "", &1.id || ""})
  end

  defp resolution_payload(issue) do
    issue
    |> get_in(["comments", "nodes"])
    |> List.wrap()
    |> Enum.filter(&resolution_comment?/1)
    |> Enum.max_by(&(&1["updatedAt"] || ""), fn -> nil end)
    |> case do
      nil ->
        nil

      comment ->
        %{
          comment_id: comment["id"],
          updated_at: comment["updatedAt"],
          excerpt: resolution_excerpt(comment["body"])
        }
    end
  end

  defp resolution_comment?(%{"body" => body}) when is_binary(body),
    do: Regex.match?(~r/(?:^|\n)##\s+Resolution\s*(?:\n|$)/iu, body)

  defp resolution_comment?(_comment), do: false

  defp resolution_excerpt(body) do
    body
    |> String.split(~r/(?:^|\n)##\s+Resolution\s*(?:\n|$)/iu, parts: 2)
    |> List.last()
    |> String.split(~r/\n##\s+/u, parts: 2)
    |> List.first()
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> String.slice(0, @resolution_limit)
  end

  defp dependency_payloads(issues, ticket_map_ids) do
    issues
    |> Enum.flat_map(fn issue -> outgoing_dependencies(issue) ++ incoming_dependencies(issue) end)
    |> Enum.uniq_by(&{&1.from.id, &1.to.id, &1.kind})
    |> Enum.map(&Map.put(&1, :external, external_dependency?(&1, ticket_map_ids)))
    |> Enum.sort_by(&{&1.from.identifier || "", &1.to.identifier || ""})
  end

  defp external_dependency?(dependency, ticket_map_ids) do
    from_map_id = Map.get(ticket_map_ids, dependency.from.id)
    to_map_id = Map.get(ticket_map_ids, dependency.to.id)
    is_nil(from_map_id) or from_map_id != to_map_id
  end

  defp outgoing_dependencies(issue) do
    issue
    |> relation_nodes("relations")
    |> Enum.filter(&(&1["type"] == "blocks"))
    |> Enum.map(fn relation -> dependency(issue_ref(issue), issue_ref(relation["relatedIssue"])) end)
    |> Enum.reject(&invalid_dependency?/1)
  end

  defp incoming_dependencies(issue) do
    issue
    |> relation_nodes("inverseRelations")
    |> Enum.filter(&(&1["type"] == "blocks"))
    |> Enum.map(fn relation -> dependency(issue_ref(relation["issue"]), issue_ref(issue)) end)
    |> Enum.reject(&invalid_dependency?/1)
  end

  defp relation_nodes(issue, relation_name) do
    issue |> get_in([relation_name, "nodes"]) |> List.wrap() |> Enum.filter(&is_map/1)
  end

  defp dependency(from, to), do: %{from: from, to: to, kind: "blocks"}
  defp invalid_dependency?(%{from: %{id: nil}}), do: true
  defp invalid_dependency?(%{to: %{id: nil}}), do: true
  defp invalid_dependency?(_dependency), do: false

  defp issue_ref(nil), do: %{id: nil, identifier: nil, title: nil, url: nil, state: state_payload(nil)}

  defp issue_ref(issue) do
    %{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      url: issue["url"],
      state: state_payload(issue["state"])
    }
  end

  defp map_issue?(issue), do: "wayfinder:map" in label_names(issue)

  defp wayfinder_type(issue) do
    issue
    |> label_names()
    |> Enum.reject(&(&1 == "wayfinder:map"))
    |> Enum.filter(&String.starts_with?(&1, "wayfinder:"))
    |> Enum.sort()
    |> List.first("wayfinder:ticket")
    |> String.replace_prefix("wayfinder:", "")
  end

  defp label_names(issue) do
    issue
    |> get_in(["labels", "nodes"])
    |> List.wrap()
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp issue_sort_key(issue), do: {issue["identifier"] || "", issue["id"] || ""}
end
