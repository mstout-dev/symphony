defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{WayfinderGraph, WorkflowGroupDashboard}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:selected_project_id, nil)
      |> assign(:view, "operations")
      |> assign(:selected_map_id, nil)
      |> assign(:wayfinder_layout, "graph")
      |> assign(:selected_ticket_id, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_navigation(socket, params)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(%{payload: %{projects: _projects}, view: "wayfinder"} = assigns) do
    ~H"""
    <.wayfinder_dashboard
      payload={@payload}
      selected_project_id={@selected_project_id}
      selected_map_id={@selected_map_id}
      layout={@wayfinder_layout}
      selected_ticket_id={@selected_ticket_id}
    />
    """
  end

  def render(%{payload: %{projects: _projects}} = assigns) do
    ~H"""
    <.portfolio_dashboard
      payload={@payload}
      now={@now}
      selected_project_id={@selected_project_id}
    />
    """
  end

  def render(assigns) do
    ~H"""
    <.project_dashboard payload={@payload} now={@now} />
    """
  end

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)
  attr(:selected_project_id, :string, default: nil)

  defp portfolio_dashboard(assigns) do
    assigns =
      assigns
      |> assign(:summary, portfolio_summary(assigns.payload.projects, assigns.now))
      |> assign(:attention, attention_entries(assigns.payload.projects, assigns.now))
      |> assign(:selected_project, find_project(assigns.payload.projects, assigns.selected_project_id))

    ~H"""
    <section class="dashboard-shell portfolio-dashboard">
      <.portfolio_nav current="operations" />
      <header class="hero-card portfolio-hero">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Observability</p>
            <h1 class="hero-title">Portfolio Operations</h1>
            <p class="hero-copy">
              Read-only delivery signals across configured workflows. Linear owns work and review state; GitHub owns pull requests, checks, and review history.
            </p>
          </div>
          <div class="status-stack portfolio-status">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Parent runtime connected
            </span>
            <span class="last-updated">
              Last updated <span class="mono numeric"><%= @summary.generated_at %></span>
            </span>
          </div>
        </div>
      </header>

      <section class="section-card attention-card" aria-labelledby="todays-decisions-title">
        <div class="section-header">
          <div>
            <p class="eyebrow">Decision first</p>
            <h2 id="todays-decisions-title" class="section-title">Today’s decisions</h2>
            <p class="section-copy">
              Material delivery exceptions only. This informational view cannot change Linear or GitHub.
            </p>
          </div>
          <span class="attention-count numeric"><%= length(@attention) %> items</span>
        </div>

        <div :if={@summary.unavailable > 0} class="decision-unavailable" role="status">
          Delivery data unavailable for <%= @summary.unavailable %> workflow(s); decisions may be incomplete.
        </div>

        <%= if @attention == [] do %>
          <div class="calm-state" role="status">
            <strong>No delivery decisions need attention.</strong>
            <span>Supported blocked, retry, review, merge, and aging signals are clear. Review items outside active workflow states are unavailable.</span>
          </div>
        <% else %>
          <ol class="attention-list">
            <li :for={item <- @attention} class={"attention-item attention-item-#{item.kind}"}>
              <div class="attention-project"><%= item.project_name %></div>
              <div class="attention-main">
                <span class={state_badge_class(item.kind)}><%= attention_label(item.kind) %></span>
                <div class="decision-identity">
                  <.issue_identifier identifier={item.entry.issue_identifier} url={item.entry.issue_url} />
                  <strong><%= item.entry[:issue_title] || "Title unavailable" %></strong>
                </div>
                <span class="attention-message"><%= attention_message(item) %></span>
              </div>
              <dl class="decision-facts">
                <div><dt>Stage</dt><dd><%= delivery_stage(item) %></dd></div>
                <div><dt>Age</dt><dd><%= attention_time(item, @now) %></dd></div>
                <div><dt>Owner</dt><dd><%= item.entry[:review_owner] || "Unavailable" %></dd></div>
              </dl>
              <details class="decision-details">
                <summary>Supporting delivery details</summary>
                <p><strong>Reason:</strong> <%= attention_message(item) %></p>
                <nav aria-label={"Evidence for #{item.entry.issue_identifier}"}>
                  <.issue_identifier identifier={"Open Linear"} url={item.entry.issue_url} />
                  <%= if external_issue_url(item.entry[:pull_request_url]) do %>
                    <a class="issue-link" href={item.entry.pull_request_url} target="_blank" rel="noopener noreferrer">Open GitHub pull request</a>
                  <% else %>
                    <span class="missing-evidence">Pull request link unavailable</span>
                  <% end %>
                  <a class="issue-link" href={"/api/v1/#{item.entry.issue_identifier}"}>Agent-run JSON evidence</a>
                  <.link patch={"/?project=#{item.project_id}"} class="issue-link">Project detail</.link>
                </nav>
              </details>
            </li>
          </ol>
        <% end %>
      </section>

      <section class="metric-grid portfolio-metrics" aria-label="Portfolio runtime totals">
        <.portfolio_metric label="Workflows" value={@summary.workflows} detail="Configured in this runtime." />
        <.portfolio_metric label="Running" value={@summary.running} detail="Active issue sessions." />
        <.portfolio_metric label="Retrying" value={@summary.retrying} detail="Waiting for a retry window." />
        <.portfolio_metric label="Blocked" value={@summary.blocked} detail="Waiting for operator input." />
        <.portfolio_metric label="Total tokens" value={format_int(@summary.total_tokens)} detail={"In #{format_int(@summary.input_tokens)} / Out #{format_int(@summary.output_tokens)}"} />
        <.portfolio_metric label="Runtime" value={format_runtime_seconds(@summary.runtime_seconds)} detail="Completed and active Codex time." />
      </section>

      <div :if={portfolio_idle?(@summary)} class="portfolio-idle" role="status">
        <strong>Portfolio is idle.</strong>
        <span>Every configured workflow is available and has no running, blocked, or retrying work.</span>
      </div>

      <section class="section-card project-health-card">
        <div class="section-header">
          <div>
            <p class="eyebrow">Portfolio comparison</p>
            <h2 class="section-title">Project health</h2>
            <p class="section-copy">One current row for every configured workflow, including idle and unavailable projects.</p>
          </div>
        </div>

        <%= if @payload.projects == [] do %>
          <div class="calm-state" role="status">
            <strong>No workflows configured.</strong>
            <span>The parent runtime has not reported any project snapshots.</span>
          </div>
        <% else %>
          <div class="table-wrap project-table-wrap">
            <table class="data-table project-table">
              <thead>
                <tr>
                  <th>Project</th>
                  <th>Running</th>
                  <th>Retrying</th>
                  <th>Blocked</th>
                  <th>Tokens / runtime</th>
                  <th>Latest running update</th>
                  <th><span class="visually-hidden">Action</span></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={project <- @payload.projects}>
                  <td data-label="Project"><strong><%= project.name %></strong></td>
                  <%= if project.state[:error] do %>
                    <td colspan="5" class="snapshot-unavailable" data-label="Snapshot">
                      Snapshot unavailable · <%= project.state.error.code %>
                    </td>
                  <% else %>
                    <td data-label="Running" class="numeric"><%= project.state.counts.running %></td>
                    <td data-label="Retrying" class="numeric"><%= project.state.counts.retrying %></td>
                    <td data-label="Blocked" class="numeric"><%= project.state.counts.blocked %></td>
                    <td data-label="Tokens / runtime" class="numeric">
                      <%= format_int(project.state.codex_totals.total_tokens) %> / <%= format_runtime_seconds(total_runtime_seconds(project.state, @now)) %>
                    </td>
                    <td data-label="Latest update"><%= latest_running_update(project.state) %></td>
                  <% end %>
                  <td data-label="Action"><.link patch={"/?project=#{project.id}"} class="detail-link">View detail</.link></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>

      <section :if={@selected_project} class="project-focus" id="project-detail">
        <nav class="focus-nav" aria-label="Project focus">
          <.link patch="/" class="all-projects-link">← All projects</.link>
          <span>Focused on <strong><%= @selected_project.name %></strong></span>
        </nav>
        <.project_dashboard payload={@selected_project.state} now={@now} project_name={@selected_project.name} focused={true} />
      </section>
    </section>
    """
  end

  attr(:current, :string, required: true)

  defp portfolio_nav(assigns) do
    ~H"""
    <nav class="portfolio-switch" aria-label="Portfolio view">
      <.link patch="/?view=operations" class={if @current == "operations", do: "portfolio-switch-active"}>
        Operations
      </.link>
      <.link patch="/?view=wayfinder" class={if @current == "wayfinder", do: "portfolio-switch-active"}>
        Wayfinder
      </.link>
    </nav>
    """
  end

  attr(:payload, :map, required: true)
  attr(:selected_project_id, :string, default: nil)
  attr(:selected_map_id, :string, default: nil)
  attr(:layout, :string, required: true)
  attr(:selected_ticket_id, :string, default: nil)

  defp wayfinder_dashboard(assigns) do
    selected_project = find_project(assigns.payload.projects, assigns.selected_project_id)
    snapshot = wayfinder_for(selected_project)
    selected_map = Enum.find(snapshot.maps, &(&1.id == assigns.selected_map_id))
    tickets = tickets_for_map(snapshot, assigns.selected_map_id)
    graph = WayfinderGraph.layout(tickets, snapshot.dependencies)
    selected_ticket = Enum.find(tickets, &(&1.id == assigns.selected_ticket_id))

    assigns =
      assigns
      |> assign(:selected_project, selected_project)
      |> assign(:snapshot, snapshot)
      |> assign(:selected_map, selected_map)
      |> assign(:tickets, tickets)
      |> assign(:graph, graph)
      |> assign(:selected_ticket, selected_ticket)
      |> assign(:rail_tickets, Enum.map(graph.nodes, & &1.ticket) ++ graph.repair_tickets)
      |> assign(:active_maps, wayfinder_map_entries(assigns.payload.projects, :active))
      |> assign(:inactive_maps, wayfinder_map_entries(assigns.payload.projects, :inactive))
      |> assign(:completed_tickets, Enum.filter(tickets, &get_in(&1, [:completion, :completed])))
      |> assign(:repair_count, snapshot.orphaned_count + length(graph.repair_tickets))
      |> assign(:external_relations, external_relations(snapshot.dependencies, selected_ticket))

    ~H"""
    <section class="dashboard-shell wayfinder-dashboard">
      <.portfolio_nav current="wayfinder" />

      <header class="hero-card wayfinder-hero">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Read-only portfolio topology</p>
            <h1 class="hero-title">Portfolio Wayfinder</h1>
            <p class="hero-copy">
              Maps, edge tickets, and blocking relationships from Linear—arranged as the work actually depends on itself.
            </p>
          </div>
          <div class="status-stack portfolio-status">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Parent runtime connected
            </span>
            <span class="last-updated">
              Snapshot <span class="mono numeric"><%= @snapshot.generated_at %></span>
            </span>
          </div>
        </div>
      </header>

      <section class="wayfinder-project-strip" aria-label="Wayfinder projects">
        <.link
          :for={project <- @payload.projects}
          patch={wayfinder_path(project.id, first_map_id(wayfinder_for(project)), @layout)}
          class={[
            "wayfinder-project-chip",
            project.id == @selected_project_id && "wayfinder-project-chip-active"
          ]}
        >
          <span><%= project.name %></span>
          <small class={"wayfinder-source-#{wayfinder_for(project).status}"}>
            <%= wayfinder_status_label(wayfinder_for(project).status) %>
          </small>
        </.link>
      </section>

      <section class="section-card map-library" aria-labelledby="active-maps-title">
        <div class="section-header">
          <div>
            <p class="eyebrow">Map library</p>
            <h2 id="active-maps-title" class="section-title">Active maps</h2>
            <p class="section-copy">Open work appears first across every configured workflow.</p>
          </div>
          <span class="attention-count numeric"><%= length(@active_maps) %> active</span>
        </div>

        <div :if={@active_maps != []} class="map-card-grid">
          <.link
            :for={entry <- @active_maps}
            patch={wayfinder_path(entry.project.id, entry.map.id, @layout)}
            class={[
              "map-card",
              entry.project.id == @selected_project_id && entry.map.id == @selected_map_id && "map-card-selected"
            ]}
          >
            <span class="map-card-project"><%= entry.project.name %></span>
            <strong><%= entry.map.title %></strong>
            <span class="map-card-meta">
              <span class="mono"><%= entry.map.identifier %></span>
              <span><%= length(entry.map.ticket_ids) %> tickets</span>
            </span>
          </.link>
        </div>

        <div :if={@active_maps == []} class="calm-state" role="status">
          <strong>No active maps.</strong>
          <span>Completed and abandoned maps remain available below.</span>
        </div>

        <details :if={@inactive_maps != []} class="inactive-map-drawer">
          <summary>Completed &amp; abandoned maps · <%= length(@inactive_maps) %></summary>
          <div class="map-card-grid">
            <.link
              :for={entry <- @inactive_maps}
              patch={wayfinder_path(entry.project.id, entry.map.id, @layout)}
              class="map-card map-card-muted"
            >
              <span class="map-card-project"><%= entry.project.name %></span>
              <strong><%= entry.map.title %></strong>
              <span class="map-card-meta mono"><%= entry.map.identifier %></span>
            </.link>
          </div>
        </details>
      </section>

      <%= if @snapshot.status == "available" and @selected_map do %>
        <section class="wayfinder-workspace">
          <article class="section-card wayfinder-canvas-card">
            <div class="section-header wayfinder-map-header">
              <div>
                <p class="eyebrow"><%= @selected_project.name %> · <%= @selected_map.identifier %></p>
                <h2 class="section-title"><%= @selected_map.title %></h2>
                <p class="section-copy"><%= length(@tickets) %> mapped tickets · arrows point from prerequisite to dependent work.</p>
              </div>
              <div class="layout-switch" aria-label="Wayfinder layout">
                <.link
                  patch={wayfinder_path(@selected_project.id, @selected_map.id, "graph", @selected_ticket_id)}
                  class={if @layout == "graph", do: "layout-switch-active"}
                >Graph</.link>
                <.link
                  patch={wayfinder_path(@selected_project.id, @selected_map.id, "rails", @selected_ticket_id)}
                  class={if @layout == "rails", do: "layout-switch-active"}
                >Rails</.link>
              </div>
            </div>

            <%= if @layout == "graph" do %>
              <div class="wayfinder-graph-scroll">
                <div class="wayfinder-graph" style={"width: #{@graph.width}px; height: #{@graph.height}px"}>
                  <svg
                    data-wayfinder-graph
                    width={@graph.width}
                    height={@graph.height}
                    viewBox={"0 0 #{@graph.width} #{@graph.height}"}
                    role="img"
                    aria-label={"Dependency graph for #{@selected_map.title}"}
                  >
                    <defs>
                      <marker id="wayfinder-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                        <path d="M 0 0 L 10 5 L 0 10 z" class="wayfinder-arrowhead" />
                      </marker>
                    </defs>
                    <path
                      :for={edge <- @graph.edges}
                      d={edge.path}
                      data-from={edge.from_id}
                      data-to={edge.to_id}
                      class="wayfinder-connector"
                      marker-end="url(#wayfinder-arrow)"
                    />
                  </svg>

                  <.link
                    :for={node <- @graph.nodes}
                    patch={wayfinder_path(@selected_project.id, @selected_map.id, @layout, node.ticket.id)}
                    data-wayfinder-node={node.ticket.id}
                    class={[
                      "wayfinder-node",
                      get_in(node.ticket, [:completion, :completed]) && "wayfinder-node-complete",
                      node.ticket.id == @selected_ticket_id && "wayfinder-node-selected"
                    ]}
                    style={"left: #{node.x}px; top: #{node.y}px"}
                  >
                    <span class="wayfinder-node-topline">
                      <span class="mono"><%= node.ticket.identifier %></span>
                      <span class="wayfinder-type"><%= node.ticket.wayfinder_type %></span>
                    </span>
                    <strong><%= node.ticket.title %></strong>
                    <span class="wayfinder-node-state"><%= node.ticket.state.name %></span>
                  </.link>
                </div>
              </div>
            <% else %>
              <div class="wayfinder-rails">
                <div class="rails-heading">
                  <p class="eyebrow">Alternate view</p>
                  <h3>Dependency rails</h3>
                </div>
                <.link
                  :for={ticket <- @rail_tickets}
                  patch={wayfinder_path(@selected_project.id, @selected_map.id, @layout, ticket.id)}
                  data-wayfinder-rail={ticket.id}
                  class={[
                    "wayfinder-rail",
                    get_in(ticket, [:completion, :completed]) && "wayfinder-rail-complete",
                    ticket.id == @selected_ticket_id && "wayfinder-rail-selected"
                  ]}
                >
                  <span class="rail-marker"></span>
                  <span class="mono"><%= ticket.identifier %></span>
                  <strong><%= ticket.title %></strong>
                  <span><%= ticket.state.name %></span>
                </.link>
              </div>
            <% end %>

            <section :if={@repair_count > 0} class="relation-repair" aria-labelledby="relation-repair-title">
              <div>
                <p class="eyebrow">Data quality</p>
                <h3 id="relation-repair-title">Needs relation repair</h3>
                <p><%= relationship_repair_label(@repair_count) %>. Cyclic tickets and children without a fetched map stay out of the graph.</p>
              </div>
              <div class="repair-ticket-list">
                <span :for={ticket <- @graph.repair_tickets} class="mono"><%= ticket.identifier %></span>
              </div>
            </section>

            <section class="completion-ledger" aria-labelledby="completion-ledger-title">
              <div class="section-header compact-section-header">
                <div>
                  <p class="eyebrow">Durable record</p>
                  <h3 id="completion-ledger-title" class="section-title">Completed edge tickets</h3>
                </div>
                <span class="attention-count numeric"><%= length(@completed_tickets) %> resolved</span>
              </div>

              <div :if={@completed_tickets == []} class="calm-state compact-calm-state">
                <strong>No completed edge tickets yet.</strong>
                <span>Resolution excerpts will appear here when work closes.</span>
              </div>

              <ol :if={@completed_tickets != []} class="completion-list">
                <li :for={ticket <- @completed_tickets}>
                  <.link patch={wayfinder_path(@selected_project.id, @selected_map.id, @layout, ticket.id)}>
                    <span class="mono"><%= ticket.identifier %></span>
                    <strong><%= ticket.title %></strong>
                    <span><%= resolution_excerpt(ticket) %></span>
                  </.link>
                </li>
              </ol>
            </section>
          </article>

          <aside class="section-card ticket-inspector" aria-labelledby="ticket-inspector-title">
            <%= if @selected_ticket do %>
              <div class="inspector-heading">
                <p class="eyebrow">Ticket inspector</p>
                <h2 id="ticket-inspector-title"><%= @selected_ticket.title %></h2>
                <div class="inspector-badges">
                  <span class="mono"><%= @selected_ticket.identifier %></span>
                  <span class="wayfinder-type"><%= @selected_ticket.wayfinder_type %></span>
                </div>
              </div>

              <dl class="inspector-facts">
                <div><dt>Status</dt><dd><%= @selected_ticket.state.name %></dd></div>
                <div><dt>Updated</dt><dd class="mono"><%= @selected_ticket.updated_at || "Unavailable" %></dd></div>
              </dl>

              <section class="inspector-section">
                <h3>Resolution</h3>
                <p><%= resolution_excerpt(@selected_ticket) %></p>
              </section>

              <section :if={@external_relations != []} class="inspector-section">
                <h3>External blockers</h3>
                <ul class="external-relation-list">
                  <li :for={relation <- @external_relations}>
                    <span><%= relation.direction %></span>
                    <strong class="mono"><%= relation.issue.identifier %></strong>
                    <small><%= relation.issue.title || "Title unavailable" %></small>
                  </li>
                </ul>
              </section>

              <section class="inspector-section">
                <h3>Linked artifacts</h3>
                <ul :if={@selected_ticket.artifacts != []} class="artifact-list">
                  <li :for={artifact <- @selected_ticket.artifacts}>
                    <a :if={external_issue_url(artifact.url)} href={artifact.url} target="_blank" rel="noopener noreferrer"><%= artifact.title %></a>
                  </li>
                </ul>
                <p :if={@selected_ticket.artifacts == []} class="muted-copy">No linked Linear documents.</p>
              </section>

              <a :if={external_issue_url(@selected_ticket.url)} class="inspector-linear-link" href={@selected_ticket.url} target="_blank" rel="noopener noreferrer">
                Open in Linear ↗
              </a>
            <% else %>
              <div class="inspector-empty">
                <p class="eyebrow">Ticket inspector</p>
                <h2 id="ticket-inspector-title">Choose a ticket</h2>
                <p>Select a graph node or rail to inspect its resolution, artifacts, and external blockers.</p>
              </div>
            <% end %>
          </aside>
        </section>
      <% else %>
        <section class="section-card wayfinder-unavailable" role="status">
          <p class="eyebrow"><%= wayfinder_status_label(@snapshot.status) %></p>
          <h2><%= wayfinder_empty_title(@snapshot.status) %></h2>
          <p><%= wayfinder_empty_copy(@snapshot.status) %></p>
        </section>
      <% end %>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)

  defp portfolio_metric(assigns) do
    ~H"""
    <article class="metric-card" data-metric={@label |> String.downcase() |> String.replace(" ", "-")}>
      <p class="metric-label"><%= @label %></p>
      <p class="metric-value numeric"><%= @value %></p>
      <p class="metric-detail"><%= @detail %></p>
    </article>
    """
  end

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)
  attr(:project_name, :string, default: nil)
  attr(:focused, :boolean, default: false)

  defp project_dashboard(assigns) do
    ~H"""
    <section class={"dashboard-shell #{if @focused, do: "focused-dashboard", else: ""}"}>
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              <%= @project_name || "Symphony Observability" %>
            </p>
            <h1 class="hero-title"><%= if @focused, do: "Project Operations", else: "Operations Dashboard" %></h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div :if={not @focused} class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp assign_navigation(socket, params) do
    payload = socket.assigns.payload

    if params["view"] == "wayfinder" and match?(%{projects: _projects}, payload) do
      project = selected_wayfinder_project(payload.projects, params["project"])
      snapshot = wayfinder_for(project)
      map_id = selected_wayfinder_map_id(snapshot, params["map"])
      ticket_id = selected_wayfinder_ticket_id(snapshot, map_id, params["ticket"])

      socket
      |> assign(:view, "wayfinder")
      |> assign(:selected_project_id, project && project.id)
      |> assign(:selected_map_id, map_id)
      |> assign(:wayfinder_layout, if(params["layout"] == "rails", do: "rails", else: "graph"))
      |> assign(:selected_ticket_id, ticket_id)
    else
      socket
      |> assign(:view, "operations")
      |> assign(:selected_project_id, selected_project_id(payload, params))
      |> assign(:selected_map_id, nil)
      |> assign(:wayfinder_layout, "graph")
      |> assign(:selected_ticket_id, nil)
    end
  end

  defp selected_wayfinder_project(projects, requested_id) do
    Enum.find(projects, &(&1.id == requested_id and wayfinder_for(&1).status == "available")) ||
      Enum.find(projects, &(wayfinder_for(&1).status == "available")) ||
      Enum.find(projects, &Map.has_key?(&1.state, :wayfinder))
  end

  defp selected_wayfinder_map_id(snapshot, requested_id) do
    case Enum.find(snapshot.maps, &(&1.id == requested_id)) do
      nil -> first_map_id(snapshot)
      selected_map -> selected_map.id
    end
  end

  defp selected_wayfinder_ticket_id(snapshot, map_id, requested_id) do
    snapshot
    |> tickets_for_map(map_id)
    |> Enum.find_value(fn ticket -> if ticket.id == requested_id, do: ticket.id end)
  end

  defp wayfinder_for(nil), do: empty_wayfinder("unavailable")

  defp wayfinder_for(project) do
    defaults = empty_wayfinder("unavailable")

    case project.state[:wayfinder] do
      %{} = snapshot -> Map.merge(defaults, snapshot)
      _ -> defaults
    end
  end

  defp empty_wayfinder(status) do
    %{
      status: status,
      generated_at: "Not yet available",
      orphaned_count: 0,
      maps: [],
      tickets: [],
      dependencies: []
    }
  end

  defp first_map_id(snapshot) do
    case Enum.find(snapshot.maps, &active_wayfinder_map?/1) || List.first(snapshot.maps) do
      nil -> nil
      map -> map.id
    end
  end

  defp wayfinder_map_entries(projects, activity) do
    projects
    |> Enum.flat_map(fn project ->
      snapshot = wayfinder_for(project)

      if snapshot.status == "available" do
        Enum.map(snapshot.maps, &%{project: project, map: &1})
      else
        []
      end
    end)
    |> Enum.filter(fn entry ->
      case activity do
        :active -> active_wayfinder_map?(entry.map)
        :inactive -> not active_wayfinder_map?(entry.map)
      end
    end)
    |> Enum.sort_by(&{&1.project.name, &1.map.identifier || "", &1.map.id})
  end

  defp active_wayfinder_map?(map) do
    not get_in(map, [:completion, :completed]) and get_in(map, [:state, :type]) not in ["completed", "canceled"]
  end

  defp tickets_for_map(_snapshot, nil), do: []

  defp tickets_for_map(snapshot, map_id) do
    snapshot.tickets
    |> Enum.filter(&(&1.map_id == map_id))
    |> Enum.sort_by(&{&1.identifier || "", &1.id})
  end

  defp wayfinder_path(project_id, map_id, layout, ticket_id \\ nil) do
    [view: "wayfinder", project: project_id, map: map_id, layout: layout, ticket: ticket_id]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> URI.encode_query()
    |> then(&"/?#{&1}")
  end

  defp wayfinder_status_label("available"), do: "Available"
  defp wayfinder_status_label("loading"), do: "Loading"
  defp wayfinder_status_label("unsupported"), do: "Linear only"
  defp wayfinder_status_label(_status), do: "Unavailable"

  defp wayfinder_empty_title("loading"), do: "Building the first Wayfinder snapshot"
  defp wayfinder_empty_title("unsupported"), do: "Wayfinder is unavailable for this tracker"
  defp wayfinder_empty_title("available"), do: "No map selected"
  defp wayfinder_empty_title(_status), do: "Wayfinder data unavailable"

  defp wayfinder_empty_copy("loading"), do: "This workflow will appear after its initial Linear refresh."

  defp wayfinder_empty_copy("unsupported"),
    do: "Version one reads Linear map and ticket relationships; this workflow uses another tracker."

  defp wayfinder_empty_copy("available"), do: "Add a wayfinder:map issue in Linear to begin mapping this workflow."
  defp wayfinder_empty_copy(_status), do: "This project has no current Wayfinder snapshot. Other projects remain usable."

  defp relationship_repair_label(1), do: "1 relationship needs repair"
  defp relationship_repair_label(count), do: "#{count} relationships need repair"

  defp resolution_excerpt(%{resolution: %{excerpt: excerpt}}) when is_binary(excerpt) and excerpt != "",
    do: excerpt

  defp resolution_excerpt(_ticket), do: "Resolution not recorded."

  defp external_relations(_dependencies, nil), do: []

  defp external_relations(dependencies, ticket) do
    dependencies
    |> Enum.filter(&Map.get(&1, :external, false))
    |> Enum.flat_map(fn dependency ->
      cond do
        dependency.to.id == ticket.id -> [%{direction: "Blocked by", issue: dependency.from}]
        dependency.from.id == ticket.id -> [%{direction: "Blocks", issue: dependency.to}]
        true -> []
      end
    end)
    |> Enum.sort_by(&{&1.direction, &1.issue.identifier || ""})
  end

  defp selected_project_id(%{projects: projects}, %{"project" => project_id})
       when is_binary(project_id) do
    if Enum.any?(projects, &(&1.id == project_id)), do: project_id
  end

  defp selected_project_id(_payload, _params), do: nil

  defp find_project(projects, project_id), do: Enum.find(projects, &(&1.id == project_id))

  defp portfolio_summary(projects, now) do
    initial = %{
      workflows: length(projects),
      running: 0,
      retrying: 0,
      blocked: 0,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      runtime_seconds: 0,
      unavailable: 0,
      generated_at: "Not yet available"
    }

    Enum.reduce(projects, initial, fn project, summary ->
      state = project.state

      summary =
        if state[:error] do
          %{summary | unavailable: summary.unavailable + 1}
        else
          %{
            summary
            | running: summary.running + state.counts.running,
              retrying: summary.retrying + state.counts.retrying,
              blocked: summary.blocked + state.counts.blocked,
              input_tokens: summary.input_tokens + numeric_value(state.codex_totals.input_tokens),
              output_tokens: summary.output_tokens + numeric_value(state.codex_totals.output_tokens),
              total_tokens: summary.total_tokens + numeric_value(state.codex_totals.total_tokens),
              runtime_seconds: summary.runtime_seconds + total_runtime_seconds(state, now)
          }
        end

      %{summary | generated_at: latest_timestamp(summary.generated_at, state[:generated_at])}
    end)
  end

  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_value), do: 0

  defp portfolio_idle?(summary) do
    summary.workflows > 0 and summary.unavailable == 0 and summary.running == 0 and
      summary.retrying == 0 and summary.blocked == 0
  end

  defp latest_timestamp("Not yet available", value) when is_binary(value), do: value
  defp latest_timestamp(current, nil), do: current
  defp latest_timestamp(current, value) when value > current, do: value
  defp latest_timestamp(current, _value), do: current

  defp attention_entries(projects, now) do
    projects
    |> Enum.flat_map(&project_attention_entries(&1, now))
    |> Enum.sort_by(fn item ->
      {attention_priority(item.kind), attention_sort_time(item), item.project_name, item.entry.issue_identifier}
    end)
  end

  defp project_attention_entries(project, now) do
    if project.state[:error] do
      []
    else
      blocked =
        Enum.map(project.state.blocked, fn entry ->
          attention_entry(project, :blocked, entry)
        end)

      retrying =
        Enum.map(project.state.retrying, fn entry ->
          attention_entry(project, :retrying, entry)
        end)

      delivery =
        project.state.running
        |> Enum.map(&delivery_attention_entry(project, &1, now))
        |> Enum.reject(&is_nil/1)

      blocked ++ retrying ++ delivery
    end
  end

  defp delivery_attention_entry(project, entry, now) do
    normalized = entry.state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, "review") ->
        attention_entry(project, :review, entry)

      String.contains?(normalized, "merging") or String.contains?(normalized, "merge") ->
        attention_entry(project, :merge, entry)

      state_age_seconds(entry, now) >= 86_400 ->
        attention_entry(project, :aging, entry)

      true ->
        nil
    end
  end

  defp attention_entry(project, kind, entry) do
    %{project_id: project.id, project_name: project.name, kind: kind, entry: entry}
  end

  defp attention_sort_time(%{kind: :blocked, entry: entry}), do: entry[:blocked_at] || ""
  defp attention_sort_time(%{entry: entry}), do: entry[:due_at] || "9999"

  defp attention_priority(:blocked), do: 0
  defp attention_priority(:retrying), do: 1
  defp attention_priority(:review), do: 2
  defp attention_priority(:merge), do: 3
  defp attention_priority(:aging), do: 4

  defp attention_label(:blocked), do: "Blocked"
  defp attention_label(:retrying), do: "Retrying"
  defp attention_label(:review), do: "Review decision"
  defp attention_label(:merge), do: "Merge decision"
  defp attention_label(:aging), do: "Aging delivery"

  defp attention_message(%{kind: :blocked, entry: entry}), do: entry.error || "Operator input required"

  defp attention_message(%{kind: :retrying, entry: entry}),
    do: entry.error || "Waiting for retry attempt #{entry.attempt}"

  defp attention_message(%{kind: :review}), do: "Human review is required"
  defp attention_message(%{kind: :merge}), do: "Approved work is awaiting merge"
  defp attention_message(%{kind: :aging}), do: "Delivery stage has not changed within 24 hours"

  defp attention_time(%{kind: :blocked, entry: entry}, now), do: format_age(entry.blocked_at, now)
  defp attention_time(%{kind: :retrying, entry: entry}, _now), do: entry.due_at || "Due time unavailable"
  defp attention_time(%{entry: entry}, now), do: format_age(entry[:state_updated_at], now)

  defp delivery_stage(%{kind: :blocked, entry: entry}), do: entry[:state] || "Blocked"
  defp delivery_stage(%{kind: :retrying, entry: entry}), do: entry[:state] || "Retry queue"
  defp delivery_stage(%{entry: entry}), do: entry[:state] || "Unavailable"

  defp state_age_seconds(entry, now) do
    case parse_datetime(entry[:state_updated_at]) do
      %DateTime{} = updated_at -> max(DateTime.diff(now, updated_at, :second), 0)
      nil -> 0
    end
  end

  defp format_age(value, now) do
    case parse_datetime(value) do
      %DateTime{} = then ->
        hours = max(DateTime.diff(now, then, :second), 0) |> div(3_600)
        if hours < 24, do: "#{hours}h in state", else: "#{div(hours, 24)}d #{rem(hours, 24)}h in state"

      nil ->
        "Age unavailable"
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp latest_running_update(%{running: []}), do: "No running update"

  defp latest_running_update(%{running: running}) do
    entry = Enum.max_by(running, &(&1.last_event_at || ""))
    message = entry.last_message || to_string(entry.last_event || "Update unavailable")

    if entry.last_event_at, do: "#{message} · #{entry.last_event_at}", else: message
  end

  defp load_payload do
    case Endpoint.config(:group_dashboard) do
      nil -> Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
      group_dashboard -> WorkflowGroupDashboard.state_payload(group_dashboard)
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
