# Multi-Agent Architecture Proposal

## The Anchor Question

**If this can be built as a sequential pipeline workflow, we've failed.**

The demo must showcase capabilities that require true multi-agent collaboration—not just agents running in sequence or background tasks that don't affect real-time decisions.

---

## Current State (The Problem)

The current architecture is essentially a sequential pipeline with background noise:

```
User Message → Director Responds → (Background: Analysts run, results ignored until later)
```

### What's Actually Happening:
1. User sends message
2. Director immediately picks next question from static question bank
3. LLM "adapts" the question (minor rewording)
4. Story Analyst and Probe Coach run in background
5. Their insights only affect *future* questions (if at all)
6. Engagement Monitor detects issues but signals arrive too late

### Why This Fails the Test:
- Could be built as a simple state machine with an LLM call
- No real-time collaboration between agents
- No emergent behavior from multiple perspectives
- The "agents" are just async decorations

---

## Proposed Architecture: True Multi-Agent Collaboration

### Core Principle: Parallel Analysis → Collective Synthesis → Dynamic Response

```
User Message
     ↓
┌────────────────────────────────────────────┐
│         PARALLEL ANALYSIS PHASE            │
│  (All agents analyze simultaneously)       │
│                                            │
│  ┌─────────────┐  ┌─────────────┐         │
│  │Story Analyst│  │ Probe Coach │         │
│  │ "resilience │  │ "brother    │         │
│  │  theme"     │  │  unexplored"│         │
│  └──────┬──────┘  └──────┬──────┘         │
│         │                │                 │
│  ┌──────┴────────────────┴──────┐         │
│  │    Engagement Monitor         │         │
│  │    "high engagement now"      │         │
│  └──────────────┬───────────────┘         │
└─────────────────┼──────────────────────────┘
                  ↓
┌────────────────────────────────────────────┐
│         SYNTHESIS PHASE                    │
│  (Director waits for & combines inputs)    │
│                                            │
│  Director receives:                        │
│  - Themes: [resilience, self-reliance]     │
│  - Probes: [brother relationship, 3k bet]  │
│  - Engagement: high, lean in               │
│  - Phase context: core_questions           │
│                                            │
│  Director decides:                         │
│  "Given high engagement + unexplored       │
│   brother thread + resilience theme,       │
│   I should probe the brother dynamic"      │
└─────────────────┬──────────────────────────┘
                  ↓
┌────────────────────────────────────────────┐
│         DYNAMIC RESPONSE                   │
│  (Generated from collective intelligence)  │
│                                            │
│  NOT: "What drives you?" (from question    │
│        bank)                               │
│                                            │
│  YES: "You mentioned your brother was the  │
│        'smart one' - I'm curious how that  │
│        dynamic shaped your approach to     │
│        working with brilliant people at    │
│        Berkeley..."                        │
└────────────────────────────────────────────┘
```

---

## Key Differentiators from Pipeline Architecture

### 1. **Parallel Processing with Synchronization Barrier**

Pipeline: Agent A → Agent B → Agent C (sequential)

Multi-Agent:
```
         ┌→ Agent A ─┐
Input ───┼→ Agent B ─┼→ Synchronization → Synthesis → Output
         └→ Agent C ─┘
```

All agents must complete (or timeout) before proceeding. Their outputs are combined, not chained.

### 2. **No Static Question Bank**

Pipeline: Pick question #3 from list, have LLM rephrase it

Multi-Agent: Generate question dynamically based on:
- Themes discovered by Story Analyst
- Probes suggested by Probe Coach
- Engagement level from Monitor
- Conversation context
- Phase goals

The question emerges from collective intelligence, not a lookup table.

### 3. **Agents Influence Each Other**

Pipeline: Each agent works independently on its task

Multi-Agent:
- Story Analyst's themes inform Probe Coach's suggestions
- Probe Coach's suggestions inform Director's question
- Engagement Monitor can override both ("user is tired, wrap up")
- Director synthesizes all inputs into coherent action

### 4. **Visible Collaboration in UI**

The debug panel should show agents "talking":
```
[21:45:01] Story Analyst → Director: Identified theme "resilience through adversity"
[21:45:01] Probe Coach → Director: Suggest probing brother relationship (high priority)
[21:45:02] Engagement Monitor → All: User highly engaged, lean in
[21:45:02] Director: Synthesizing inputs... generating response
[21:45:03] Director → User: [question that incorporates all inputs]
```

### 5. **Emergent Behavior**

The combination of agents produces insights no single agent would generate:
- Story Analyst sees "resilience"
- Probe Coach sees "brother dynamic unexplored"
- Together: "The brother dynamic is the *source* of the resilience—probe there"

This synthesis is the value of multi-agent architecture.

---

## Implementation Changes Required

### Phase 1: Parallel Analysis with Wait

```elixir
def process_message(session_id, message) do
  # 1. Broadcast message to all agents
  :ok = Director.process_user_message(session_id, message)

  # 2. Trigger parallel analysis and WAIT for results (with timeout)
  insights = gather_insights(session_id, timeout: 3000)
  # Returns: %{themes: [...], probes: [...], engagement: :high}

  # 3. Director synthesizes all inputs
  action = Director.get_next_action(session_id, insights)

  # 4. Generate response incorporating insights
  handle_action(session_id, action, insights)
end
```

### Phase 2: Dynamic Question Generation

Remove the static question bank. Instead:

```elixir
defp build_user_prompt(:ask, context, state) do
  """
  Recent conversation:
  #{format_history(state.conversation_history)}

  Themes discovered by Story Analyst:
  #{format_themes(context.insights.themes)}

  Probe suggestions from Probe Coach:
  #{format_probes(context.insights.probes)}

  Engagement level: #{context.insights.engagement}
  Current phase: #{state.current_phase}
  Phase goal: #{phase_goal(state.current_phase)}

  Generate a question that:
  1. Explores the most promising theme or probe suggestion
  2. Builds naturally on the conversation
  3. Matches the current engagement level
  4. Advances the phase goal

  Do NOT use generic questions. The question must be specific to what
  this person has shared and what the analysts have discovered.
  """
end
```

### Phase 3: Agent-to-Agent Communication

Agents should be able to message each other:

```elixir
# Story Analyst discovers theme, notifies Probe Coach
InterviewBus.publish(%Signal{
  type: "analyst.insight.theme",
  source: "story_analyst",
  target: "probe_coach",  # Direct message
  data: %{theme: "resilience", evidence: "..."}
})

# Probe Coach receives theme, generates relevant probe
def handle_signal(%{type: "analyst.insight.theme"} = signal, state) do
  # Generate probe specifically about this theme
  probe = generate_theme_probe(signal.data.theme, state)
  # ...
end
```

### Phase 4: Consensus Mechanisms

For critical decisions, agents could vote:

```elixir
def should_transition_to_synthesis?(session_id) do
  votes = %{
    story_analyst: StoryAnalyst.vote_ready?(session_id),
    probe_coach: ProbeCoach.vote_ready?(session_id),
    engagement: EngagementMonitor.vote_ready?(session_id)
  }

  # Majority or weighted consensus
  Enum.count(votes, fn {_, v} -> v end) >= 2
end
```

---

## Success Criteria

The demo succeeds if:

1. **You can't replicate it with a pipeline**: No sequence of LLM calls could produce the same behavior

2. **Removing an agent changes the output**: If Story Analyst is disabled, the questions are noticeably different (not just missing a feature)

3. **Agents visibly collaborate**: The debug panel shows agents influencing each other in real-time

4. **Questions are truly dynamic**: No two interviews with similar content produce identical questions

5. **The whole is greater than the sum**: The combined agent output is better than any single agent could produce

---

## What This Demo Proves

If implemented correctly, this demo proves:

- **Multi-agent systems can handle ambiguity** that pipelines can't (what question to ask next depends on parallel analysis)

- **Collective intelligence emerges** from multiple specialized perspectives

- **Real-time collaboration** between AI agents is possible and valuable

- **The architecture is necessary**, not just fancy—a pipeline couldn't do this

---

## Next Steps

1. Implement parallel analysis with synchronization barrier
2. Remove static question bank, implement dynamic generation
3. Add agent-to-agent messaging
4. Make collaboration visible in UI
5. Test that removing agents changes behavior
6. Validate against success criteria
