defmodule InterviewStudio.Testing.FeedbackLoop.ConversationRunner do
  @moduledoc """
  Runs a single automated conversation for testing.

  Orchestrates an IntervieweeAgent with the actual interview system
  to produce a complete conversation that can be evaluated.
  """

  require Logger

  alias InterviewStudio.Session
  alias InterviewStudio.Testing.FeedbackLoop.IntervieweeAgent
  alias InterviewStudio.Testing.FeedbackLoop.Evaluator
  alias InterviewStudio.Testing.FeedbackLoop.Persona
  alias InterviewStudio.Agents.Director

  @default_max_exchanges 20
  @exchange_timeout 60_000

  @doc """
  Runs a single automated conversation.

  ## Options
    * `:persona` - Persona name (atom/string) or Persona struct. Required.
    * `:domain` - Domain name (default: "interview")
    * `:max_exchanges` - Maximum number of exchanges before stopping (default: 20)
    * `:session_id` - Optional custom session ID

  ## Returns
    A map containing:
    * `:session_id` - The session ID used
    * `:persona` - The persona used
    * `:exchanges` - List of all exchanges
    * `:evaluation` - Evaluation results from Evaluator
    * `:duration_ms` - Total duration in milliseconds
    * `:final_phase` - The phase the conversation ended in
    * `:error` - Error details if the conversation failed
  """
  @spec run(keyword()) :: map()
  def run(opts) do
    start_time = System.monotonic_time(:millisecond)

    persona_input = Keyword.fetch!(opts, :persona)
    domain = Keyword.get(opts, :domain, "interview")
    max_exchanges = Keyword.get(opts, :max_exchanges, @default_max_exchanges)
    custom_session_id = Keyword.get(opts, :session_id)

    # Load persona if needed
    persona =
      case persona_input do
        %Persona{} = p -> p
        name -> Persona.load!(name)
      end

    Logger.info("[ConversationRunner] Starting conversation with persona: #{persona.name}")

    # Start session
    session_opts = [domain: domain]
    session_opts = if custom_session_id, do: [{:session_id, custom_session_id} | session_opts], else: session_opts

    case Session.start_session(session_opts) do
      {:ok, session_id} ->
        run_with_session(session_id, persona, domain, max_exchanges, start_time)

      {:error, reason} ->
        end_time = System.monotonic_time(:millisecond)

        %{
          session_id: nil,
          persona: persona.name,
          exchanges: [],
          evaluation: nil,
          duration_ms: end_time - start_time,
          final_phase: nil,
          error: {:session_start_failed, reason}
        }
    end
  end

  defp run_with_session(session_id, persona, domain, max_exchanges, start_time) do
    # Start interviewee agent
    case IntervieweeAgent.start_link(session_id: session_id, persona: persona, domain: domain) do
      {:ok, _pid} ->
        result = execute_conversation(session_id, max_exchanges)

        # Evaluate
        evaluation = Evaluator.evaluate(session_id)

        # Get final phase
        final_phase =
          case Session.current_phase(session_id) do
            {:ok, phase} -> phase
            _ -> :unknown
          end

        # Cleanup
        cleanup(session_id)

        end_time = System.monotonic_time(:millisecond)

        %{
          session_id: session_id,
          persona: persona.name,
          exchanges: result.exchanges,
          evaluation: evaluation,
          duration_ms: end_time - start_time,
          final_phase: final_phase,
          exchange_count: result.exchange_count,
          stopped_reason: result.stopped_reason,
          error: result.error
        }

      {:error, reason} ->
        cleanup(session_id)
        end_time = System.monotonic_time(:millisecond)

        %{
          session_id: session_id,
          persona: persona.name,
          exchanges: [],
          evaluation: nil,
          duration_ms: end_time - start_time,
          final_phase: nil,
          error: {:interviewee_start_failed, reason}
        }
    end
  end

  defp execute_conversation(session_id, max_exchanges) do
    initial_state = %{
      exchanges: [],
      exchange_count: 0,
      stopped_reason: nil,
      error: nil
    }

    # Get initial greeting from Director
    case get_initial_greeting(session_id) do
      {:ok, greeting} ->
        initial_exchange = %{
          turn: 0,
          host_message: greeting,
          user_response: nil,
          phase: get_current_phase(session_id)
        }

        run_conversation_loop(
          session_id,
          max_exchanges,
          %{initial_state | exchanges: [initial_exchange]}
        )

      {:error, reason} ->
        %{initial_state | error: {:greeting_failed, reason}, stopped_reason: :error}
    end
  end

  defp run_conversation_loop(session_id, max_exchanges, state) do
    cond do
      # Max exchanges reached
      state.exchange_count >= max_exchanges ->
        %{state | stopped_reason: :max_exchanges_reached}

      # Conversation in closing phase
      in_closing_phase?(session_id) ->
        %{state | stopped_reason: :closing_phase_reached}

      # Error occurred
      state.error != nil ->
        state

      # Continue conversation
      true ->
        case run_single_exchange(session_id, state) do
          {:continue, new_state} ->
            run_conversation_loop(session_id, max_exchanges, new_state)

          {:stop, new_state} ->
            new_state
        end
    end
  end

  defp run_single_exchange(session_id, state) do
    # Get the last host message to respond to
    last_exchange = List.last(state.exchanges)
    host_message = last_exchange && last_exchange.host_message

    if is_nil(host_message) do
      {:stop, %{state | stopped_reason: :no_host_message, error: :missing_host_message}}
    else
      # Generate interviewee response
      case IntervieweeAgent.generate_response(session_id, host_message) do
        {:ok, user_response} ->
          # Update last exchange with user response
          updated_last = %{last_exchange | user_response: user_response}
          updated_exchanges = List.replace_at(state.exchanges, -1, updated_last)

          # Process user message through interview system
          case process_and_get_response(session_id, user_response) do
            {:ok, next_host_message} ->
              new_exchange = %{
                turn: state.exchange_count + 1,
                host_message: next_host_message,
                user_response: nil,
                phase: get_current_phase(session_id)
              }

              new_state = %{
                state
                | exchanges: updated_exchanges ++ [new_exchange],
                  exchange_count: state.exchange_count + 1
              }

              # Check if we've reached closing
              if in_closing_phase?(session_id) do
                {:stop, %{new_state | stopped_reason: :closing_phase_reached}}
              else
                {:continue, new_state}
              end

            {:error, reason} ->
              {:stop, %{state | error: {:process_message_failed, reason}, stopped_reason: :error}}
          end

        {:error, reason} ->
          {:stop, %{state | error: {:interviewee_response_failed, reason}, stopped_reason: :error}}
      end
    end
  end

  defp get_initial_greeting(session_id) do
    # The session should have an opening message ready
    # We need to trigger the first host message

    # First, transition to opening phase if in preparation
    case Session.current_phase(session_id) do
      {:ok, :preparation} ->
        # Transition to opening
        case Director.transition(session_id, :opening, "Automated test start") do
          {:ok, _} -> :ok
          {:error, _} -> :ok # May already be in opening
        end

      _ ->
        :ok
    end

    # Get the initial greeting by processing an empty or greeting message
    # The Director should generate the opening question
    case Session.process_message(session_id, "[Session started]") do
      {:ok, response} -> {:ok, response}
      error -> error
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  defp process_and_get_response(session_id, message) do
    Task.async(fn ->
      Session.process_message(session_id, message)
    end)
    |> Task.await(@exchange_timeout)
  rescue
    e -> {:error, {:exception, e}}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  defp get_current_phase(session_id) do
    case Session.current_phase(session_id) do
      {:ok, phase} -> phase
      _ -> :unknown
    end
  end

  defp in_closing_phase?(session_id) do
    case Session.current_phase(session_id) do
      {:ok, :closing} -> true
      _ -> false
    end
  end

  defp cleanup(session_id) do
    # Stop interviewee agent
    IntervieweeAgent.stop(session_id)

    # Stop session
    Session.stop_session(session_id)
  rescue
    _ -> :ok
  end
end
