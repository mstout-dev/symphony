defmodule SymphonyElixir.WorkflowGroupDashboard do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.HttpServer
  alias SymphonyElixirWeb.ObservabilityPubSub

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec start_supervisor(non_neg_integer()) :: Supervisor.on_start()
  def start_supervisor(port) when is_integer(port) and port >= 0 do
    # ponytail: the group needs only one state process and the existing web server.
    pubsub =
      if Process.whereis(SymphonyElixir.PubSub) do
        []
      else
        [{Phoenix.PubSub, name: SymphonyElixir.PubSub}]
      end

    Supervisor.start_link(
      pubsub ++
        [
          __MODULE__,
          {HttpServer, port: port, host: "127.0.0.1", group_dashboard: __MODULE__}
        ],
      strategy: :one_for_one
    )
  end

  @spec put_snapshot(String.t(), Path.t(), map(), GenServer.name()) :: :ok
  def put_snapshot(project_id, workflow_path, payload, server \\ __MODULE__) do
    GenServer.cast(server, {:put_snapshot, project_id, workflow_path, payload})
  end

  @spec state_payload(GenServer.name()) :: map()
  def state_payload(server \\ __MODULE__), do: GenServer.call(server, :state_payload)

  @spec issue_payload(String.t(), GenServer.name()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, server \\ __MODULE__) do
    GenServer.call(server, {:issue_payload, issue_identifier})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:put_snapshot, project_id, workflow_path, payload}, state) do
    project = %{
      id: project_id,
      name: workflow_path |> Path.dirname() |> Path.basename(),
      workflow_path: workflow_path,
      state: payload
    }

    ObservabilityPubSub.broadcast_update()
    {:noreply, Map.put(state, project_id, project)}
  end

  @impl true
  def handle_call(:state_payload, _from, state) do
    projects = state |> Map.values() |> Enum.sort_by(& &1.name)
    {:reply, %{projects: projects}, state}
  end

  def handle_call({:issue_payload, issue_identifier}, _from, state) do
    result =
      Enum.find_value(state, {:error, :issue_not_found}, fn {_id, project} ->
        case find_issue(project.state, issue_identifier) do
          {status, entry} when not is_nil(entry) ->
            {:ok, %{project: project.name, status: status, issue: entry}}

          _ ->
            nil
        end
      end)

    {:reply, result, state}
  end

  defp find_issue(%{running: running, retrying: retrying, blocked: blocked}, identifier) do
    cond do
      entry = Enum.find(running, &(&1.issue_identifier == identifier)) -> {"running", entry}
      entry = Enum.find(retrying, &(&1.issue_identifier == identifier)) -> {"retrying", entry}
      entry = Enum.find(blocked, &(&1.issue_identifier == identifier)) -> {"blocked", entry}
      true -> {nil, nil}
    end
  end

  defp find_issue(_payload, _identifier), do: {nil, nil}
end
