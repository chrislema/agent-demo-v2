defmodule InterviewStudio.Agents.TimerAgent do
  @moduledoc """
  Timer Agent - tracks interview duration and signals time milestones.

  Responsibilities:
  - Track how long the interview has been running
  - Emit signals at key milestones (configurable via priv/config/timer.yaml)
  - Provide context for pacing decisions
  - Suggest wrap-up when interview gets lengthy

  Implemented as a Jido.Agent with signal_routes and Actions.
  Uses Schedule directives for periodic tick checks.
  """

  use Jido.Agent,
    name: "timer_agent",
    description: "Tracks interview duration and signals time milestones",
    schema: [
      session_id: [type: :any, default: nil],
      started_at: [type: :any, default: nil],
      milestones_hit: [type: :any, default: []],
      current_phase: [type: :atom, default: :opening],
      phase_started_at: [type: :any, default: nil],
      frustration_level: [type: :atom, default: :none],
      frustration_wrap_up_emitted: [type: :boolean, default: false],
      config: [type: :any, default: %{}]
    ],
    signal_routes: [
      {"interview.phase.entered", InterviewStudio.Agents.TimerAgent.Actions.HandlePhaseChange},
      {"interview.phase.changed", InterviewStudio.Agents.TimerAgent.Actions.HandlePhaseChange},
      {"observer.status.frustration", InterviewStudio.Agents.TimerAgent.Actions.HandleFrustration},
      {"jido.agent.scheduled", InterviewStudio.Agents.TimerAgent.Actions.Tick}
    ]

  require Logger

  alias InterviewStudio.InterviewBus
  alias InterviewStudio.ConfigLoader

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

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    now = DateTime.utc_now()
    config = ConfigLoader.load_with_defaults(:timer, @default_config)

    {:ok, pid} = Jido.AgentServer.start_link(
      agent: __MODULE__,
      name: via_tuple(session_id),
      id: "timer_agent_#{session_id}",
      register_global: false,
      initial_state: %{
        session_id: session_id,
        started_at: now,
        phase_started_at: now,
        config: config
      }
    )

    # Subscribe to InterviewBus signals
    InterviewBus.subscribe_pid("interview.phase.**", pid)
    InterviewBus.subscribe_pid("observer.status.frustration", pid)

    # Schedule the first tick
    tick_interval = config[:tick_interval_ms] || 60_000
    schedule_tick(pid, tick_interval)

    Logger.info("[TimerAgent] Started for session #{session_id} with config: milestones=#{inspect(config[:milestones])}")
    {:ok, pid}
  end

  def get_elapsed_minutes(session_id) do
    state = get_agent_state(session_id)
    elapsed_minutes(state.started_at)
  end

  def get_state(session_id) do
    get_agent_state(session_id)
  end

  @doc """
  Check if transition to phase is ready based on timing.
  Pure function — reads state and computes vote.
  """
  def vote_transition(session_id, target_phase) do
    state = get_agent_state(session_id)
    elapsed = elapsed_minutes(state.started_at)
    wrap_up_config = (state.config || %{})[:wrap_up] || %{}
    time_threshold = wrap_up_config[:time_threshold_minutes] || 10
    frustration_threshold = wrap_up_config[:frustration_threshold_minutes] || 5

    case target_phase do
      :closing ->
        if elapsed >= time_threshold do
          {:ready, "Interview has been running for #{round(elapsed)} minutes - time to wrap up"}
        else
          {:abstain, "No timing concerns"}
        end

      :synthesis ->
        if elapsed >= frustration_threshold do
          {:ready, "Good time for synthesis after #{round(elapsed)} minutes"}
        else
          {:abstain, "No timing concerns"}
        end

      _ ->
        {:abstain, "No timing input for this phase"}
    end
  end

  # Private helpers

  defp get_agent_state(session_id) do
    {:ok, server_state} = Jido.AgentServer.state(via_tuple(session_id))
    server_state.agent.state
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:timer_agent, session_id}}}
  end

  defp elapsed_minutes(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) / 60
    |> Float.round(1)
  end

  # Schedule a tick signal using Process.send_after with the {:signal, signal} format
  # that AgentServer handles natively
  defp schedule_tick(pid, delay_ms) do
    tick_signal = %Jido.Signal{
      type: "jido.agent.scheduled",
      source: "/timer_agent/tick",
      id: Jido.Util.generate_id(),
      data: %{tick: true},
      time: DateTime.utc_now()
    }

    Process.send_after(pid, {:signal, tick_signal}, delay_ms)
  end
end

# =============================================================================
# Action: Tick
# =============================================================================

defmodule InterviewStudio.Agents.TimerAgent.Actions.Tick do
  @moduledoc "Periodic tick — checks milestones and frustration-based wrap-up."

  use Jido.Action,
    name: "timer_tick",
    description: "Check milestones and schedule next tick",
    schema: [
      tick: [type: :any]
    ]

  require Logger

  alias InterviewStudio.InterviewBus

  @impl true
  def run(_params, context) do
    state = context.state
    config = state.config || %{}
    elapsed = elapsed_minutes(state.started_at)
    milestones = config[:milestones] || [5, 10]
    tick_interval = config[:tick_interval_ms] || 60_000

    # Check for new milestones
    new_milestones = Enum.filter(milestones, fn m ->
      elapsed >= m and m not in (state.milestones_hit || [])
    end)

    # Emit signals for new milestones
    Enum.each(new_milestones, fn milestone ->
      emit_timer_signal(milestone, elapsed, config)
    end)

    # Update milestones hit
    updated_milestones = (state.milestones_hit || []) ++ new_milestones

    # Check frustration-based wrap-up
    wrap_up_config = config[:wrap_up] || %{}
    frustration_threshold = wrap_up_config[:frustration_threshold_minutes] || 5

    {wrap_up_emitted, new_frustration_emitted} =
      if state.frustration_level in [:moderate, :high] and
         elapsed >= frustration_threshold and
         not (state.frustration_wrap_up_emitted || false) do
        emit_wrap_up_signal(elapsed, state.frustration_level, config)
        {true, true}
      else
        {state.frustration_wrap_up_emitted || false, false}
      end

    _ = new_frustration_emitted

    # Schedule next tick by sending directly to self
    schedule_next_tick(tick_interval)

    {:ok, %{
      milestones_hit: updated_milestones,
      frustration_wrap_up_emitted: wrap_up_emitted
    }}
  end

  defp schedule_next_tick(delay_ms) do
    tick_signal = %Jido.Signal{
      type: "jido.agent.scheduled",
      source: "/timer_agent/tick",
      id: Jido.Util.generate_id(),
      data: %{tick: true},
      time: DateTime.utc_now()
    }

    Process.send_after(self(), {:signal, tick_signal}, delay_ms)
  end

  defp elapsed_minutes(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) / 60
    |> Float.round(1)
  end

  defp emit_timer_signal(milestone, elapsed, config) do
    recommendations = config[:recommendations] || %{}
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

  defp emit_wrap_up_signal(elapsed, frustration_level, config) do
    recommendations = config[:recommendations] || %{}
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
end

# =============================================================================
# Action: HandlePhaseChange
# =============================================================================

defmodule InterviewStudio.Agents.TimerAgent.Actions.HandlePhaseChange do
  @moduledoc "Updates timer state when interview phase changes."

  use Jido.Action,
    name: "timer_handle_phase_change",
    description: "Track phase timing on phase transitions",
    schema: [
      phase: [type: :any],
      phase_name: [type: :any],
      to_phase: [type: :any]
    ]

  require Logger

  @impl true
  def run(params, context) do
    state = context.state
    phase = params[:phase] || params[:phase_name] || params[:to_phase]

    if phase do
      now = DateTime.utc_now()
      phase_duration = if state.phase_started_at do
        DateTime.diff(now, state.phase_started_at, :second) / 60 |> Float.round(1)
      else
        0
      end
      Logger.info("[TimerAgent] Phase #{state.current_phase} lasted #{phase_duration} minutes")

      {:ok, %{
        current_phase: phase,
        phase_started_at: now
      }}
    else
      {:ok, %{}}
    end
  end
end

# =============================================================================
# Action: HandleFrustration
# =============================================================================

defmodule InterviewStudio.Agents.TimerAgent.Actions.HandleFrustration do
  @moduledoc "Handles frustration signals — may trigger wrap-up suggestion."

  use Jido.Action,
    name: "timer_handle_frustration",
    description: "Process frustration signal and maybe suggest wrap-up",
    schema: [
      level: [type: :any]
    ]

  require Logger

  alias InterviewStudio.InterviewBus

  @impl true
  def run(params, context) do
    state = context.state
    level = params[:level] || :none
    Logger.debug("[TimerAgent] <- [SentimentAgent] Frustration: #{level}")

    elapsed = elapsed_minutes(state.started_at)
    config = state.config || %{}
    wrap_up_config = config[:wrap_up] || %{}
    frustration_threshold = wrap_up_config[:frustration_threshold_minutes] || 5

    new_state = %{frustration_level: level}

    if level in [:moderate, :high] and
       elapsed >= frustration_threshold and
       not (state.frustration_wrap_up_emitted || false) do
      emit_wrap_up_signal(elapsed, level, config)
      {:ok, Map.put(new_state, :frustration_wrap_up_emitted, true)}
    else
      {:ok, new_state}
    end
  end

  defp elapsed_minutes(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) / 60
    |> Float.round(1)
  end

  defp emit_wrap_up_signal(elapsed, frustration_level, config) do
    recommendations = config[:recommendations] || %{}
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
end
