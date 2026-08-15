defmodule SymphonyElixir.GroupReporter do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter}

  @frame_prefix "SYMPHONY_GROUP_SNAPSHOT_V1:"
  @report_interval_ms 5_000
  @payload_keys %{
    "attempt" => :attempt,
    "blocked" => :blocked,
    "blocked_at" => :blocked_at,
    "code" => :code,
    "codex_totals" => :codex_totals,
    "counts" => :counts,
    "due_at" => :due_at,
    "error" => :error,
    "generated_at" => :generated_at,
    "input_tokens" => :input_tokens,
    "issue_id" => :issue_id,
    "issue_identifier" => :issue_identifier,
    "issue_url" => :issue_url,
    "last_event" => :last_event,
    "last_event_at" => :last_event_at,
    "last_message" => :last_message,
    "message" => :message,
    "output_tokens" => :output_tokens,
    "rate_limits" => :rate_limits,
    "retrying" => :retrying,
    "running" => :running,
    "seconds_running" => :seconds_running,
    "session_id" => :session_id,
    "started_at" => :started_at,
    "state" => :state,
    "tokens" => :tokens,
    "total_tokens" => :total_tokens,
    "turn_count" => :turn_count,
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
    {:ok, Keyword.get(opts, :orchestrator, Orchestrator)}
  end

  @impl true
  def handle_info(:observability_updated, orchestrator) do
    report(orchestrator)
    {:noreply, orchestrator}
  end

  def handle_info(:report, orchestrator) do
    report(orchestrator)
    Process.send_after(self(), :report, @report_interval_ms)
    {:noreply, orchestrator}
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

  defp report(orchestrator) do
    payload = Presenter.state_payload(orchestrator, 15_000)
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
