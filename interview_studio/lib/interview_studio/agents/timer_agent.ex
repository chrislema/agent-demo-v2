defmodule InterviewStudio.Agents.TimerAgent do
  @moduledoc """
  Timer Agent - tracks interview duration and signals time milestones.

  Responsibilities:
  - Track how long the interview has been running
  - Emit signals at key milestones (configurable via priv/config/timer.yaml)
  - Provide context for pacing decisions
  - Suggest wrap-up when interview gets lengthy
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.ConfigLoader

  # Default config (used if YAML file not found)
  @default_config %{
    milestones: [5, 10],
    tick_interval_ms: 60_000,
    wrap_up: %{
      time_threshold_minutes: 10,
      frustration_threshold_minutes: 5
    },
    recommendations: %{
      milestone_5: "Pay attention to time",
      milestone_10: "We should likely wrap up",
      wrap_up: "User shows frustration - consider wrapping up"
    }
  }

  defstruct [
    :session_id,
    :started_at,
    :milestones_hit,
    :timer_ref,
    :current_phase,          # Track current phase for timing recommendations
    :phase_started_at,       # When current phase started
    :frustration_level,      # From Sentiment Agent - affects wrap-up recommendations
    :frustration_wrap_up_emitted,  # Track if we've already suggested wrap-up due to frustration
    :config                  # Loaded configuration
  ]

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  def get_elapsed_minutes(session_id) do
    GenServer.call(via_tuple(session_id), :get_elapsed)
  end

  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  @doc """
  Check if transition to phase is ready based on timing.
  Returns {:ready | :not_ready, rationale}
  """
  def vote_transition(session_id, target_phase) do
    GenServer.call(via_tuple(session_id), {:vote_transition, target_phase})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    now = DateTime.utc_now()

    # Load config from YAML, falling back to defaults
    config = ConfigLoader.load_with_defaults(:timer, @default_config)
    tick_interval = config[:tick_interval_ms] || 60_000

    state = %__MODULE__{
      session_id: session_id,
      started_at: now,
      milestones_hit: [],
      timer_ref: nil,
      current_phase: :opening,
      phase_started_at: now,
      frustration_level: :none,
      frustration_wrap_up_emitted: false,
      config: config
    }

    # CROSS-AGENT: Subscribe to phase changes for timing context
    InterviewBus.subscribe("interview.phase.**")
    # CROSS-AGENT: Subscribe to frustration signals - recommend wrap-up when frustrated
    InterviewBus.subscribe("observer.status.frustration")

    # Start the timer tick
    timer_ref = Process.send_after(self(), :tick, tick_interval)

    Logger.info("[TimerAgent] Started for session #{session_id} with config: milestones=#{inspect(config[:milestones])}")
    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:get_elapsed, _from, state) do
    elapsed = elapsed_minutes(state.started_at)
    {:reply, elapsed, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:vote_transition, target_phase}, _from, state) do
    elapsed = elapsed_minutes(state.started_at)
    wrap_up_config = state.config[:wrap_up] || %{}
    time_threshold = wrap_up_config[:time_threshold_minutes] || 10
    frustration_threshold = wrap_up_config[:frustration_threshold_minutes] || 5

    vote = case target_phase do
      :closing ->
        # After time_threshold minutes, we're supportive of wrapping up
        if elapsed >= time_threshold do
          {:ready, "Interview has been running for #{round(elapsed)} minutes - time to wrap up"}
        else
          {:abstain, "No timing concerns"}
        end

      :synthesis ->
        # After frustration_threshold minutes, synthesis is acceptable
        if elapsed >= frustration_threshold do
          {:ready, "Good time for synthesis after #{round(elapsed)} minutes"}
        else
          {:abstain, "No timing concerns"}
        end

      _ ->
        {:abstain, "No timing input for this phase"}
    end

    {:reply, vote, state}
  end

  @impl true
  def handle_info(:tick, state) do
    elapsed = elapsed_minutes(state.started_at)
    milestones = state.config[:milestones] || [5, 10]
    tick_interval = state.config[:tick_interval_ms] || 60_000

    # Check for new milestones
    new_milestones = Enum.filter(milestones, fn m ->
      elapsed >= m and m not in state.milestones_hit
    end)

    # Emit signals for new milestones
    Enum.each(new_milestones, fn milestone ->
      emit_timer_signal(milestone, elapsed, state)
    end)

    # Update state with new milestones
    new_state = %{state | milestones_hit: state.milestones_hit ++ new_milestones}

    # CROSS-AGENT: Check if frustration + time suggests wrap-up
    new_state = check_frustration_wrap_up(elapsed, new_state)

    # Schedule next tick
    timer_ref = Process.send_after(self(), :tick, tick_interval)

    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  # CROSS-AGENT: Receive phase changes
  @impl true
  def handle_info({:signal, %{type: "interview.phase." <> _} = signal}, state) do
    phase = signal.data[:phase] || signal.data[:to_phase]
    if phase do
      Logger.debug("[TimerAgent] <- [Director] Phase change: #{phase}")
      now = DateTime.utc_now()
      phase_duration = if state.phase_started_at do
        DateTime.diff(now, state.phase_started_at, :second) / 60 |> Float.round(1)
      else
        0
      end
      Logger.info("[TimerAgent] Phase #{state.current_phase} lasted #{phase_duration} minutes")
      {:noreply, %{state | current_phase: phase, phase_started_at: now}}
    else
      {:noreply, state}
    end
  end

  # CROSS-AGENT: Receive frustration signals from Sentiment Agent
  @impl true
  def handle_info({:signal, %{type: "observer.status.frustration"} = signal}, state) do
    level = signal.data[:level] || :none
    Logger.debug("[TimerAgent] <- [SentimentAgent] Frustration: #{level}")
    elapsed = elapsed_minutes(state.started_at)

    wrap_up_config = state.config[:wrap_up] || %{}
    frustration_threshold = wrap_up_config[:frustration_threshold_minutes] || 5

    new_state = %{state | frustration_level: level}

    # If frustration is moderate+ and we're past threshold, suggest wrap-up
    new_state = if level in [:moderate, :high] and elapsed >= frustration_threshold and not state.frustration_wrap_up_emitted do
      emit_wrap_up_signal(elapsed, level, state)
      %{new_state | frustration_wrap_up_emitted: true}
    else
      new_state
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:signal, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  # Private functions

  defp elapsed_minutes(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) / 60
    |> Float.round(1)
  end

  defp emit_timer_signal(milestone, elapsed, state) do
    recommendations = state.config[:recommendations] || %{}
    milestone_key = String.to_atom("milestone_#{milestone}")
    recommendation = recommendations[milestone_key] || "Interview progressing"

    signal = %Jido.Signal{
      type: "observer.status.timer",
      source: "timer_agent",
      id: Jido.Util.generate_id(),
      data: %{
        elapsed_minutes: elapsed,
        milestone: milestone,
        recommendation: recommendation,
        timestamp: DateTime.utc_now()
      }
    }

    InterviewBus.publish(signal)
    Logger.info("[TimerAgent] Milestone reached: #{milestone} minutes (#{elapsed} elapsed)")
  end

  # CROSS-AGENT: Emit wrap-up signal when user is frustrated and we have enough time elapsed
  defp emit_wrap_up_signal(elapsed, frustration_level, state) do
    recommendations = state.config[:recommendations] || %{}
    wrap_up_recommendation = recommendations[:wrap_up] || "User shows frustration - consider wrapping up"

    signal = %Jido.Signal{
      type: "observer.suggestion.wrap_up",
      source: "timer_agent",
      id: Jido.Util.generate_id(),
      data: %{
        elapsed_minutes: elapsed,
        reason: :frustration_detected,
        frustration_level: frustration_level,
        recommendation: "#{wrap_up_recommendation} (#{round(elapsed)} minutes elapsed)",
        timestamp: DateTime.utc_now()
      }
    }

    InterviewBus.publish(signal)
    Logger.info("[TimerAgent] Suggesting wrap-up: frustration #{frustration_level} at #{round(elapsed)} minutes")
  end

  # Check during tick if we should emit frustration-based wrap-up
  defp check_frustration_wrap_up(elapsed, state) do
    wrap_up_config = state.config[:wrap_up] || %{}
    frustration_threshold = wrap_up_config[:frustration_threshold_minutes] || 5

    if state.frustration_level in [:moderate, :high] and
       elapsed >= frustration_threshold and
       not state.frustration_wrap_up_emitted do
      emit_wrap_up_signal(elapsed, state.frustration_level, state)
      %{state | frustration_wrap_up_emitted: true}
    else
      state
    end
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:timer_agent, session_id}}}
  end
end
