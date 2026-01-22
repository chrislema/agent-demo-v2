defmodule InterviewStudio.Pipeline.InterviewFSM do
  @moduledoc """
  Finite State Machine managing the interview phases.

  Phases:
  1. Preparation - Initialize agents, load context (automatic)
  2. Opening - Greeting, establish rapport (1-2 exchanges)
  3. Core Questions - Primary interview questions (main portion)
  4. Probing - Follow up on themes, dig deeper (variable)
  5. Synthesis - Summarize themes, confirm understanding (1-2 exchanges)
  6. Closing - Thank user, explain next steps (1 exchange)

  Transitions:
  - Normal flow: 1 -> 2 -> 3 -> 4 -> 5 -> 6
  - Early probe: 3 -> 4 (if high-value opportunity)
  - Return to questions: 4 -> 3 (if more questions remain)
  - Early exit: Any -> 6 (if engagement crashes)
  """

  use GenServer
  require Logger

  alias InterviewStudio.InterviewBus

  # Valid transitions from each phase
  @transitions %{
    preparation: [:opening],
    opening: [:core_questions],
    core_questions: [:probing, :synthesis, :closing],
    probing: [:core_questions, :synthesis, :closing],
    synthesis: [:closing],
    closing: []
  }

  defstruct [
    :session_id,
    :current_phase,
    :phase_history,
    :started_at,
    :phase_started_at,
    :context
  ]

  # Client API

  def start_link(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  def current_phase(session_id) do
    GenServer.call(via_tuple(session_id), :current_phase)
  end

  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  def transition(session_id, to_phase, reason \\ "requested") do
    GenServer.call(via_tuple(session_id), {:transition, to_phase, reason})
  end

  def complete_phase(session_id, summary \\ nil) do
    GenServer.call(via_tuple(session_id), {:complete_phase, summary})
  end

  def can_transition?(session_id, to_phase) do
    GenServer.call(via_tuple(session_id), {:can_transition?, to_phase})
  end

  # Server Callbacks

  @impl true
  def init(session_id) do
    state = %__MODULE__{
      session_id: session_id,
      current_phase: :preparation,
      phase_history: [],
      started_at: DateTime.utc_now(),
      phase_started_at: DateTime.utc_now(),
      context: %{}
    }

    # Subscribe to transition requests
    InterviewBus.subscribe("director.decision.transition")

    # Emit phase entered signal for preparation
    emit_phase_entered(state)

    Logger.info("[InterviewFSM] Session #{session_id} started in :preparation phase")
    {:ok, state}
  end

  @impl true
  def handle_call(:current_phase, _from, state) do
    {:reply, state.current_phase, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:transition, to_phase, reason}, _from, state) do
    case do_transition(state, to_phase, reason) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.current_phase}, new_state}

      {:error, reason} = error ->
        Logger.warning("[InterviewFSM] Transition denied: #{reason}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:complete_phase, summary}, _from, state) do
    # Record phase completion
    history_entry = %{
      phase: state.current_phase,
      started_at: state.phase_started_at,
      completed_at: DateTime.utc_now(),
      summary: summary
    }

    new_state = %{state |
      phase_history: [history_entry | state.phase_history]
    }

    # Emit phase completed signal
    emit_phase_completed(new_state, summary)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:can_transition?, to_phase}, _from, state) do
    allowed = Map.get(@transitions, state.current_phase, [])
    {:reply, to_phase in allowed, state}
  end

  @impl true
  def handle_info({:signal, %{type: "director.decision.transition"} = signal}, state) do
    to_phase = signal.data.to_phase
    reason = signal.data.reason

    case do_transition(state, to_phase, reason) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signal, _signal}, state) do
    # Ignore other signals
    {:noreply, state}
  end

  # Private functions

  defp do_transition(state, to_phase, reason) do
    allowed = Map.get(@transitions, state.current_phase, [])

    if to_phase in allowed do
      Logger.info("[InterviewFSM] Transitioning from #{state.current_phase} to #{to_phase}: #{reason}")

      # Record the previous phase in history
      history_entry = %{
        phase: state.current_phase,
        started_at: state.phase_started_at,
        completed_at: DateTime.utc_now(),
        summary: reason
      }

      new_state = %{state |
        current_phase: to_phase,
        phase_started_at: DateTime.utc_now(),
        phase_history: [history_entry | state.phase_history]
      }

      # Emit signals
      emit_phase_completed(state, reason)
      emit_phase_entered(new_state)

      {:ok, new_state}
    else
      {:error, "Invalid transition from #{state.current_phase} to #{to_phase}"}
    end
  end

  defp emit_phase_entered(state) do
    signal = %Jido.Signal{
      type: "interview.phase.entered",
      source: "interview_fsm",
      id: Jido.Util.generate_id(),
      data: %{
        phase_name: state.current_phase,
        timestamp: DateTime.utc_now(),
        context: state.context
      }
    }
    InterviewBus.publish(signal)
  end

  defp emit_phase_completed(state, summary) do
    next_phase = case Map.get(@transitions, state.current_phase, []) do
      [first | _] -> first
      [] -> nil
    end

    signal = %Jido.Signal{
      type: "interview.phase.completed",
      source: "interview_fsm",
      id: Jido.Util.generate_id(),
      data: %{
        phase_name: state.current_phase,
        summary: summary,
        next_phase: next_phase,
        timestamp: DateTime.utc_now()
      }
    }
    InterviewBus.publish(signal)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:fsm, session_id}}}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
