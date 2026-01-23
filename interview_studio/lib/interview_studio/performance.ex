defmodule InterviewStudio.Performance do
  @moduledoc """
  Performance monitoring and optimization for multi-agent system.

  Phase 7 Implementation:
  - 7.1: Response time tracking (< 5 second target)
  - 7.2: Circuit breakers for agent failure isolation
  - 7.3: Insight caching to reduce redundant LLM calls

  Uses ETS for fast, concurrent access to metrics and cache.
  """

  use GenServer
  require Logger

  @table_name :interview_performance
  @cache_table :interview_insight_cache
  @metrics_table :interview_metrics

  # Circuit breaker thresholds
  @failure_threshold 3          # Failures before circuit opens
  @recovery_timeout_ms 30_000   # 30 seconds before retry
  @cache_ttl_ms 10_000          # 10 second cache TTL

  # Performance targets
  @max_response_time_ms 5_000   # 5 second max response time

  defstruct [
    :started_at,
    circuit_states: %{}
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record the start of an operation for timing.
  Returns an operation ID to use with `record_end/2`.
  """
  def record_start(operation_type, metadata \\ %{}) do
    op_id = generate_op_id()
    :ets.insert(@table_name, {op_id, operation_type, System.monotonic_time(:millisecond), metadata})
    op_id
  end

  @doc """
  Record the end of an operation and compute duration.
  Returns {:ok, duration_ms} or {:error, :not_found}
  """
  def record_end(op_id, result \\ :success) do
    end_time = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, op_id) do
      [{^op_id, operation_type, start_time, metadata}] ->
        duration_ms = end_time - start_time
        :ets.delete(@table_name, op_id)

        # Record metric
        record_metric(operation_type, duration_ms, result, metadata)

        # Log warning if over target
        if duration_ms > @max_response_time_ms do
          Logger.warning("[Performance] Operation #{operation_type} exceeded target: #{duration_ms}ms > #{@max_response_time_ms}ms")
        end

        {:ok, duration_ms}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if an agent's circuit breaker is open (too many failures).
  Returns :closed (healthy), :open (failing), or :half_open (testing).
  """
  def circuit_state(agent_name) do
    GenServer.call(__MODULE__, {:circuit_state, agent_name})
  end

  @doc """
  Record an agent failure for circuit breaker.
  """
  def record_failure(agent_name, reason \\ :unknown) do
    GenServer.cast(__MODULE__, {:record_failure, agent_name, reason})
  end

  @doc """
  Record an agent success (resets circuit breaker).
  """
  def record_success(agent_name) do
    GenServer.cast(__MODULE__, {:record_success, agent_name})
  end

  @doc """
  Execute a function with circuit breaker protection.
  Returns {:ok, result}, {:error, :circuit_open}, or {:error, reason}.
  """
  def with_circuit_breaker(agent_name, fun) do
    case circuit_state(agent_name) do
      :open ->
        Logger.debug("[Performance] Circuit open for #{agent_name}, skipping")
        {:error, :circuit_open}

      state when state in [:closed, :half_open] ->
        try do
          result = fun.()
          record_success(agent_name)
          {:ok, result}
        rescue
          e ->
            record_failure(agent_name, e)
            {:error, e}
        catch
          :exit, reason ->
            record_failure(agent_name, reason)
            {:error, reason}
        end
    end
  end

  # Insight Caching (7.3)

  @doc """
  Get cached insights for a session/agent combination.
  Returns {:ok, insights} or :miss.
  """
  def get_cached_insights(session_id, agent_type) do
    cache_key = {session_id, agent_type}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, cache_key) do
      [{^cache_key, insights, timestamp}] when now - timestamp < @cache_ttl_ms ->
        Logger.debug("[Performance] Cache hit for #{agent_type}")
        {:ok, insights}

      _ ->
        :miss
    end
  end

  @doc """
  Cache insights for a session/agent combination.
  """
  def cache_insights(session_id, agent_type, insights) do
    cache_key = {session_id, agent_type}
    timestamp = System.monotonic_time(:millisecond)
    :ets.insert(@cache_table, {cache_key, insights, timestamp})
    :ok
  end

  @doc """
  Invalidate cache for a session (called when new message arrives).
  """
  def invalidate_cache(session_id) do
    # Delete all cache entries for this session
    :ets.match_delete(@cache_table, {{session_id, :_}, :_, :_})
    :ok
  end

  @doc """
  Get performance metrics summary.
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Get recent operation timings.
  """
  def get_recent_timings(limit \\ 10) do
    :ets.tab2list(@metrics_table)
    |> Enum.sort_by(fn {_key, data} -> data.timestamp end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_key, data} -> data end)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables for concurrent access
    :ets.new(@table_name, [:named_table, :public, :set])
    :ets.new(@cache_table, [:named_table, :public, :set])
    :ets.new(@metrics_table, [:named_table, :public, :ordered_set])

    state = %__MODULE__{
      started_at: DateTime.utc_now(),
      circuit_states: %{}
    }

    Logger.info("[Performance] Monitor started")
    {:ok, state}
  end

  @impl true
  def handle_call({:circuit_state, agent_name}, _from, state) do
    circuit = Map.get(state.circuit_states, agent_name, default_circuit())
    now = System.monotonic_time(:millisecond)

    status = cond do
      circuit.failures < @failure_threshold ->
        :closed

      circuit.last_failure_at + @recovery_timeout_ms < now ->
        :half_open

      true ->
        :open
    end

    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = :ets.tab2list(@metrics_table)
    |> Enum.reduce(%{}, fn {_key, data}, acc ->
      op_type = data.operation_type
      current = Map.get(acc, op_type, %{count: 0, total_ms: 0, failures: 0})

      updated = %{
        count: current.count + 1,
        total_ms: current.total_ms + data.duration_ms,
        failures: current.failures + (if data.result == :success, do: 0, else: 1)
      }

      Map.put(acc, op_type, updated)
    end)
    |> Enum.map(fn {op_type, data} ->
      avg = if data.count > 0, do: data.total_ms / data.count, else: 0
      {op_type, Map.put(data, :avg_ms, Float.round(avg, 2))}
    end)
    |> Enum.into(%{})

    {:reply, metrics, state}
  end

  @impl true
  def handle_cast({:record_failure, agent_name, reason}, state) do
    circuit = Map.get(state.circuit_states, agent_name, default_circuit())

    updated_circuit = %{circuit |
      failures: circuit.failures + 1,
      last_failure_at: System.monotonic_time(:millisecond),
      last_reason: reason
    }

    if updated_circuit.failures >= @failure_threshold do
      Logger.warning("[Performance] Circuit OPENED for #{agent_name} after #{updated_circuit.failures} failures")
    end

    new_state = %{state | circuit_states: Map.put(state.circuit_states, agent_name, updated_circuit)}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_success, agent_name}, state) do
    # Reset circuit breaker on success
    circuit = default_circuit()
    new_state = %{state | circuit_states: Map.put(state.circuit_states, agent_name, circuit)}
    {:noreply, new_state}
  end

  # Private functions

  defp default_circuit do
    %{
      failures: 0,
      last_failure_at: 0,
      last_reason: nil
    }
  end

  defp generate_op_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp record_metric(operation_type, duration_ms, result, metadata) do
    key = System.monotonic_time(:nanosecond)
    data = %{
      operation_type: operation_type,
      duration_ms: duration_ms,
      result: result,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }
    :ets.insert(@metrics_table, {key, data})

    # Prune old metrics (keep last 1000)
    all_keys = :ets.select(@metrics_table, [{{:"$1", :_}, [], [:"$1"]}])
    if length(all_keys) > 1000 do
      to_delete = all_keys |> Enum.sort() |> Enum.take(length(all_keys) - 1000)
      Enum.each(to_delete, fn k -> :ets.delete(@metrics_table, k) end)
    end
  end
end
