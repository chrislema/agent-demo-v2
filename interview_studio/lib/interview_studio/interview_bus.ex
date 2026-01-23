defmodule InterviewStudio.InterviewBus do
  @moduledoc """
  The central signal bus for interview sessions.
  All agents subscribe to and publish signals through this bus.

  Uses Jido.Signal.Bus for pub/sub with:
  - Fan-out to multiple subscribers
  - Signal history for causality tracking
  - Pattern-based subscriptions
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Publish a signal to all subscribers.
  """
  def publish(signal, opts \\ []) do
    bus = Keyword.get(opts, :bus, __MODULE__)
    GenServer.cast(bus, {:publish, signal})
  end

  @doc """
  Subscribe to signals matching a pattern.
  Pattern can be:
  - "interview.utterance.*" - all utterances
  - "observer.**" - all observer signals
  - "interview.phase.entered" - specific signal type

  For direct agent-to-agent messaging, agents can also subscribe with their name:
  - subscribe("direct.probe_coach") - receive signals targeted at probe_coach
  """
  def subscribe(pattern, opts \\ []) do
    bus = Keyword.get(opts, :bus, __MODULE__)
    GenServer.call(bus, {:subscribe, pattern, self()})
  end

  @doc """
  Subscribe to direct messages for a specific agent.
  This is a convenience wrapper for subscribing to targeted signals.
  """
  def subscribe_direct(agent_name, opts \\ []) do
    subscribe("direct.#{agent_name}", opts)
  end

  @doc """
  Unsubscribe from a pattern.
  """
  def unsubscribe(pattern, opts \\ []) do
    bus = Keyword.get(opts, :bus, __MODULE__)
    GenServer.call(bus, {:unsubscribe, pattern, self()})
  end

  @doc """
  Get signal history, optionally filtered by pattern and time range.
  """
  def history(opts \\ []) do
    bus = Keyword.get(opts, :bus, __MODULE__)
    GenServer.call(bus, {:history, opts})
  end

  @doc """
  Clear all subscriptions and history (for testing/reset).
  """
  def reset(opts \\ []) do
    bus = Keyword.get(opts, :bus, __MODULE__)
    GenServer.call(bus, :reset)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      subscriptions: %{},  # pattern => [pid, ...]
      history: [],         # [{signal, timestamp}, ...]
      history_limit: 1000  # max signals to keep
    }
    Logger.debug("[InterviewBus] Started")
    {:ok, state}
  end

  @impl true
  def handle_cast({:publish, signal}, state) do
    # Check if this is a targeted (direct) signal
    target = get_signal_target(signal)

    if target do
      Logger.debug("[InterviewBus] Publishing DIRECT signal: #{signal.type} -> #{target}")
    else
      Logger.debug("[InterviewBus] Publishing BROADCAST signal: #{signal.type}")
    end

    # Record in history
    entry = {signal, DateTime.utc_now()}
    history = [entry | state.history] |> Enum.take(state.history_limit)

    # Determine which patterns to match
    patterns_to_match = if target do
      # For targeted signals, match both:
      # 1. The normal type pattern (for debug/monitoring)
      # 2. The direct.{agent_name} pattern (for the target agent)
      fn {pattern, _pids} ->
        matches_pattern?(signal.type, pattern) or
        matches_pattern?("direct.#{target}", pattern)
      end
    else
      # Broadcast: match only type pattern
      fn {pattern, _pids} -> matches_pattern?(signal.type, pattern) end
    end

    # Fan out to matching subscribers
    state.subscriptions
    |> Enum.filter(patterns_to_match)
    |> Enum.flat_map(fn {_pattern, pids} -> pids end)
    |> Enum.uniq()
    |> Enum.each(fn pid ->
      send(pid, {:signal, signal})
    end)

    {:noreply, %{state | history: history}}
  end

  # Extract target from signal (supports both data.target and extensions.target)
  defp get_signal_target(%{data: %{target: target}}) when is_binary(target), do: target
  defp get_signal_target(%{extensions: %{target: target}}) when is_binary(target), do: target
  defp get_signal_target(_), do: nil

  @impl true
  def handle_call({:subscribe, pattern, pid}, _from, state) do
    Logger.debug("[InterviewBus] Subscribing #{inspect(pid)} to #{pattern}")

    # Monitor the subscriber so we can clean up if they die
    Process.monitor(pid)

    subscriptions = Map.update(
      state.subscriptions,
      pattern,
      [pid],
      fn pids -> [pid | pids] |> Enum.uniq() end
    )

    {:reply, :ok, %{state | subscriptions: subscriptions}}
  end

  @impl true
  def handle_call({:unsubscribe, pattern, pid}, _from, state) do
    subscriptions = Map.update(
      state.subscriptions,
      pattern,
      [],
      fn pids -> Enum.reject(pids, &(&1 == pid)) end
    )

    {:reply, :ok, %{state | subscriptions: subscriptions}}
  end

  @impl true
  def handle_call({:history, opts}, _from, state) do
    pattern = Keyword.get(opts, :pattern)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, 100)

    result = state.history
    |> Enum.filter(fn {signal, timestamp} ->
      (is_nil(pattern) or matches_pattern?(signal.type, pattern)) and
      (is_nil(since) or DateTime.compare(timestamp, since) == :gt)
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {signal, _ts} -> signal end)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{subscriptions: %{}, history: [], history_limit: 1000}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up subscriptions for dead processes
    subscriptions = state.subscriptions
    |> Enum.map(fn {pattern, pids} ->
      {pattern, Enum.reject(pids, &(&1 == pid))}
    end)
    |> Enum.into(%{})

    {:noreply, %{state | subscriptions: subscriptions}}
  end

  # Pattern matching helpers

  defp matches_pattern?(type, pattern) do
    type_parts = String.split(type, ".")
    pattern_parts = String.split(pattern, ".")

    do_match?(type_parts, pattern_parts)
  end

  defp do_match?([], []), do: true
  defp do_match?(_, ["**"]), do: true
  defp do_match?([_h | t1], ["*" | t2]), do: do_match?(t1, t2)
  defp do_match?([h | t1], [h | t2]), do: do_match?(t1, t2)
  defp do_match?(_, _), do: false
end
