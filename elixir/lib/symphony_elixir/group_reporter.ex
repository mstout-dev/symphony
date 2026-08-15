defmodule SymphonyElixir.GroupReporter do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter}

  @frame_prefix "SYMPHONY_GROUP_SNAPSHOT_V1:"
  @report_interval_ms 5_000

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
    @frame_prefix <> (payload |> :erlang.term_to_binary() |> Base.encode64())
  end

  @doc false
  @spec decode_snapshot(binary()) :: {:ok, map()} | :error
  def decode_snapshot(@frame_prefix <> encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         payload when is_map(payload) <- :erlang.binary_to_term(binary, [:safe]) do
      {:ok, payload}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def decode_snapshot(_line), do: :error

  defp report(orchestrator) do
    payload = Presenter.state_payload(orchestrator, 15_000)
    IO.puts(encode_snapshot(payload))
  end
end
