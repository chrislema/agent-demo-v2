# Interview Studio: Multi-Agent Prototype Specification

## Purpose

This prototype demonstrates two fundamental multi-agent patterns using the Jido framework in Elixir:

1. **Sequential Pipeline** - Ordered workflow stages where each phase has defined entry/exit criteria and deterministic progression
2. **Concurrent Swarm** - Multiple specialized agents observing and processing the same events simultaneously in true parallel

The prototype also demonstrates the **hybrid pattern** where pipeline stages and swarm observations interact - the swarm informs decisions within the pipeline, and the pipeline provides context for swarm processing.

This is a precursor to three production applications:
- Brand conversation system (client discovery and positioning)
- MCode voice interview (motivation assessment)
- Moore Mastery tutoring (curriculum-guided learning)

All three share the same architectural pattern: a user engaged in conversation with an orchestrated team of agents working both sequentially (through defined phases) and concurrently (observing and analyzing in parallel).

---

## What Success Looks Like

When complete, this prototype should demonstrate:

1. A user can have a coherent conversation with what appears to be a single interviewer
2. Behind the scenes, multiple agents receive every utterance simultaneously
3. Each observer agent processes independently and emits observations
4. The pipeline progresses through defined phases with clear transitions
5. Swarm observations can influence pipeline decisions (probe deeper, transition early)
6. All signals are traceable with causality (what triggered what)
7. A debug view shows the full signal flow and agent activity

---

## Architecture Overview

### Three Layers

**Layer 1: Interview Pipeline (Sequential)**

The macro flow of the conversation. A state machine managing phases:

```
Preparation → Opening → Core Questions → Probing → Synthesis → Closing
```

Each phase has:
- Entry conditions (what must be true to enter)
- Associated actions (what happens during this phase)
- Exit criteria (what triggers transition to next phase)
- Allowed transitions (which phases can follow)

The pipeline is deterministic and predictable. It provides structure.

**Layer 2: Observer Swarm (Concurrent)**

Multiple specialist agents observing every moment of the interview:

| Agent | Responsibility | Emits |
|-------|----------------|-------|
| Analyst | Extracts themes, patterns, key insights from responses | Theme observations, pattern detections |
| Probe Coach | Identifies opportunities to dig deeper | Probe suggestions with rationale |
| Engagement Monitor | Reads energy, confusion, resistance, enthusiasm | Engagement state, alerts |
| Scribe | Documents key quotes, timestamps, running summary | Transcript entries, summaries |

All observers subscribe to the same signals. All process in parallel (separate BEAM processes). None block each other. Each has a single focused responsibility.

**Layer 3: Director (Orchestrator)**

The bridge between pipeline and swarm:

- Owns the user-facing conversation (the "voice" the user hears)
- Knows current pipeline state (which phase, what's been covered)
- Receives all swarm observations (themes, suggestions, engagement)
- Makes decisions: what to ask next, when to probe, when to transition
- Can override pipeline (skip ahead, loop back) based on swarm input

The Director is the synthesis point. It turns parallel observations into sequential action.

---

## Signal Architecture

All communication happens via Jido Signals on a shared Interview Bus.

### Signal Categories

**User Interaction Signals**

| Signal Type | Payload | Emitted By | Consumed By |
|-------------|---------|------------|-------------|
| interview.utterance.user | content, timestamp, phase_context | Chat interface | All observers, Director |
| interview.utterance.host | content, timestamp, question_id | Director | All observers, Scribe |

**Pipeline Signals**

| Signal Type | Payload | Emitted By | Consumed By |
|-------------|---------|------------|-------------|
| interview.phase.entered | phase_name, timestamp, context | Pipeline FSM | All observers, Director |
| interview.phase.completed | phase_name, summary, next_phase | Pipeline FSM | Director, Scribe |
| interview.transition.requested | from_phase, to_phase, reason | Director | Pipeline FSM |

**Observer Signals**

| Signal Type | Payload | Emitted By | Consumed By |
|-------------|---------|------------|-------------|
| observer.insight.theme | theme, evidence, confidence | Analyst | Director, Scribe |
| observer.insight.pattern | pattern_type, instances, significance | Analyst | Director |
| observer.suggestion.probe | topic, rationale, suggested_question | Probe Coach | Director |
| observer.status.engagement | level, indicators, recommendation | Engagement Monitor | Director |
| observer.record.quote | quote, speaker, timestamp, tags | Scribe | (stored) |
| observer.record.summary | phase, summary_text, key_points | Scribe | Director |

**Director Signals**

| Signal Type | Payload | Emitted By | Consumed By |
|-------------|---------|------------|-------------|
| director.decision.ask | question, rationale, source | Director | Chat interface |
| director.decision.probe | original_topic, probe_question | Director | Chat interface |
| director.decision.transition | to_phase, reason | Director | Pipeline FSM |
| director.decision.override | action, justification | Director | Pipeline FSM |

---

## Pipeline Phases

### Phase Definitions

**1. Preparation**
- Entry: Interview session created
- Actions: Load context, initialize observers, prepare opening
- Exit: All agents ready, context loaded
- Duration: Automatic (no user interaction)

**2. Opening**
- Entry: Preparation complete
- Actions: Greeting, establish rapport, set expectations
- Exit: User has responded to opening, rapport signals positive
- Duration: 1-2 exchanges

**3. Core Questions**
- Entry: Opening complete
- Actions: Ask primary interview questions from question bank
- Exit: All core questions asked OR time threshold reached
- Duration: Main portion of interview (configurable question count)

**4. Probing**
- Entry: Core Questions complete OR high-value probe opportunity detected
- Actions: Follow up on themes identified by Analyst, dig deeper per Probe Coach suggestions
- Exit: Probing depth satisfied OR diminishing returns detected
- Duration: Variable based on richness of responses

**5. Synthesis**
- Entry: Probing complete
- Actions: Summarize key themes back to user, confirm understanding
- Exit: User confirms or corrects synthesis
- Duration: 1-2 exchanges

**6. Closing**
- Entry: Synthesis confirmed
- Actions: Thank user, explain next steps, end session
- Exit: Session complete
- Duration: 1 exchange

### Phase Transitions

Normal flow is linear: 1 → 2 → 3 → 4 → 5 → 6

Allowed non-linear transitions:
- Core Questions → Probing (early, if high-value opportunity)
- Probing → Core Questions (return, if more core questions remain)
- Any phase → Closing (early termination if engagement crashes)

---

## Agent Specifications

### Director Agent

**Role**: Orchestrator and user-facing voice

**State**:
- current_phase
- questions_asked (list)
- questions_remaining (list)
- active_themes (from Analyst)
- pending_suggestions (from Probe Coach)
- engagement_level (from Engagement Monitor)
- conversation_history

**Subscriptions**:
- interview.utterance.user
- interview.phase.*
- observer.insight.*
- observer.suggestion.*
- observer.status.*

**Decision Logic**:
1. Receive user utterance
2. Collect any pending swarm observations (non-blocking)
3. Evaluate: Should I probe (swarm suggestion), continue (next pipeline question), or transition (phase complete)?
4. Emit decision signal
5. Execute decision (ask question, transition phase)

**Key Behavior**: Director should feel responsive. Don't wait for all observers - use whatever observations have arrived. Observers that are slow will inform future turns.

### Analyst Agent

**Role**: Extract meaning from conversation

**State**:
- identified_themes (list with evidence)
- detected_patterns (list)
- phase_context

**Subscriptions**:
- interview.utterance.user
- interview.utterance.host
- interview.phase.entered

**Processing**:
1. Receive utterance
2. Analyze for themes (could use LLM or pattern matching)
3. Compare to existing themes (reinforce or add new)
4. If significant theme detected, emit observer.insight.theme
5. If pattern across multiple responses, emit observer.insight.pattern

**Key Behavior**: Analyst accumulates understanding over time. Early observations are tentative; later observations have more confidence.

### Probe Coach Agent

**Role**: Identify opportunities to dig deeper

**State**:
- probe_opportunities (prioritized list)
- probes_suggested (list, to avoid repetition)
- phase_context

**Subscriptions**:
- interview.utterance.user
- interview.phase.entered

**Processing**:
1. Receive utterance
2. Scan for probe triggers: emotional language, vague statements, contradictions, unexplored tangents
3. If trigger found, formulate probe suggestion
4. Emit observer.suggestion.probe with rationale

**Key Behavior**: Probe Coach is opportunistic. Not every utterance needs a probe. Quality over quantity.

### Engagement Monitor Agent

**Role**: Read the room

**State**:
- current_engagement_level (high/medium/low/critical)
- engagement_history (trend)
- alert_threshold

**Subscriptions**:
- interview.utterance.user
- interview.utterance.host
- interview.phase.entered

**Processing**:
1. Receive utterance
2. Analyze engagement signals: response length, response time, language energy, explicit frustration/confusion
3. Update engagement level
4. If level changes significantly or crosses threshold, emit observer.status.engagement

**Key Behavior**: Engagement Monitor is a guardian. Mostly silent unless something notable happens. Critical engagement triggers immediate alert.

### Scribe Agent

**Role**: Document everything

**State**:
- full_transcript (list of entries)
- phase_summaries (map)
- notable_quotes (list)

**Subscriptions**:
- interview.utterance.user
- interview.utterance.host
- interview.phase.entered
- interview.phase.completed
- observer.insight.theme

**Processing**:
1. Log every utterance with metadata
2. Tag notable quotes (emotional, insightful, key decisions)
3. At phase completion, generate phase summary
4. Emit records for storage

**Key Behavior**: Scribe is comprehensive but quiet. Rarely emits signals that influence Director. Primary output is the documented record.

---

## User Interface

### Primary View (User Experience)

The user sees a simple chat interface:
- Messages from "Interviewer" (Director's voice)
- Input field for responses
- Minimal chrome - feels like a conversation

The user should NOT see:
- Multiple agent names
- Signal traffic
- Phase indicators (unless designed into the conversation naturally)

### Debug View (Developer Experience)

A separate view showing:
- Current pipeline phase (highlighted in phase diagram)
- Live signal stream (filterable by type)
- Agent status panels (what each observer is tracking)
- Causality links (click a signal to see what triggered it and what it triggered)
- Timing information (latency of each agent's processing)

This view is essential for development and demonstrates the architecture.

---

## Implementation Approach

### Suggested Build Sequence

**Step 1: Signal Infrastructure**
- Set up Interview Bus (Jido.Signal.Bus)
- Define all signal types as modules with schemas
- Verify fan-out works (multiple subscribers receive same signal)

**Step 2: Pipeline Only**
- Implement phase state machine (FSM strategy or custom)
- Director walks through phases with scripted questions
- No swarm yet - just Director and Pipeline
- User can chat through a complete interview

**Step 3: Add Scribe**
- First observer agent
- Subscribes to utterances
- Logs everything, emits records
- Verify parallel receipt (Scribe and Director both get signals)

**Step 4: Add Analyst**
- Subscribes to utterances
- Emits theme observations
- Director receives but doesn't act yet (log only)

**Step 5: Add Remaining Observers**
- Probe Coach and Engagement Monitor
- All four observers processing in parallel
- Director receives all observations

**Step 6: Director Uses Swarm Input**
- Director decision logic considers observations
- Probe suggestions can insert follow-up questions
- Engagement alerts can trigger phase transitions
- True hybrid operation

**Step 7: Chat Interface**
- Jido.Chat room for user interaction
- Director as the speaking participant
- Connect chat events to signal bus

**Step 8: Debug Interface**
- Visual signal stream
- Phase diagram
- Agent status panels

---

## Technology Choices

### Required Jido Packages

- **jido** (core) - Agent definitions, Actions, Workflows, FSM strategy
- **jido_signal** - Signal Bus, routing, subscriptions
- **jido_chat** - Chat room for user interface
- **jido_ai** - LLM integration for agent reasoning (Director, Analyst, Probe Coach)

### LLM Usage

Agents that likely need LLM:
- **Director** - Formulating natural questions, responding to unexpected input
- **Analyst** - Identifying themes from unstructured text
- **Probe Coach** - Generating relevant follow-up questions

Agents that might not need LLM:
- **Engagement Monitor** - Could use heuristics (response length, keywords, timing)
- **Scribe** - Mostly logging, summarization could use LLM or templates

### State Storage

- Agent state: In-process (Jido Agent state)
- Signal history: Jido.Signal.Bus history + Journal
- Transcript: Scribe agent state, persisted at end
- Session state: Could use ETS or simple GenServer

---

## Success Criteria

### Functional Requirements

1. User completes full interview through all phases
2. Observers receive every utterance (verifiable in debug view)
3. Analyst identifies at least 2-3 themes during interview
4. Probe Coach suggests at least 1-2 probes that Director uses
5. Phase transitions occur based on defined criteria
6. Final output includes transcript and theme summary

### Architectural Requirements

1. Observers process truly in parallel (verify via timing in debug view)
2. No observer blocks another or blocks Director
3. Signal causality is traceable (every signal links to cause)
4. Pipeline can override normal flow based on swarm input
5. System handles slow LLM responses gracefully (Director doesn't freeze)

### Performance Requirements

1. Director responds within 2-3 seconds of user input (acceptable for LLM)
2. Observers complete processing within 1-2 seconds
3. No message loss under normal operation
4. Graceful degradation if an observer crashes (supervisor restarts, interview continues)

---

## Future Extensions

Once prototype is validated, these extensions map to production apps:

**For MCode Voice Interview**:
- Replace generic Analyst with MCode Dimension Analyzers (8 specialized observers, one per dimension)
- Add voice input/output layer
- Pipeline phases map to MCode interview structure
- Final output generates MCode report

**For Brand Conversation**:
- Replace Analyst with Brand Strategy observers (positioning, messaging, differentiation)
- Pipeline phases map to brand discovery flow
- Probe Coach focuses on competitive and customer insights
- Final output generates brand brief

**For Moore Mastery Tutoring**:
- Replace Analyst with Comprehension Tracker
- Replace Probe Coach with Misconception Detector
- Pipeline phases map to lesson structure
- Add curriculum-aware question selection
- Final output tracks mastery progress

---

## Questions to Resolve During Build

1. **Signal batching**: Should Director wait briefly to collect observations, or act immediately on whatever's available?

2. **Observer priority**: If Probe Coach and Engagement Monitor conflict (probe wants to dig in, engagement says back off), how does Director resolve?

3. **LLM parallelism**: Do observer LLM calls happen in parallel, or should we sequence to manage API costs?

4. **State persistence**: How much state survives a crash? Full replay from signals, or checkpoint-based?

5. **Testing strategy**: How to test swarm behavior? Mock signals? Recorded conversations?

---

## Summary

The Interview Studio prototype is a multi-agent system demonstrating:

- **Sequential pipeline**: Phased interview flow with state machine transitions
- **Concurrent swarm**: Multiple specialized observers processing in parallel
- **Hybrid coordination**: Swarm informs pipeline, pipeline provides context to swarm
- **Unified chat interface**: User sees one interviewer, powered by many agents

Built on Jido's primitives (Agents, Signals, Actions, Skills), it validates the architectural patterns needed for brand conversations, MCode assessments, and tutoring systems.

The key insight: users want simple, coherent experiences. The complexity of multi-agent collaboration should be invisible to them but observable to developers. This prototype proves that pattern.
