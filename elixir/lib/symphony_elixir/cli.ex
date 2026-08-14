defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with one or more explicit WORKFLOW.md paths.
  """

  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @acknowledgement_argument "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result()),
          run_workflow_group: ([String.t()], String.t() -> :ok | {:error, String.t()})
        }
  @type workflow_group_deps :: %{
          executable_path: (-> {:ok, String.t()} | {:error, String.t()}),
          open_port: (String.t(), [String.t()], [{charlist(), charlist()}] -> {:ok, term()} | {:error, term()}),
          close_port: (term() -> term()),
          install_shutdown_handlers: ((-> :ok) -> (-> term())),
          write_stderr: (IO.chardata() -> term())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    main(args, fn -> Application.ensure_all_started(:symphony_elixir) end)
  end

  @doc false
  @spec main([String.t()], (-> ensure_started_result())) :: no_return()
  def main(args, ensure_all_started) do
    case evaluate(args, runtime_deps(ensure_all_started)) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      {opts, workflow_paths, []} when length(workflow_paths) > 1 ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- reject_shared_server_port(opts),
             {:ok, logs_root} <- require_group_logs_root(opts),
             {:ok, expanded_paths} <- validate_workflow_paths(workflow_paths, deps) do
          deps.run_workflow_group.(expanded_paths, logs_root)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @doc false
  @spec supervise_workflows([Path.t()], Path.t()) :: {:error, String.t()}
  def supervise_workflows(workflow_paths, logs_root) do
    supervise_workflows(workflow_paths, logs_root, runtime_workflow_group_deps())
  end

  @doc false
  @spec supervise_workflows([Path.t()], Path.t(), workflow_group_deps()) :: {:error, String.t()}
  def supervise_workflows(workflow_paths, logs_root, deps)
      when is_list(workflow_paths) and is_binary(logs_root) do
    with {:ok, executable} <- deps.executable_path.(),
         {:ok, children} <- start_workflow_children(workflow_paths, logs_root, executable, deps) do
      remove_shutdown_handlers =
        deps.install_shutdown_handlers.(fn -> close_workflow_children(children, nil, deps) end)

      try do
        await_workflow_child(children, deps)
      after
        remove_shutdown_handlers.()
      end
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md ...]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps(ensure_all_started \\ fn -> Application.ensure_all_started(:symphony_elixir) end) do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: ensure_all_started,
      run_workflow_group: &supervise_workflows/2
    }
  end

  defp runtime_workflow_group_deps do
    %{
      executable_path: &current_executable_path/0,
      open_port: &open_workflow_port/3,
      close_port: &close_workflow_port/1,
      install_shutdown_handlers: &install_shutdown_handlers/1,
      write_stderr: &IO.write(:stderr, &1)
    }
  end

  defp reject_shared_server_port(opts) do
    if Keyword.has_key?(opts, :port) do
      {:error, "--port cannot be shared by multiple workflows; configure server.port in each WORKFLOW.md"}
    else
      :ok
    end
  end

  defp require_group_logs_root(opts) do
    case logs_root_option(opts) do
      {:ok, nil} -> {:error, "--logs-root is required when running multiple workflows"}
      {:ok, logs_root} -> {:ok, Path.expand(logs_root)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_workflow_paths(workflow_paths, deps) do
    expanded_paths = Enum.map(workflow_paths, &Path.expand/1)

    cond do
      length(Enum.uniq(expanded_paths)) != length(expanded_paths) ->
        {:error, "Workflow paths must be unique"}

      missing_path = Enum.find(expanded_paths, &(not deps.file_regular?.(&1))) ->
        {:error, "Workflow file not found: #{missing_path}"}

      true ->
        {:ok, expanded_paths}
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case logs_root_option(opts) do
      {:ok, nil} ->
        :ok

      {:ok, logs_root} ->
        :ok = deps.set_logs_root.(Path.expand(logs_root))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp logs_root_option(opts) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        {:ok, nil}

      values ->
        case values |> List.last() |> String.trim() do
          "" -> {:error, usage_message()}
          logs_root -> {:ok, logs_root}
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp start_workflow_children(workflow_paths, logs_root, executable, deps) do
    Enum.reduce_while(workflow_paths, {:ok, %{}}, fn workflow_path, {:ok, children} ->
      label = workflow_label(workflow_path)
      child_logs_root = Path.join(logs_root, label)
      args = [@acknowledgement_argument, "--logs-root", child_logs_root, workflow_path]
      env = [{~c"SYMPHONY_MANAGED_CHILD", ~c"1"}]

      case deps.open_port.(executable, args, env) do
        {:ok, port} ->
          deps.write_stderr.("Started Symphony workflow=#{workflow_path} logs=#{LogFile.default_log_file(child_logs_root)}\n")

          child = %{label: label, workflow_path: workflow_path}
          {:cont, {:ok, Map.put(children, port, child)}}

        {:error, reason} ->
          close_workflow_children(children, nil, deps)
          {:halt, {:error, "Failed to start Symphony with workflow #{workflow_path}: #{inspect(reason)}"}}
      end
    end)
  end

  defp await_workflow_child(children, deps) do
    receive do
      {port, {:data, data}} when is_map_key(children, port) ->
        %{label: label} = Map.fetch!(children, port)
        deps.write_stderr.(["[", label, "] ", data])
        await_workflow_child(children, deps)

      {port, {:exit_status, status}} when is_map_key(children, port) ->
        %{workflow_path: workflow_path} = Map.fetch!(children, port)
        close_workflow_children(children, port, deps)
        {:error, "Symphony workflow #{workflow_path} exited with status #{status}"}

      {:EXIT, port, reason} when is_map_key(children, port) ->
        %{workflow_path: workflow_path} = Map.fetch!(children, port)
        close_workflow_children(children, port, deps)
        {:error, "Symphony workflow #{workflow_path} exited: #{inspect(reason)}"}

      _other ->
        await_workflow_child(children, deps)
    end
  end

  defp close_workflow_children(children, excluded_port, deps) do
    Enum.each(children, fn
      {port, _child} when port == excluded_port -> :ok
      {port, _child} -> deps.close_port.(port)
    end)
  end

  defp workflow_label(workflow_path) do
    # ponytail: the path itself is the unique workflow identity; no registry needed.
    path_hash = workflow_path |> :erlang.md5() |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "#{Path.basename(Path.dirname(workflow_path))}-#{path_hash}"
  end

  defp current_executable_path do
    case System.get_env("__BURRITO_BIN_PATH") do
      path when is_binary(path) and path != "" ->
        {:ok, Path.expand(path)}

      _ ->
        case :escript.script_name() do
          path when is_list(path) and path != [] -> {:ok, path |> List.to_string() |> Path.expand()}
          _ -> {:error, "Unable to resolve the current Symphony executable"}
        end
    end
  end

  defp open_workflow_port(executable, args, env) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(args, &String.to_charlist/1),
          env: env
        ]
      )

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  defp close_workflow_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)])
      nil -> :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp install_shutdown_handlers(shutdown) do
    registrations =
      case System.trap_signal(:sigterm, shutdown) do
        {:ok, id} -> [{:sigterm, id}]
        {:error, _reason} -> []
      end

    fn -> Enum.each(registrations, fn {signal, id} -> System.untrap_signal(signal, id) end) end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
