defmodule SymphonyElixir.WayfinderSnapshot do
  @moduledoc """
  Owns the read-only Wayfinder snapshot for one workflow runtime.

  Refreshes follow the workflow polling interval. A failed refresh deliberately
  replaces prior data so the portfolio never presents stale topology as current.
  """

  use GenServer

  alias SymphonyElixir.Linear.Wayfinder
  alias SymphonyElixir.WorkflowStore

  @type snapshot :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec snapshot(GenServer.name()) :: snapshot()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> unavailable_snapshot()
  end

  @spec refresh(GenServer.name()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.cast(server, :refresh)
  end

  @impl true
  def init(opts) do
    state = %{
      settings_fun: Keyword.get(opts, :settings_fun, &WorkflowStore.settings/0),
      fetch_fun: Keyword.get(opts, :fetch_fun, &Wayfinder.fetch/1),
      snapshot: loading_snapshot()
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :refresh)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {snapshot, interval_ms} = refresh_snapshot(state)
    Process.send_after(self(), :refresh, interval_ms)
    {:noreply, %{state | snapshot: snapshot}}
  end

  defp refresh_snapshot(state) do
    case state.settings_fun.() do
      {:ok, %{tracker: %{kind: "linear"} = tracker, polling: polling}} ->
        snapshot =
          case state.fetch_fun.(tracker) do
            {:ok, snapshot} -> snapshot
            {:error, _reason} -> unavailable_snapshot()
          end

        {snapshot, polling_interval(polling)}

      {:ok, %{polling: polling}} ->
        {unsupported_snapshot(), polling_interval(polling)}

      {:error, _reason} ->
        {unavailable_snapshot(), 30_000}
    end
  end

  defp polling_interval(%{interval_ms: interval_ms}) when is_integer(interval_ms) and interval_ms > 0,
    do: interval_ms

  defp polling_interval(_polling), do: 30_000

  defp loading_snapshot do
    empty_snapshot("loading")
  end

  defp unsupported_snapshot do
    empty_snapshot("unsupported")
  end

  defp unavailable_snapshot do
    "unavailable"
    |> empty_snapshot()
    |> Map.put(:error, %{
      code: "wayfinder_unavailable",
      message: "Wayfinder data is temporarily unavailable"
    })
  end

  defp empty_snapshot(status) do
    %{
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      orphaned_count: 0,
      maps: [],
      tickets: [],
      dependencies: []
    }
  end
end
