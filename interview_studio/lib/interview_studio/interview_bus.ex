defmodule InterviewStudio.InterviewBus do
  @moduledoc """
  The central signal bus for interview sessions.
  All agents subscribe to and publish signals through this bus.

  Wraps Jido.Signal.Bus for core pub/sub while preserving:
  - Same public API (publish/2, subscribe/2, etc.)
  - Target-based direct routing (signals with data.target)
  - Signal history for causality tracking
  - Pattern-based subscriptions with * and ** wildcards
  """

  use GenServer
  require Logger

  @bus_name :interview_signal_bus

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
  Subscribe an explicit PID to signals matching a pattern.
  Used when the subscribing process is different from the caller
  (e.g., subscribing an AgentServer process from a start_link wrapper).
  """
  def subscribe_pid(pattern, pid, opts \\ []) do
    bus = Keyword.get(opts, :bus, __MODULE__)
    GenServer.call(bus, {:subscribe, pattern, pid})
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
    # Start the underlying Jido.Signal.Bus
    case Jido.Signal.Bus.start_link(name: @bus_name) do
      {:ok, bus_pid} ->
        Process.monitor(bus_pid)

        state = %{
          bus_pid: bus_pid,
          # {pattern, pid} => subscription_id from Jido.Signal.Bus
          subscription_ids: %{},
          # Direct pattern subscribers: "direct.agent_name" => [{pid, sub_id}]
          direct_subscriptions: %{},
          history: [],
          history_limit: 1000
        }

        Logger.debug("[InterviewBus] Started (backed by Jido.Signal.Bus)")
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
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

    # Publish through Jido.Signal.Bus (takes a list)
    Jido.Signal.Bus.publish(@bus_name, [signal])

    # Handle target routing: if the signal has a target, also publish on
    # the "direct.{target}" path so agents subscribed to direct messages receive it
    if target do
      direct_signal = %{signal | type: "direct.#{target}"}
      Jido.Signal.Bus.publish(@bus_name, [direct_signal])
    end

    {:noreply, %{state | history: history}}
  end

  @impl true
  def handle_call({:subscribe, pattern, pid}, _from, state) do
    Logger.debug("[InterviewBus] Subscribing #{inspect(pid)} to #{pattern}")

    # Monitor the subscriber so we can clean up if they die
    Process.monitor(pid)

    # Subscribe through Jido.Signal.Bus with the caller's pid as dispatch target
    case Jido.Signal.Bus.subscribe(@bus_name, pattern,
           dispatch: {:pid, target: pid, delivery_mode: :async}
         ) do
      {:ok, sub_id} ->
        subscription_ids = Map.put(state.subscription_ids, {pattern, pid}, sub_id)
        {:reply, :ok, %{state | subscription_ids: subscription_ids}}

      {:error, reason} ->
        Logger.warning("[InterviewBus] Failed to subscribe #{inspect(pid)} to #{pattern}: #{inspect(reason)}")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, pattern, pid}, _from, state) do
    key = {pattern, pid}

    case Map.pop(state.subscription_ids, key) do
      {nil, _} ->
        {:reply, :ok, state}

      {sub_id, remaining} ->
        Jido.Signal.Bus.unsubscribe(@bus_name, sub_id)
        {:reply, :ok, %{state | subscription_ids: remaining}}
    end
  end

  @impl true
  def handle_call({:history, opts}, _from, state) do
    pattern = Keyword.get(opts, :pattern)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, 100)

    result =
      state.history
      |> Enum.filter(fn {signal, timestamp} ->
        (is_nil(pattern) or matches_pattern?(signal.type, pattern)) and
          (is_nil(since) or DateTime.compare(timestamp, since) == :gt)
      end)
      |> Enum.take(limit)
      |> Enum.map(fn {signal, _ts} -> signal end)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Unsubscribe all from Jido.Signal.Bus
    Enum.each(state.subscription_ids, fn {_key, sub_id} ->
      Jido.Signal.Bus.unsubscribe(@bus_name, sub_id)
    end)

    {:reply, :ok, %{state | subscription_ids: %{}, history: []}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up subscriptions for dead processes
    {to_remove, to_keep} =
      Map.split_with(state.subscription_ids, fn {{_pattern, sub_pid}, _sub_id} ->
        sub_pid == pid
      end)

    # Unsubscribe dead process from Jido.Signal.Bus
    Enum.each(to_remove, fn {_key, sub_id} ->
      Jido.Signal.Bus.unsubscribe(@bus_name, sub_id)
    end)

    {:noreply, %{state | subscription_ids: to_keep}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Extract target from signal (supports both data.target and extensions.target)
  defp get_signal_target(%{data: %{target: target}}) when is_binary(target), do: target
  defp get_signal_target(%{extensions: %{target: target}}) when is_binary(target), do: target
  defp get_signal_target(_), do: nil

  # Pattern matching helpers (kept for history filtering)
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
