defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{CLI, GroupReporter}

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "runs multiple workflow paths as one managed group" do
    parent = self()
    paths = ["tmp/life-os/WORKFLOW.md", "tmp/next-forge/WORKFLOW.md"]
    expanded_paths = Enum.map(paths, &Path.expand/1)
    logs_root = Path.expand("tmp/symphony-logs")

    deps =
      group_deps(fn workflow_paths, group_logs_root, server_port, server_host ->
        send(parent, {:group_started, workflow_paths, group_logs_root, server_port, server_host})
        :ok
      end)

    assert :ok =
             CLI.evaluate(
               [
                 @ack_flag,
                 "--logs-root",
                 "tmp/symphony-logs",
                 "--host",
                 "0.0.0.0",
                 "--port",
                 "4001"
                 | paths
               ],
               deps
             )

    assert_received {:group_started, ^expanded_paths, ^logs_root, 4001, "0.0.0.0"}
  end

  test "defaults grouped dashboard host to loopback" do
    parent = self()
    paths = ["tmp/life-os/WORKFLOW.md", "tmp/next-forge/WORKFLOW.md"]

    deps =
      group_deps(fn _workflow_paths, _logs_root, _server_port, server_host ->
        send(parent, {:group_host, server_host})
        :ok
      end)

    assert :ok =
             CLI.evaluate([@ack_flag, "--logs-root", "tmp/logs", "--port", "4001" | paths], deps)

    assert_received {:group_host, "127.0.0.1"}
  end

  test "rejects missing and duplicate workflow paths before starting a group" do
    parent = self()

    deps =
      group_deps(
        fn _workflow_paths, _logs_root, _server_port, _server_host ->
          send(parent, :group_started)
          :ok
        end,
        file_regular?: fn path -> !String.ends_with?(path, "missing/WORKFLOW.md") end
      )

    assert {:error, missing_message} =
             CLI.evaluate(
               [
                 @ack_flag,
                 "--logs-root",
                 "tmp/logs",
                 "--port",
                 "4001",
                 "tmp/valid/WORKFLOW.md",
                 "tmp/missing/WORKFLOW.md"
               ],
               deps
             )

    assert missing_message =~ "Workflow file not found:"

    assert {:error, duplicate_message} =
             CLI.evaluate(
               [
                 @ack_flag,
                 "--logs-root",
                 "tmp/logs",
                 "--port",
                 "4001",
                 "tmp/valid/WORKFLOW.md",
                 "tmp/valid/WORKFLOW.md"
               ],
               deps
             )

    assert duplicate_message =~ "Workflow paths must be unique"
    refute_received :group_started
  end

  test "requires one logs root and one shared port for workflow groups" do
    deps = group_deps(fn _workflow_paths, _logs_root, _server_port, _server_host -> :ok end)
    paths = ["tmp/life-os/WORKFLOW.md", "tmp/next-forge/WORKFLOW.md"]

    assert {:error, logs_message} = CLI.evaluate([@ack_flag | paths], deps)
    assert logs_message =~ "--logs-root is required"

    assert {:error, port_message} = CLI.evaluate([@ack_flag, "--logs-root", "tmp/logs" | paths], deps)

    assert port_message =~ "--port is required"
  end

  test "builds isolated child commands and stops siblings when one child exits" do
    parent = self()
    first_workflow_path = Path.expand("tmp/life-os/WORKFLOW.md")
    second_workflow_path = Path.expand("tmp/next-forge/WORKFLOW.md")
    workflow_paths = [first_workflow_path, second_workflow_path]
    logs_root = Path.expand("tmp/symphony-logs")

    runtime_deps = %{
      executable_path: fn -> {:ok, "/tmp/symphony"} end,
      open_port: fn executable, args, env ->
        port = make_ref()
        send(parent, {:child_opened, port, executable, args, env})
        {:ok, port}
      end,
      close_port: fn port -> send(parent, {:child_closed, port}) end,
      start_dashboard: fn port, host ->
        send(parent, {:dashboard_started, port, host})
        {:ok, self()}
      end,
      put_snapshot: fn label, path, payload -> send(parent, {:snapshot, label, path, payload}) end,
      install_shutdown_handlers: fn _shutdown -> fn -> :ok end end,
      write_stderr: fn output -> send(parent, {:stderr, IO.iodata_to_binary(output)}) end
    }

    task =
      Task.async(fn ->
        CLI.supervise_workflows(workflow_paths, logs_root, 4001, "0.0.0.0", runtime_deps)
      end)

    assert_receive {:dashboard_started, 4001, "0.0.0.0"}
    assert_receive {:child_opened, first_port, "/tmp/symphony", first_args, first_env}
    assert_receive {:child_opened, second_port, "/tmp/symphony", second_args, second_env}

    assert [@ack_flag, "--logs-root", first_logs_root, ^first_workflow_path] = first_args
    assert [@ack_flag, "--logs-root", second_logs_root, ^second_workflow_path] = second_args
    refute first_logs_root == second_logs_root
    assert first_env == [{~c"SYMPHONY_MANAGED_CHILD", ~c"1"}]
    assert second_env == first_env

    payload = %{counts: %{running: 0}}
    send(task.pid, {first_port, {:data, {:eol, GroupReporter.encode_snapshot(payload)}}})
    assert_receive {:snapshot, _label, ^first_workflow_path, ^payload}

    send(task.pid, {first_port, {:exit_status, 17}})

    assert {:error, message} = Task.await(task)
    assert message =~ first_workflow_path
    assert message =~ "status 17"
    assert_received {:child_closed, ^second_port}
    refute_received {:child_closed, ^first_port}
  end

  test "reports child startup failures and closes children already started" do
    parent = self()
    workflow_paths = [Path.expand("tmp/life-os/WORKFLOW.md"), Path.expand("tmp/next-forge/WORKFLOW.md")]

    runtime_deps = %{
      executable_path: fn -> {:ok, "/tmp/symphony"} end,
      open_port: fn _executable, args, _env ->
        if List.last(args) == List.first(workflow_paths) do
          port = make_ref()
          send(parent, {:first_child, port})
          {:ok, port}
        else
          {:error, :boom}
        end
      end,
      close_port: fn port -> send(parent, {:child_closed, port}) end,
      start_dashboard: fn _port, _host -> {:ok, self()} end,
      put_snapshot: fn _label, _path, _payload -> :ok end,
      install_shutdown_handlers: fn _shutdown -> fn -> :ok end end,
      write_stderr: fn _output -> :ok end
    }

    assert {:error, message} =
             CLI.supervise_workflows(workflow_paths, Path.expand("tmp/logs"), 4001, runtime_deps)

    assert message =~ "Failed to start Symphony"
    assert_receive {:first_child, first_port}
    assert_received {:child_closed, ^first_port}
  end

  defp group_deps(run_workflow_group, overrides \\ []) do
    Map.merge(
      %{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        run_workflow_group: run_workflow_group
      },
      Map.new(overrides)
    )
  end
end
