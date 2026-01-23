# Multi-Agent Collaboration Architecture

## The TV Studio Model

This document describes a production-tested architecture for orchestrating multiple AI agents that collaborate in real-time. The system was built for conducting intelligent interviews, but the patterns apply to any domain requiring coordinated agent behavior.

### The Metaphor

Imagine a live TV interview studio:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PRODUCTION BOOTH                              │
│  Everyone can hear everything. The producer speaks to the host,     │
│  but the graphics operator, sound engineer, and floor manager        │
│  all hear it too - and can react accordingly.                        │
└─────────────────────────────────────────────────────────────────────┘
         │                    │                    │
    ┌────▼────┐          ┌────▼────┐          ┌────▼────┐
    │  Host   │          │ Graphics │          │  Floor  │
    │(on air) │          │ Operator │          │ Manager │
    └─────────┘          └──────────┘          └─────────┘
```

**Key insight:** In a real TV studio, communication is *broadcast by default*. When the producer says "wrap it up" to the host, everyone hears it. The graphics person starts preparing the outro. The floor manager signals the guest. This ambient awareness enables coordinated behavior without explicit point-to-point messaging.

Our multi-agent system works the same way.

---

## Architecture Overview

### Core Components

```
┌─────────────────────────────────────────────────────────────────┐
│                     INTERVIEW BUS (Broadcast)                   │
│  Phoenix.PubSub with pattern-based subscriptions                │
│  All signals are visible to all subscribers                     │
└─────────────────────────────────────────────────────────────────┘
       ↑↓              ↑↓              ↑↓              ↑↓
   ┌────────┐     ┌────────┐     ┌────────┐     ┌────────┐
   │Director│     │ Story  │     │ Probe  │     │Engage- │
   │ (Host) │     │Analyst │     │ Coach  │     │  ment  │
   └────────┘     └────────┘     └────────┘     └────────┘
       ↑↓              ↑↓              ↑↓              ↑↓
   ┌────────┐     ┌────────┐     ┌────────┐     ┌────────┐
   │ Scribe │     │Sentiment│    │ Timer  │     │  User  │
   │        │     │  Agent  │    │ Agent  │     │  (UI)  │
   └────────┘     └────────┘     └────────┘     └────────┘
```

### The Agents

| Agent | TV Role | Responsibility | LLM-Powered |
|-------|---------|----------------|-------------|
| **Director** | Host/Producer | Conducts interview, synthesizes all input, makes final decisions | Yes |
| **Story Analyst** | Research Team | Identifies themes, patterns, and narrative arcs | Yes |
| **Probe Coach** | Segment Producer | Suggests follow-up questions, spots opportunities for depth | Yes |
| **Engagement Monitor** | Floor Manager | Tracks user engagement, flags when to pivot | No |
| **Sentiment Agent** | Mood Reader | Detects frustration, emotional cues | No |
| **Timer Agent** | Clock Manager | Tracks duration, signals time milestones | No |
| **Scribe** | Transcriptionist | Records everything, captures key quotes, provides memory | No |

### The Bus (Communication Layer)

The `InterviewBus` is the central nervous system. It's built on Phoenix.PubSub with these characteristics:

1. **Broadcast by default** - Any published signal goes to all matching subscribers
2. **Pattern subscriptions** - Subscribe to `observer.**` to hear all observer signals
3. **Typed signals** - Signals have a `type` field for routing (e.g., `observer.insight.theme`)
4. **No exclusion** - Even "direct" messages broadcast; they just add a `target` field

```elixir
# Publishing a signal (visible to everyone subscribed to matching patterns)
signal = %Jido.Signal{
  type: "observer.insight.theme",
  source: "story_analyst",
  data: %{theme: "resilience", evidence: "overcame three failures"}
}
InterviewBus.publish(signal)

# Subscribing to patterns
InterviewBus.subscribe("observer.**")           # All observer signals
InterviewBus.subscribe("interview.utterance.*") # All utterances
InterviewBus.subscribe("observer.status.frustration") # Specific signal
```

---

## Key Patterns

### Pattern 1: Broadcast with Ambient Awareness

Every agent can hear what other agents are saying. This creates emergent coordination.

**Example:** When Sentiment Agent detects frustration:

```elixir
# Sentiment Agent publishes frustration signal
signal = %Jido.Signal{
  type: "observer.status.frustration",
  source: "sentiment_agent",
  data: %{level: :moderate, indicators: [:short_answers, :dismissive]}
}
InterviewBus.publish(signal)
```

Multiple agents react simultaneously:

- **Director** adjusts question depth, considers moving to closing
- **Probe Coach** clears non-urgent probes from queue
- **Timer Agent** may emit "wrap up" suggestion if past 5 minutes
- **Story Analyst** pauses deep analysis to respect user's state

No orchestration code required - each agent independently subscribes and reacts.

### Pattern 2: Cross-Agent Subscriptions

Agents subscribe to each other's outputs to inform their own behavior.

```elixir
# In Probe Coach init/1
def init(opts) do
  # ... setup ...

  # Subscribe to user messages (primary input)
  InterviewBus.subscribe("interview.utterance.user")

  # Cross-agent: hear themes from Story Analyst
  InterviewBus.subscribe("analyst.theme.discovered")

  # Cross-agent: adjust behavior based on engagement
  InterviewBus.subscribe("observer.status.engagement")

  # Cross-agent: back off when user is frustrated
  InterviewBus.subscribe("observer.status.frustration")

  {:ok, state}
end
```

**Subscription Matrix (who hears what):**

| Agent | Subscribes To | Reacts By |
|-------|--------------|-----------|
| Director | Everything (`observer.**`, `interview.**`) | Synthesizing into decisions |
| Story Analyst | Utterances, engagement, probe suggestions | Prioritizing theme analysis |
| Probe Coach | Utterances, themes, engagement, frustration | Generating/filtering probes |
| Sentiment Agent | Utterances, engagement, phase changes | Escalating/relaxing frustration |
| Timer Agent | Phase changes, frustration | Adjusting wrap-up recommendations |
| Engagement Monitor | Utterances only | Calculating engagement metrics |
| Scribe | Utterances, phase changes | Recording everything |

### Pattern 3: Consensus-Based Decisions

For major decisions (phase transitions), the Director polls other agents.

```elixir
def gather_transition_votes(session_id, target_phase) do
  # Poll each agent in parallel
  tasks = [
    Task.async(fn -> {:story_analyst, StoryAnalyst.vote_transition(session_id, target_phase)} end),
    Task.async(fn -> {:probe_coach, ProbeCoach.vote_transition(session_id, target_phase)} end),
    Task.async(fn -> {:engagement_monitor, EngagementMonitor.vote_transition(session_id, target_phase)} end)
  ]

  # Collect votes with timeout
  Task.yield_many(tasks, 3_000)
  |> process_votes()
end

# Each agent returns: {:ready | :not_ready | :abstain, rationale}
def vote_transition(session_id, :synthesis) do
  if length(state.themes) >= 3 do
    {:ready, "Identified #{length(state.themes)} themes - sufficient for synthesis"}
  else
    {:not_ready, "Need more themes before synthesis"}
  end
end
```

**Weighted voting** for domain-specific expertise:
- Engagement Monitor has 2x weight on closing decisions
- Story Analyst has 1.5x weight on synthesis readiness
- Probe Coach has 1.5x weight on probing decisions

### Pattern 4: Collective Memory (Scribe as Archive)

The Scribe maintains the full interview transcript and provides formatted context for LLM prompts.

```elixir
def get_interview_context(session_id) do
  %{
    phases_completed: [...],   # What phases we've been through
    key_quotes: [...],         # Notable moments captured
    key_learnings: [...],      # Extracted from longer responses
    formatted_text: "..."      # Ready for LLM system prompt
  }
end
```

**Why this matters:** LLM agents (Director, Story Analyst, Probe Coach) only see recent messages in their prompts. Without memory, they repeat questions or miss earlier context. The Scribe provides:

1. **Key quotes** - Emotional, reflective, or insightful moments
2. **Key learnings** - First sentences from substantive responses
3. **Phase summaries** - What happened in each phase

This goes into the Director's system prompt:

```
=== INTERVIEW MEMORY (from Scribe) ===

PHASES COMPLETED:
- opening: 2 exchanges (engaged responses)
- core_questions: 6 exchanges (engaged responses)

KEY QUOTES CAPTURED:
- [emotional] "I realized my brother being the 'smart one' pushed me..."
- [reflection] "That failure taught me more than any success..."

KEY LEARNINGS FROM USER:
- I started the company after getting laid off in 2019
- My approach is different because I focus on relationships first

=== END INTERVIEW MEMORY ===
```

### Pattern 5: Graceful Degradation

Agents are designed to work even if other agents are unavailable.

```elixir
defp safe_vote(agent_module, session_id, target_phase) do
  try do
    agent_module.vote_transition(session_id, target_phase)
  rescue
    _ -> {:abstain, "Agent error"}
  catch
    :exit, _ -> {:abstain, "Agent unavailable"}
  end
end
```

The system continues functioning with reduced capability rather than failing.

---

## Signal Types Reference

### Interview Flow Signals
```
interview.utterance.user    - User said something
interview.utterance.host    - Interviewer said something
interview.phase.entered     - Transitioned to new phase
interview.phase.exited      - Left a phase
```

### Observer Signals
```
observer.insight.theme      - Story Analyst found a theme
observer.insight.pattern    - Story Analyst found a pattern
observer.suggestion.probe   - Probe Coach suggests a follow-up
observer.suggestion.wrap_up - Timer suggests wrapping up
observer.status.engagement  - Engagement level update
observer.status.frustration - Frustration level update
observer.status.timer       - Time milestone reached
observer.status.analyzing   - Agent is processing
observer.status.complete    - Agent finished processing
observer.record.quote       - Scribe captured notable quote
observer.record.summary     - Scribe generated phase summary
```

### Director Signals
```
director.consensus.disagreement - Agents didn't agree, Director overrode
analyst.theme.discovered        - Theme sent directly to Probe Coach
engagement.alert.broadcast      - Critical engagement broadcast
```

---

## Implementation Guide

### Creating a New Agent

1. **Define the struct** with state fields:
```elixir
defstruct [
  :session_id,
  :my_data,
  :engagement_level,  # If reacting to engagement
  :frustration_level  # If reacting to frustration
]
```

2. **Subscribe in init/1**:
```elixir
def init(opts) do
  session_id = Keyword.fetch!(opts, :session_id)
  state = %__MODULE__{session_id: session_id, ...}

  # Primary input
  InterviewBus.subscribe("interview.utterance.user")

  # Cross-agent awareness (pick what's relevant)
  InterviewBus.subscribe("observer.status.engagement")
  InterviewBus.subscribe("observer.status.frustration")
  InterviewBus.subscribe("interview.phase.**")

  {:ok, state}
end
```

3. **Handle signals**:
```elixir
def handle_info({:signal, %{type: "interview.utterance.user"} = signal}, state) do
  # React to user input
  new_state = process_user_message(signal.data.content, state)
  {:noreply, new_state}
end

def handle_info({:signal, %{type: "observer.status.frustration"} = signal}, state) do
  # React to frustration from Sentiment Agent
  level = signal.data.level
  new_state = adjust_for_frustration(level, state)
  {:noreply, new_state}
end

def handle_info({:signal, _}, state), do: {:noreply, state}
```

4. **Publish your outputs**:
```elixir
def emit_my_insight(data, state) do
  signal = %Jido.Signal{
    type: "observer.insight.my_type",
    source: "my_agent",
    id: Jido.Util.generate_id(),
    data: data
  }
  InterviewBus.publish(signal)
end
```

5. **Implement vote_transition/2** if participating in consensus:
```elixir
def vote_transition(session_id, target_phase) do
  state = get_state(session_id)
  case target_phase do
    :closing -> evaluate_closing_readiness(state)
    :synthesis -> evaluate_synthesis_readiness(state)
    _ -> {:abstain, "No opinion on this phase"}
  end
end
```

### Adding Cross-Agent Awareness

To have Agent A react to Agent B:

1. **Agent B publishes** its insights/status
2. **Agent A subscribes** to B's signal type
3. **Agent A handles** the signal and updates its behavior

```elixir
# Agent A subscribes to Agent B
InterviewBus.subscribe("agent_b.output.type")

# Agent A handles and reacts
def handle_info({:signal, %{type: "agent_b.output.type"} = signal}, state) do
  # Adjust A's behavior based on B's output
  new_state = react_to_b(signal.data, state)
  {:noreply, new_state}
end
```

---

## Design Principles

### 1. Broadcast Over Point-to-Point
Publish signals to the bus, not to specific agents. Let interested parties subscribe. This enables:
- New agents to tap into existing signals
- Debugging/monitoring without code changes
- Emergent coordination

### 2. React, Don't Request
Agents react to signals they receive rather than requesting information. This keeps agents loosely coupled and enables parallel processing.

### 3. Graceful with Missing Peers
Never assume another agent is available. Use try/catch, timeouts, and fallback behaviors.

### 4. State in Agents, Flow on Bus
Each agent maintains its own state. The bus carries events/signals, not state synchronization messages.

### 5. LLM Agents Need Memory
LLM-powered agents only see their prompt context. Provide summarized history from a memory agent (Scribe) to prevent repetition and enable continuity.

### 6. Consensus for Major Decisions
Don't let one agent make unilateral decisions on phase transitions or significant state changes. Poll relevant agents and use weighted voting.

---

## Debugging

### Signal Visibility
All signals flow through the bus and can be monitored. The debug panel subscribes to `**` to see everything.

### Agent State Inspection
Each agent exposes `get_state/1` for debugging:
```elixir
Director.get_state(session_id)
StoryAnalyst.get_state(session_id)
```

### Log Patterns
Agents log cross-agent communication:
```
[ProbeCoach] <- [StoryAnalyst] Received theme: resilience
[TimerAgent] <- [SentimentAgent] Frustration: moderate
[Director] CONSENSUS reached for transition to synthesis
```

---

## Summary

The TV Studio model for multi-agent collaboration:

1. **Broadcast communication** - Everyone hears everything relevant
2. **Pattern subscriptions** - Subscribe to signal types, not agents
3. **Ambient awareness** - Agents react to each other's outputs
4. **Consensus decisions** - Major decisions involve polling agents
5. **Collective memory** - Scribe provides context across the full session
6. **Graceful degradation** - System works even with missing agents

This architecture enables coordinated, intelligent behavior from multiple specialized agents without tight coupling or complex orchestration code. Each agent does its job, publishes what it learns, and reacts to what it hears - just like a well-run TV production.
