defmodule InterviewStudio.Agents.TimerAgent do
  @moduledoc """
  Timer Agent - tracks interview duration and signals time milestones.

  Responsibilities:
  - Track how long the interview has been running
  - Emit signals at key milestones (5, 10, 15, 20 minutes)
  - Provide context for pacing decisions
  - Suggest wrap-up when interview gets lengthy
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus

  @tick_interval 60_000  # Check every minute
  @milestones [5, 10]    # Key decision points

  defstruct [
    :session_id,
    :started_at,
    :milestones_hit,
    :timer_ref
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

    state = %__MODULE__{
      session_id: session_id,
      started_at: DateTime.utc_now(),
      milestones_hit: [],
      timer_ref: nil
    }

    # Start the timer tick
    timer_ref = Process.send_after(self(), :tick, @tick_interval)

    Logger.info("[TimerAgent] Started for session #{session_id}")
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

    vote = case target_phase do
      :closing ->
        # After 10 minutes, we're supportive of wrapping up
        if elapsed >= 10 do
          {:ready, "Interview has been running for #{round(elapsed)} minutes - time to wrap up"}
        else
          {:abstain, "No timing concerns"}
        end

      :synthesis ->
        # After 5 minutes, synthesis is acceptable
        if elapsed >= 5 do
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

    # Check for new milestones
    new_milestones = Enum.filter(@milestones, fn m ->
      elapsed >= m and m not in state.milestones_hit
    end)

    # Emit signals for new milestones
    Enum.each(new_milestones, fn milestone ->
      emit_timer_signal(milestone, elapsed, state.session_id)
    end)

    # Update state with new milestones
    new_state = %{state | milestones_hit: state.milestones_hit ++ new_milestones}

    # Schedule next tick
    timer_ref = Process.send_after(self(), :tick, @tick_interval)

    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

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

  defp emit_timer_signal(milestone, elapsed, _session_id) do
    recommendation = case milestone do
      10 -> "We should likely wrap up"
      5 -> "Pay attention to time"
      _ -> "Interview progressing"
    end

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

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:timer_agent, session_id}}}
  end
end
