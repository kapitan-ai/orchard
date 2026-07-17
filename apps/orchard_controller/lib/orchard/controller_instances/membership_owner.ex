defmodule Orchard.ControllerInstances.MembershipOwner do
  @moduledoc """
  Owns the local Controller membership heartbeat and capability evidence.

  The first complete membership and capability tuple is published synchronously
  during `init/1`, so identity, custody, schema, or configuration failures stop
  Controller startup instead of leaving a live Controller whose dispatch-capacity
  cutover evidence never appears.

  Database availability is not such a failure. A Controller whose Postgres is
  still starting must boot and serve, so publication failures are classified
  from their structured shape before they are reduced to a stable code: only
  `DBConnection` availability and pool faults, an unregistered Repo, and the
  allowlisted transient PostgreSQL SQLSTATEs retry on the fixed interval with
  bounded logging.

  Neither is uninitialized node trust. `orchardctl nodes trust init` is a
  leader-gated operator step run against an already-serving Controller, so a
  Controller that has no trust material yet must boot and wait for it rather
  than stop and make trust unreachable forever. Every other failure — identity
  mismatch, custody, schema, authorization, or unrecognized — fails closed.

  After the first publication has succeeded, failing closed cannot mean exiting:
  a `:permanent` child that keeps stopping would exhaust the supervisor's restart
  intensity and take the serving Controller down with it. A post-boot fatal
  failure therefore logs once, cancels the heartbeat, leaves the last durable
  evidence untouched, and holds an explicit terminal state that ignores queued
  heartbeats until an operator remediates and restarts the Controller.
  """

  use GenServer

  require Logger

  alias Orchard.ControllerInstances

  @heartbeat_interval_ms 10_000
  @failure_log_interval_ms 300_000
  @dispatch_capacity_contract_version 1
  @dispatch_capacity_consumers_ready false

  # SQLSTATE class 08 is connection exception. 57P01/57P02/57P03 are admin
  # shutdown, crash shutdown, and cannot-connect-now; 53300 is too-many-connections.
  # 40001/40P01/57014 are serialization failure, deadlock, and query cancellation:
  # the publication is one atomic row-locked transaction, so re-running it on the
  # next beat is the correct response to losing a lock race with an admission.
  @retryable_sqlstate_class "08"
  @retryable_sqlstates ~w(57P01 57P02 57P03 53300 40001 40P01 57014)

  @type failure :: %{
          reason: atom(),
          diagnostic: String.t(),
          logged_at: DateTime.t(),
          suppressed: non_neg_integer()
        }

  @type state :: %{
          opts: keyword(),
          timer_ref: term(),
          failure: failure() | nil,
          fatal: atom() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the fixed Controller membership heartbeat interval.
  """
  @spec heartbeat_interval_ms() :: 10_000
  def heartbeat_interval_ms, do: @heartbeat_interval_ms

  @impl true
  def init(opts) do
    observed_at = now(opts)

    case attempt_publish(opts, observed_at) do
      {:ok, _instance} ->
        {:ok, %{opts: opts, timer_ref: start_timer(), failure: nil, fatal: nil}}

      {:error, reason} ->
        init_failure(opts, reason, observed_at)
    end
  end

  defp init_failure(opts, reason, observed_at) do
    if retryable?(reason) do
      {:ok,
       %{
         opts: opts,
         timer_ref: start_timer(),
         failure: record_failure(nil, reason, observed_at),
         fatal: nil
       }}
    else
      {:stop, fatal_reason(reason)}
    end
  end

  @impl true
  def handle_info(:heartbeat, %{fatal: fatal} = state) when not is_nil(fatal) do
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    observed_at = now(state.opts)

    case attempt_publish(state.opts, observed_at) do
      {:ok, _instance} ->
        log_recovery(state.failure)
        {:noreply, %{state | failure: nil}}

      {:error, reason} ->
        heartbeat_failure(state, reason, observed_at)
    end
  end

  defp heartbeat_failure(state, reason, observed_at) do
    if retryable?(reason) do
      {:noreply, %{state | failure: record_failure(state.failure, reason, observed_at)}}
    else
      {:noreply, enter_terminal_fatal(state, reason)}
    end
  end

  defp enter_terminal_fatal(state, reason) do
    {:ok, :cancel} = :timer.cancel(state.timer_ref)
    %{state | timer_ref: nil, failure: nil, fatal: fatal_reason(reason)}
  end

  defp fatal_reason(reason) do
    sanitized = sanitize_reason(reason)

    Logger.error(
      "Controller membership publication failed permanently; capability evidence cannot be " <>
        "published until the Controller is remediated and restarted " <>
        "(reason=#{sanitized} #{diagnostic(reason)})"
    )

    sanitized
  end

  # The stop reason stays a stable code, so the diagnostic is the only place an
  # operator learns which fault occurred. It carries the failure class, the
  # SQLSTATE, and the server's own message; exception messages elsewhere may
  # embed custody paths, queries, or connection strings and stay out.
  defp diagnostic({:heartbeat_publish_exit, {reason, {module, function, _args}}})
       when is_atom(module) and is_atom(function) do
    "class=exit callee=#{inspect(module)}.#{function}" <> exit_reason(reason)
  end

  defp diagnostic({:heartbeat_publish_exit, reason}), do: "class=exit" <> exit_reason(reason)

  defp diagnostic({_tag, %Postgrex.Error{postgres: %{pg_code: sqlstate} = postgres}})
       when is_binary(sqlstate) do
    "class=Postgrex.Error sqlstate=#{sqlstate} detail=#{inspect(Map.get(postgres, :message))}"
  end

  defp diagnostic({_tag, exception}) when is_exception(exception) do
    "class=#{inspect(exception.__struct__)}"
  end

  defp diagnostic({_tag, detail}) when is_atom(detail), do: "class=#{detail}"

  defp diagnostic(%Ecto.Changeset{} = changeset) do
    fields = changeset |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    "class=Ecto.Changeset detail=#{inspect(fields)}"
  end

  defp diagnostic(_reason), do: "class=none"

  # Exit terms carry arbitrary payloads, so only an atom reason leaves the process.
  defp exit_reason(reason) when is_atom(reason), do: " reason=#{reason}"
  defp exit_reason({reason, _detail}) when is_atom(reason), do: " reason=#{reason}"
  defp exit_reason(_reason), do: ""

  defp retryable?(:node_trust_not_initialized), do: true

  defp retryable?({:heartbeat_publish_failed, :repo_unavailable}), do: true

  defp retryable?({:heartbeat_publish_failed, %DBConnection.ConnectionError{}}), do: true

  defp retryable?({:heartbeat_publish_failed, %Postgrex.Error{postgres: %{pg_code: sqlstate}}})
       when is_binary(sqlstate) do
    String.starts_with?(sqlstate, @retryable_sqlstate_class) or sqlstate in @retryable_sqlstates
  end

  defp retryable?({:heartbeat_publish_exit, {_reason, {DBConnection.Holder, :checkout, _args}}}),
    do: true

  defp retryable?(_reason), do: false

  defp record_failure(nil, reason, observed_at) do
    log_failure(sanitize_reason(reason), diagnostic(reason), 0, observed_at)
  end

  defp record_failure(failure, reason, observed_at) do
    sanitized = sanitize_reason(reason)
    diagnostic = diagnostic(reason)

    cond do
      {sanitized, diagnostic} != {failure.reason, failure.diagnostic} ->
        log_failure(sanitized, diagnostic, 0, observed_at)

      DateTime.diff(observed_at, failure.logged_at, :millisecond) >= @failure_log_interval_ms ->
        log_failure(sanitized, diagnostic, failure.suppressed, observed_at)

      true ->
        %{failure | suppressed: failure.suppressed + 1}
    end
  end

  defp log_failure(reason, diagnostic, suppressed, observed_at) do
    Logger.warning(
      "Controller membership heartbeat failed; capability evidence remains stale " <>
        "(reason=#{reason} #{diagnostic} suppressed_attempts=#{suppressed})"
    )

    %{reason: reason, diagnostic: diagnostic, logged_at: observed_at, suppressed: 0}
  end

  defp log_recovery(nil), do: :ok

  defp log_recovery(%{reason: reason}) do
    Logger.info(
      "Controller membership heartbeat recovered; capability evidence is fresh " <>
        "(previous_reason=#{reason})"
    )
  end

  defp sanitize_reason(%Ecto.Changeset{}), do: :beam_controller_instance_heartbeat_invalid
  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason({tag, _detail}) when is_atom(tag), do: tag
  defp sanitize_reason(_reason), do: :beam_controller_membership_heartbeat_failed

  defp attempt_publish(opts, observed_at) do
    publish(opts, observed_at)
  rescue
    exception in [
      ArgumentError,
      DBConnection.ConnectionError,
      Ecto.QueryError,
      Ecto.StaleEntryError,
      File.Error,
      Postgrex.Error,
      RuntimeError
    ] ->
      {:error, {:heartbeat_publish_failed, classify(exception, __STACKTRACE__)}}
  catch
    :exit, reason -> {:error, {:heartbeat_publish_exit, reason}}
  end

  # `Ecto.Repo.Registry.lookup/1` raises RuntimeError or ArgumentError while
  # the Repo is between crash and restart, so the raising frame is the only
  # structured evidence separating repo availability from a publication defect.
  defp classify(exception, stacktrace) do
    if Enum.any?(stacktrace, &match?({Ecto.Repo.Registry, :lookup, 1, _location}, &1)) do
      :repo_unavailable
    else
      exception
    end
  end

  defp publish(opts, observed_at) do
    publisher(opts).(opts, %{
      last_seen_at: observed_at,
      software_version: software_version(),
      dispatch_capacity_contract_version: @dispatch_capacity_contract_version,
      dispatch_capacity_consumers_ready: @dispatch_capacity_consumers_ready,
      dispatch_capacity_capability_observed_at: observed_at
    })
  end

  defp start_timer do
    {:ok, timer_ref} = :timer.send_interval(@heartbeat_interval_ms, :heartbeat)
    timer_ref
  end

  defp now(opts) do
    opts
    |> Keyword.get(:clock, &DateTime.utc_now/0)
    |> then(fn clock -> clock.() end)
  end

  defp software_version do
    :orchard_controller
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp publisher(opts) do
    Keyword.get(opts, :publisher, &ControllerInstances.heartbeat_local/2)
  end
end
