# Interview Studio Demo - Implementation Plan

## Demo Purpose

A multi-agent interview system that discovers what makes a person unique and amazing, resulting in a compelling article/post about them. The user experiences a natural conversation with a skilled interviewer, while behind the scenes 5 agents collaborate to extract insights, identify themes, and build a rich portrait.

---

## Interview Context: "The Story of You"

**Goal**: Through conversational interview, uncover:
- What drives this person (motivations, passions)
- Their unique perspective or approach
- Key moments that shaped who they are
- What others should know about them
- The "hook" that makes their story compelling

**Output**: Interview transcript + synthesized themes + article outline

---

## Architecture Overview

### Three Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    USER CHAT INTERFACE                       │
│                 (simple, conversational)                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      DIRECTOR AGENT                          │
│            (orchestrator, user-facing voice)                 │
│                                                              │
│  Receives: user utterances, observer insights               │
│  Decides: what to ask, when to probe, when to transition    │
│  Emits: questions, probes, phase transitions                │
└─────────────────────────────────────────────────────────────┘
                    │                    │
         ┌──────────┘                    └──────────┐
         ▼                                          ▼
┌─────────────────────┐              ┌─────────────────────────┐
│   PIPELINE (FSM)    │              │    OBSERVER SWARM       │
│                     │              │    (parallel agents)    │
│ Preparation         │              │                         │
│ Opening             │◄────────────►│ • Story Analyst         │
│ Core Questions      │              │ • Probe Coach           │
│ Probing             │              │ • Engagement Monitor    │
│ Synthesis           │              │ • Scribe                │
│ Closing             │              │                         │
└─────────────────────┘              └─────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     DEBUG VIEW                               │
│  • Live signal stream     • Phase diagram                   │
│  • Agent activity         • Causality links                 │
└─────────────────────────────────────────────────────────────┘
```

---

## Pipeline Phases (Tailored for Story Discovery)

### 1. Preparation (automatic)
- Initialize all agents
- Load any prior context about interviewee
- Prepare opening approach

### 2. Opening (1-2 exchanges)
- Warm greeting, set expectations
- "I'm here to learn your story and help tell it"
- Build rapport

### 3. Core Questions (main portion)
- **Origin**: How did you get started? What's your background?
- **Passion**: What drives you? What do you care most about?
- **Differentiation**: What makes your approach unique?
- **Moments**: Key turning points or defining experiences?
- **Vision**: Where are you headed? What's next?

### 4. Probing (variable)
- Follow threads identified by Story Analyst
- Dig into emotional moments flagged by Probe Coach
- Explore contradictions or unexplored tangents

### 5. Synthesis (1-2 exchanges)
- Reflect back key themes: "What I'm hearing is..."
- Confirm or refine the portrait
- Identify the central narrative hook

### 6. Closing (1 exchange)
- Thank them, preview what happens next
- Final opportunity to add anything missed

---

## Agent Specifications

### Director Agent
**Role**: The interviewer voice the user interacts with

**Responsibilities**:
- Formulate natural, warm questions
- Decide whether to follow script, probe deeper, or transition
- Synthesize swarm input into conversational decisions
- Maintain interview flow and pacing

**LLM-Powered**: Yes (generates natural language responses)

---

### Story Analyst Agent
**Role**: Extract narrative themes and patterns

**Looks For**:
- Recurring themes (resilience, creativity, community, etc.)
- Story arcs (struggle → breakthrough, passion → profession)
- Unique angles that differentiate this person
- Quotable moments and key phrases

**Emits**: `observer.insight.theme`, `observer.insight.pattern`

**LLM-Powered**: Yes

---

### Probe Coach Agent
**Role**: Identify opportunities to go deeper

**Looks For**:
- Emotional language worth exploring
- Vague statements that need specifics
- Unexplored tangents with potential
- Contradictions or tensions

**Emits**: `observer.suggestion.probe` with suggested question

**LLM-Powered**: Yes

---

### Engagement Monitor Agent
**Role**: Read conversational energy

**Monitors**:
- Response length and enthusiasm
- Signs of discomfort or resistance
- Energy levels throughout interview
- When to ease off vs. lean in

**Emits**: `observer.status.engagement`

**LLM-Powered**: No (heuristic-based)

---

### Scribe Agent
**Role**: Document everything

**Records**:
- Full transcript with timestamps
- Tagged notable quotes
- Phase summaries
- Theme evidence mapping

**Emits**: `observer.record.quote`, `observer.record.summary`

**LLM-Powered**: Partial (summarization)

---

## User Interfaces

### Primary Chat View
- Clean, minimal chat interface
- Messages from "Interviewer"
- Simple text input
- No visible agent activity
- Progress indicator (subtle phase hints optional)

### Debug View
- **Signal Stream**: Live feed of all signals, filterable by type
- **Phase Diagram**: Visual FSM showing current phase highlighted
- **Agent Panels**: Status of each observer (themes found, probes pending, engagement level)
- **Causality Graph**: Click any signal to see what triggered it
- **Timing**: Latency metrics for each agent

---

## Signal Architecture

### Signal Types

| Category | Signal | Payload |
|----------|--------|---------|
| User | `interview.utterance.user` | content, timestamp |
| Host | `interview.utterance.host` | content, question_id |
| Pipeline | `interview.phase.entered` | phase_name |
| Pipeline | `interview.phase.completed` | phase_name, summary |
| Observer | `observer.insight.theme` | theme, evidence, confidence |
| Observer | `observer.insight.pattern` | pattern_type, instances |
| Observer | `observer.suggestion.probe` | topic, rationale, question |
| Observer | `observer.status.engagement` | level, indicators |
| Observer | `observer.record.quote` | quote, speaker, tags |
| Director | `director.decision.ask` | question, rationale |
| Director | `director.decision.probe` | original_topic, probe |
| Director | `director.decision.transition` | to_phase, reason |

---

## Technology Stack

- **Framework**: Elixir + Phoenix + Jido
- **Packages**: jido, jido_signal, jido_chat, jido_ai
- **LLM Provider**: Anthropic Claude (via jido_ai)
- **Frontend**: Phoenix LiveView
- **Deployment**: Fly.io (agentdemov2)

---

## Implementation Steps

### Step 1: Project Setup
- Create new Phoenix project with LiveView
- Add Jido dependencies (jido, jido_signal, jido_chat, jido_ai)
- Configure LLM credentials
- Set up basic supervision tree

### Step 2: Signal Infrastructure
- Define all signal type modules with schemas
- Set up Interview Bus (Jido.Signal.Bus)
- Verify fan-out (multiple subscribers receive signals)
- Add Journal for causality tracking

### Step 3: Pipeline FSM
- Implement 6-phase state machine
- Define phase entry/exit conditions
- Create transition logic
- Test phase progression without agents

### Step 4: Director Agent
- Implement Director with question bank
- Connect to pipeline phases
- Add LLM integration for natural responses
- Walk through scripted interview

### Step 5: Observer Agents
- Implement Scribe (transcript, quotes)
- Implement Story Analyst (themes, patterns)
- Implement Probe Coach (dig-deeper suggestions)
- Implement Engagement Monitor (heuristics)
- Verify all receive signals in parallel

### Step 6: Hybrid Integration
- Director consumes swarm observations
- Probe suggestions influence questions
- Engagement alerts affect pacing
- True coordinated behavior

### Step 7: Chat Interface
- Phoenix LiveView chat component
- Connect to Jido.Chat room
- Director as participant
- Clean user experience

### Step 8: Debug Interface
- LiveView component for signal stream
- Phase diagram visualization
- Agent status panels
- Causality display

### Step 9: Polish & Deploy
- Error handling and edge cases
- Performance optimization
- Fly.io deployment
- End-to-end testing

---

## Files to Create

```
lib/
├── interview_studio/
│   ├── application.ex
│   ├── signals/
│   │   ├── user_utterance.ex
│   │   ├── host_utterance.ex
│   │   ├── phase_entered.ex
│   │   ├── phase_completed.ex
│   │   ├── insight_theme.ex
│   │   ├── insight_pattern.ex
│   │   ├── suggestion_probe.ex
│   │   ├── status_engagement.ex
│   │   ├── record_quote.ex
│   │   └── decision_*.ex
│   ├── pipeline/
│   │   ├── interview_fsm.ex
│   │   └── phases.ex
│   ├── agents/
│   │   ├── director.ex
│   │   ├── story_analyst.ex
│   │   ├── probe_coach.ex
│   │   ├── engagement_monitor.ex
│   │   └── scribe.ex
│   └── interview_bus.ex
├── interview_studio_web/
│   └── live/
│       ├── interview_live.ex      # User chat
│       └── debug_live.ex          # Debug view
```

---

## Verification Plan

### Functional Testing
1. Complete a full interview through all 6 phases
2. Verify each observer receives every utterance (check debug view)
3. Confirm Story Analyst identifies 2-3 themes
4. Confirm Probe Coach suggestions appear and Director uses at least one
5. Verify phase transitions occur correctly
6. Check final output includes transcript + themes

### Architecture Testing
1. Confirm observers process in parallel (timing in debug view)
2. Verify no observer blocks another
3. Test signal causality tracing
4. Simulate slow LLM response - Director should not freeze

### Integration Testing
1. Run on Fly.io deployment
2. Test with real users
3. Verify debug view updates in real-time

---

## Success Criteria

- [ ] User can complete coherent interview in ~10 minutes
- [ ] All 5 agents visible and active in debug view
- [ ] Themes emerge and influence interview flow
- [ ] Debug view shows full signal architecture
- [ ] Deployed and accessible on Fly.io
