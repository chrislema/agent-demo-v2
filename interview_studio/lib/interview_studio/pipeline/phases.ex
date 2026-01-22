defmodule InterviewStudio.Pipeline.Phases do
  @moduledoc """
  Phase definitions and question banks for the interview.

  Each phase has:
  - Entry conditions
  - Core questions (for core_questions phase)
  - Exit criteria
  - Timing guidelines
  """

  @phases %{
    preparation: %{
      name: "Preparation",
      description: "Initialize agents, load context",
      entry_conditions: ["Session created"],
      exit_criteria: ["All agents ready", "Context loaded"],
      duration: :automatic,
      questions: []
    },
    opening: %{
      name: "Opening",
      description: "Greeting, establish rapport, set expectations",
      entry_conditions: ["Preparation complete"],
      exit_criteria: ["User has responded", "Rapport established"],
      duration: "1-2 exchanges",
      questions: [
        %{
          id: "opening_1",
          text: "Hi! I'm excited to learn more about you and your story. This conversation will help create a compelling article that captures what makes you unique. Ready to dive in?",
          purpose: "Set expectations and get consent"
        }
      ]
    },
    core_questions: %{
      name: "Core Questions",
      description: "Primary interview questions exploring their story",
      entry_conditions: ["Opening complete"],
      exit_criteria: ["All core questions asked", "Or time threshold reached"],
      duration: "Main portion",
      questions: [
        %{
          id: "origin_1",
          text: "Let's start at the beginning. What's your background, and how did you get to where you are today?",
          purpose: "Understand origin story",
          category: :origin
        },
        %{
          id: "passion_1",
          text: "What drives you? What are you most passionate about in your work?",
          purpose: "Uncover motivations",
          category: :passion
        },
        %{
          id: "unique_1",
          text: "What would you say makes your approach or perspective unique? What do you do differently?",
          purpose: "Identify differentiation",
          category: :differentiation
        },
        %{
          id: "moment_1",
          text: "Was there a pivotal moment or turning point that really shaped who you've become?",
          purpose: "Find defining moments",
          category: :moments
        },
        %{
          id: "vision_1",
          text: "Where are you headed? What's the vision or goal you're working toward?",
          purpose: "Understand future direction",
          category: :vision
        }
      ]
    },
    probing: %{
      name: "Probing",
      description: "Follow up on themes, dig deeper",
      entry_conditions: ["Core questions complete", "Or high-value probe opportunity"],
      exit_criteria: ["Probing depth satisfied", "Or diminishing returns"],
      duration: "Variable",
      questions: []  # Generated dynamically based on themes
    },
    synthesis: %{
      name: "Synthesis",
      description: "Summarize key themes, confirm understanding",
      entry_conditions: ["Probing complete"],
      exit_criteria: ["User confirms or corrects synthesis"],
      duration: "1-2 exchanges",
      questions: [
        %{
          id: "synthesis_1",
          text: "Based on our conversation, here's what I'm hearing as the core of your story: [THEMES]. Does that resonate with you? Is there anything you'd add or change?",
          purpose: "Confirm understanding"
        }
      ]
    },
    closing: %{
      name: "Closing",
      description: "Thank user, explain next steps",
      entry_conditions: ["Synthesis confirmed"],
      exit_criteria: ["Session complete"],
      duration: "1 exchange",
      questions: [
        %{
          id: "closing_1",
          text: "Thank you so much for sharing your story with me. I have everything I need to write a compelling piece about you. Is there anything else you'd like to add before we wrap up?",
          purpose: "Final opportunity and gratitude"
        }
      ]
    }
  }

  @doc """
  Get all phase definitions.
  """
  def all, do: @phases

  @doc """
  Get a specific phase definition.
  """
  def get(phase_name) when is_atom(phase_name) do
    Map.get(@phases, phase_name)
  end

  @doc """
  Get questions for a specific phase.
  """
  def questions(phase_name) do
    case get(phase_name) do
      %{questions: questions} -> questions
      _ -> []
    end
  end

  @doc """
  Get question by ID.
  """
  def get_question(question_id) do
    @phases
    |> Map.values()
    |> Enum.flat_map(fn phase -> phase.questions end)
    |> Enum.find(fn q -> q.id == question_id end)
  end

  @doc """
  Get the core question categories.
  """
  def core_categories do
    [:origin, :passion, :differentiation, :moments, :vision]
  end

  @doc """
  Check if a phase is complete based on criteria.
  """
  def phase_complete?(:preparation, _context), do: true

  def phase_complete?(:opening, context) do
    Map.get(context, :user_responded, false)
  end

  def phase_complete?(:core_questions, context) do
    asked = Map.get(context, :questions_asked, [])
    total = length(questions(:core_questions))
    length(asked) >= total
  end

  def phase_complete?(:probing, context) do
    Map.get(context, :probing_satisfied, false) or
    Map.get(context, :diminishing_returns, false)
  end

  def phase_complete?(:synthesis, context) do
    Map.get(context, :synthesis_confirmed, false)
  end

  def phase_complete?(:closing, _context), do: true
end
