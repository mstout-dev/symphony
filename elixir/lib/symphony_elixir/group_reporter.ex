defmodule SymphonyElixir.GroupReporter do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.{Orchestrator, WayfinderSnapshot}
  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter}

  @frame_prefix "SYMPHONY_GROUP_SNAPSHOT_V1:"
  @report_interval_ms 5_000
  @payload_keys %{
    "attempt" => :attempt,
    "artifacts" => :artifacts,
    "blocked" => :blocked,
    "blocked_at" => :blocked_at,
    "code" => :code,
    "codex_totals" => :codex_totals,
    "counts" => :counts,
    "completed" => :completed,
    "completed_at" => :completed_at,
    "completion" => :completion,
    "comment_id" => :comment_id,
    "created_at" => :created_at,
    "dependencies" => :dependencies,
    "due_at" => :due_at,
    "error" => :error,
    "generated_at" => :generated_at,
    "external" => :external,
    "excerpt" => :excerpt,
    "from" => :from,
    "id" => :id,
    "input_tokens" => :input_tokens,
    "identifier" => :identifier,
    "issue_id" => :issue_id,
    "issue_identifier" => :issue_identifier,
    "issue_url" => :issue_url,
    "last_event" => :last_event,
    "last_event_at" => :last_event_at,
    "last_message" => :last_message,
    "kind" => :kind,
    "message" => :message,
    "maps" => :maps,
    "map_id" => :map_id,
    "name" => :name,
    "orphaned_count" => :orphaned_count,
    "output_tokens" => :output_tokens,
    "rate_limits" => :rate_limits,
    "resolution" => :resolution,
    "retrying" => :retrying,
    "running" => :running,
    "seconds_running" => :seconds_running,
    "session_id" => :session_id,
    "started_at" => :started_at,
    "state" => :state,
    "status" => :status,
    "ticket_ids" => :ticket_ids,
    "tickets" => :tickets,
    "title" => :title,
    "to" => :to,
    "tokens" => :tokens,
    "total_tokens" => :total_tokens,
    "turn_count" => :turn_count,
    "type" => :type,
    "updated_at" => :updated_at,
    "url" => :url,
    "wayfinder" => :wayfinder,
    "wayfinder_type" => :wayfinder_type,
    "worker_host" => :worker_host,
    "workspace_path" => :workspace_path
  }

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    if System.get_env("SYMPHONY_MANAGED_CHILD") == "1" do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    :ok = ObservabilityPubSub.subscribe()
    send(self(), :report)

    {:ok,
     %{
       orchestrator: Keyword.get(opts, :orchestrator, Orchestrator),
       wayfinder: Keyword.get(opts, :wayfinder, WayfinderSnapshot)
     }}
  end

  @impl true
  def handle_info(:observability_updated, state) do
    report(state)
    {:noreply, state}
  end

  def handle_info(:report, state) do
    report(state)
    Process.send_after(self(), :report, @report_interval_ms)
    {:noreply, state}
  end

  @doc false
  @spec encode_snapshot(map()) :: String.t()
  def encode_snapshot(payload) when is_map(payload) do
    @frame_prefix <> Jason.encode!(payload)
  end

  @doc false
  @spec decode_snapshot(binary()) :: {:ok, map()} | :error
  def decode_snapshot(@frame_prefix <> json) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> {:ok, normalize_keys(payload)}
      _ -> :error
    end
  end

  def decode_snapshot(_line), do: :error

  @doc false
  @spec decorate_payload(map(), map()) :: map()
  def decorate_payload(runtime_payload, wayfinder_snapshot)
      when is_map(runtime_payload) and is_map(wayfinder_snapshot) do
    Map.put(runtime_payload, :wayfinder, wayfinder_snapshot)
  end

  defp report(state) do
    payload =
      state.orchestrator
      |> Presenter.state_payload(15_000)
      |> decorate_payload(WayfinderSnapshot.snapshot(state.wayfinder))

    IO.puts(encode_snapshot(payload))
  end

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {Map.get(@payload_keys, key, key), normalize_keys(nested)}
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value
end
