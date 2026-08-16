defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.WorkflowGroupDashboard
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:selected_project_id, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selected_project_id, selected_project_id(socket.assigns.payload, params))}
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
      |> assign(:attention, attention_entries(assigns.payload.projects))
      |> assign(:selected_project, find_project(assigns.payload.projects, assigns.selected_project_id))

    ~H"""
    <section class="dashboard-shell portfolio-dashboard">
      <header class="hero-card portfolio-hero">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Observability</p>
            <h1 class="hero-title">Portfolio Operations</h1>
            <p class="hero-copy">
              Current work and attention across every configured workflow in this parent runtime.
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

      <section class="metric-grid portfolio-metrics" aria-label="Portfolio totals">
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

      <section class="section-card attention-card">
        <div class="section-header">
          <div>
            <p class="eyebrow">Attention first</p>
            <h2 class="section-title">Needs attention</h2>
            <p class="section-copy">Blocked work first, followed by retries in due-time order.</p>
          </div>
          <span class="attention-count numeric"><%= length(@attention) %> items</span>
        </div>

        <%= if @attention == [] do %>
          <div class="calm-state" role="status">
            <strong>No work needs attention.</strong>
            <span>Blocked and retrying queues are clear across all available snapshots.</span>
          </div>
        <% else %>
          <ol class="attention-list">
            <li :for={item <- @attention} class={"attention-item attention-item-#{item.kind}"}>
              <div class="attention-project"><%= item.project_name %></div>
              <div class="attention-main">
                <span class={state_badge_class(item.kind)}><%= attention_label(item.kind) %></span>
                <.issue_identifier identifier={item.entry.issue_identifier} url={item.entry.issue_url} />
                <span class="attention-message"><%= attention_message(item) %></span>
              </div>
              <div class="attention-actions">
                <span class="mono"><%= attention_time(item) %></span>
                <.link patch={~p"/?project=#{item.project_id}"} class="issue-link">Project detail</.link>
                <a class="issue-link" href={"/api/v1/#{item.entry.issue_identifier}"}>JSON details</a>
              </div>
            </li>
          </ol>
        <% end %>
      </section>

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
                  <td data-label="Action"><.link patch={~p"/?project=#{project.id}"} class="detail-link">View detail</.link></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>

      <section :if={@selected_project} class="project-focus" id="project-detail">
        <nav class="focus-nav" aria-label="Project focus">
          <.link patch={~p"/"} class="all-projects-link">← All projects</.link>
          <span>Focused on <strong><%= @selected_project.name %></strong></span>
        </nav>
        <.project_dashboard payload={@selected_project.state} now={@now} project_name={@selected_project.name} focused={true} />
      </section>
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

  defp attention_entries(projects) do
    projects
    |> Enum.flat_map(fn project ->
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

        blocked ++ retrying
      end
    end)
    |> Enum.sort_by(fn item ->
      {if(item.kind == :blocked, do: 0, else: 1), attention_sort_time(item), item.project_name,
       item.entry.issue_identifier}
    end)
  end

  defp attention_entry(project, kind, entry) do
    %{project_id: project.id, project_name: project.name, kind: kind, entry: entry}
  end

  defp attention_sort_time(%{kind: :blocked, entry: entry}), do: entry[:blocked_at] || ""
  defp attention_sort_time(%{entry: entry}), do: entry[:due_at] || "9999"

  defp attention_label(:blocked), do: "Blocked"
  defp attention_label(:retrying), do: "Retrying"

  defp attention_message(%{kind: :blocked, entry: entry}), do: entry.error || "Operator input required"

  defp attention_message(%{kind: :retrying, entry: entry}),
    do: entry.error || "Waiting for retry attempt #{entry.attempt}"

  defp attention_time(%{kind: :blocked, entry: entry}), do: entry.blocked_at || "Time unavailable"
  defp attention_time(%{kind: :retrying, entry: entry}), do: entry.due_at || "Due time unavailable"

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
