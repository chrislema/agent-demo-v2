# Interview Studio - Task List

This file tracks discrete implementation tasks with acceptance criteria and verification steps.
Each task should be independently completable and verifiable.

**Status Legend:**
- [ ] Not started
- [x] Complete
- [~] In progress

---

## Phase 1: Project Foundation

### 1.1 Phoenix Project Setup
- [x] **Task:** Create Phoenix project with LiveView
- **Acceptance Criteria:**
  - Phoenix 1.8+ project created in `interview_studio/` directory
  - LiveView enabled (no Ecto, no mailer, no dashboard)
  - Project compiles without errors
- **Verification:**
  ```bash
  cd interview_studio && mix compile
  # Expected: "Generated interview_studio app"
  ```

### 1.2 Jido Dependencies
- [x] **Task:** Add Jido framework dependencies
- **Acceptance Criteria:**
  - `jido`, `jido_ai`, `jido_chat` packages in mix.exs
  - All dependencies resolve and compile
- **Verification:**
  ```bash
  cd interview_studio && mix deps.get && mix compile
  # Expected: No errors, all Jido packages compiled
  ```

### 1.3 Git Repository
- [x] **Task:** Initialize git and push to GitHub
- **Acceptance Criteria:**
  - Local git repo initialized
  - Remote set to https://github.com/chrislema/agent-demo-v2
  - Initial commit pushed
- **Verification:**
  ```bash
  git remote -v
  # Expected: origin https://github.com/chrislema/agent-demo-v2.git
  ```

### 1.4 Fly.io App
- [x] **Task:** Create Fly.io deployment target
- **Acceptance Criteria:**
  - App `agentdemov2` created on Fly.io
  - `fly.toml` configured for single machine deployment
- **Verification:**
  ```bash
  flyctl apps list | grep agentdemov2
  # Expected: agentdemov2 listed
  ```

---

## Phase 2: Signal Infrastructure

### 2.1 Interview Bus
- [x] **Task:** Create central signal bus for agent communication
- **Acceptance Criteria:**
  - `InterviewStudio.InterviewBus` GenServer created
  - Supports publish/subscribe with pattern matching
  - Maintains signal history
  - Added to application supervision tree
- **Verification:**
  ```bash
  cd interview_studio && mix compile
  # Then in iex:
  # InterviewStudio.InterviewBus.subscribe("test.*")
  # InterviewStudio.InterviewBus.publish(%Jido.Signal{type: "test.foo", ...})
  # Expected: Subscriber receives signal
  ```

### 2.2 User Utterance Signal
- [x] **Task:** Define signal for user messages
- **Acceptance Criteria:**
  - `InterviewStudio.Signals.UserUtterance` module created
  - Uses `Jido.Signal` with schema validation
  - Fields: content, timestamp, phase_context
- **Verification:**
  ```bash
  mix compile
  # Expected: Module compiles, signal type is "interview.utterance.user"
  ```

### 2.3 Host Utterance Signal
- [x] **Task:** Define signal for interviewer messages
- **Acceptance Criteria:**
  - `InterviewStudio.Signals.HostUtterance` module created
  - Fields: content, timestamp, question_id
- **Verification:** `mix compile` succeeds

### 2.4 Phase Signals
- [x] **Task:** Define signals for phase transitions
- **Acceptance Criteria:**
  - `PhaseEntered` signal with phase_name, timestamp, context
  - `PhaseCompleted` signal with phase_name, summary, next_phase
- **Verification:** `mix compile` succeeds

### 2.5 Observer Insight Signals
- [x] **Task:** Define signals for observer insights
- **Acceptance Criteria:**
  - `InsightTheme` - theme, evidence, confidence
  - `InsightPattern` - pattern_type, instances, significance
- **Verification:** `mix compile` succeeds

### 2.6 Observer Action Signals
- [x] **Task:** Define signals for observer suggestions and status
- **Acceptance Criteria:**
  - `SuggestionProbe` - topic, rationale, suggested_question, priority
  - `StatusEngagement` - level, indicators, recommendation, trend
- **Verification:** `mix compile` succeeds

### 2.7 Record Signals
- [x] **Task:** Define signals for scribe records
- **Acceptance Criteria:**
  - `RecordQuote` - quote, speaker, tags, phase
  - `RecordSummary` - phase, summary_text, key_points
- **Verification:** `mix compile` succeeds

### 2.8 Director Decision Signals
- [x] **Task:** Define signals for director decisions
- **Acceptance Criteria:**
  - `DecisionAsk` - question, rationale, source
  - `DecisionTransition` - to_phase, reason
- **Verification:** `mix compile` succeeds

---

## Phase 3: Pipeline FSM

### 3.1 Interview FSM
- [x] **Task:** Create finite state machine for interview phases
- **Acceptance Criteria:**
  - `InterviewStudio.Pipeline.InterviewFSM` GenServer created
  - Manages 6 phases: preparation, opening, core_questions, probing, synthesis, closing
  - Validates transitions (only allowed paths)
  - Emits phase signals on transitions
  - Registered via SessionRegistry
- **Verification:**
  ```elixir
  # In iex:
  {:ok, _} = InterviewStudio.Pipeline.InterviewFSM.start_link(session_id: "test")
  :preparation = InterviewStudio.Pipeline.InterviewFSM.current_phase("test")
  {:ok, :opening} = InterviewStudio.Pipeline.InterviewFSM.transition("test", :opening, "ready")
  {:error, _} = InterviewStudio.Pipeline.InterviewFSM.transition("test", :closing, "skip") # invalid
  ```

### 3.2 Phase Definitions
- [x] **Task:** Create phase configuration with question banks
- **Acceptance Criteria:**
  - `InterviewStudio.Pipeline.Phases` module created
  - Each phase has: name, description, entry/exit criteria, questions
  - Core questions cover: origin, passion, differentiation, moments, vision
  - Opening and closing have scripted questions
- **Verification:**
  ```elixir
  Phases.questions(:core_questions) |> length() >= 5
  Phases.get(:opening).questions |> length() >= 1
  ```

---

## Phase 4: Director Agent

### 4.1 Director Core
- [x] **Task:** Create Director agent orchestrator
- **Acceptance Criteria:**
  - `InterviewStudio.Agents.Director` GenServer created
  - Maintains state: current_phase, questions_asked/remaining, active_themes, pending_probes, engagement_level, conversation_history
  - Subscribes to user utterances, phase changes, observer signals
  - Registered via SessionRegistry
- **Verification:**
  ```elixir
  {:ok, _} = Director.start_link(session_id: "test")
  state = Director.get_state("test")
  assert state.current_phase == :preparation
  ```

### 4.2 Director Decision Logic
- [x] **Task:** Implement decision-making for next action
- **Acceptance Criteria:**
  - `get_next_action/1` returns appropriate action based on state
  - In opening: returns opening question
  - In core_questions: returns next question or high-priority probe
  - In probing: returns probe questions from pending list
  - In synthesis: returns synthesis action with themes
  - Critical engagement triggers early closing
- **Verification:**
  ```elixir
  # Start director in opening phase
  action = Director.get_next_action("test")
  assert action.type == :ask
  ```

### 4.3 Director LLM Integration
- [ ] **Task:** Add LLM-powered response generation
- **Acceptance Criteria:**
  - Director can generate natural language responses using jido_ai
  - Responses incorporate conversation context
  - System prompt establishes interviewer persona
  - Configurable provider/model
- **Verification:**
  ```elixir
  # Requires ANTHROPIC_API_KEY
  response = Director.generate_response("test", :ask, %{question: "test"})
  assert is_binary(response)
  ```

---

## Phase 5: Observer Agents

### 5.1 Scribe Agent
- [ ] **Task:** Create Scribe agent for documentation
- **Acceptance Criteria:**
  - `InterviewStudio.Agents.Scribe` GenServer created
  - Subscribes to all utterances and phase changes
  - Maintains full transcript with timestamps
  - Tags notable quotes
  - Generates phase summaries
  - Emits RecordQuote and RecordSummary signals
- **Verification:**
  ```elixir
  {:ok, _} = Scribe.start_link(session_id: "test")
  # Publish test utterance
  InterviewBus.publish(user_utterance_signal)
  # Check scribe recorded it
  state = Scribe.get_state("test")
  assert length(state.transcript) > 0
  ```

### 5.2 Story Analyst Agent
- [ ] **Task:** Create Story Analyst for theme extraction
- **Acceptance Criteria:**
  - `InterviewStudio.Agents.StoryAnalyst` GenServer created
  - Subscribes to user and host utterances
  - Uses LLM to identify themes and patterns
  - Accumulates themes over conversation
  - Emits InsightTheme and InsightPattern signals
- **Verification:**
  ```elixir
  {:ok, _} = StoryAnalyst.start_link(session_id: "test")
  # Publish meaningful utterance
  # Check for emitted theme signals
  ```

### 5.3 Probe Coach Agent
- [ ] **Task:** Create Probe Coach for follow-up suggestions
- **Acceptance Criteria:**
  - `InterviewStudio.Agents.ProbeCoach` GenServer created
  - Subscribes to user utterances
  - Uses LLM to identify probe opportunities
  - Detects: emotional language, vague statements, contradictions, tangents
  - Emits SuggestionProbe signals with priority
- **Verification:**
  ```elixir
  {:ok, _} = ProbeCoach.start_link(session_id: "test")
  # Publish vague utterance like "It was just... different, you know?"
  # Check for emitted probe suggestion
  ```

### 5.4 Engagement Monitor Agent
- [ ] **Task:** Create Engagement Monitor for reading the room
- **Acceptance Criteria:**
  - `InterviewStudio.Agents.EngagementMonitor` GenServer created
  - Subscribes to user utterances
  - Uses heuristics (response length, keywords) - NO LLM
  - Tracks engagement level: high, medium, low, critical
  - Emits StatusEngagement signals on significant changes
- **Verification:**
  ```elixir
  {:ok, _} = EngagementMonitor.start_link(session_id: "test")
  # Publish short, terse responses
  state = EngagementMonitor.get_state("test")
  assert state.level in [:low, :critical]
  ```

---

## Phase 6: Session Orchestration

### 6.1 Interview Session
- [ ] **Task:** Create session manager to coordinate all agents
- **Acceptance Criteria:**
  - `InterviewStudio.Session` module created
  - `start_session/1` starts FSM, Director, and all observers
  - `stop_session/1` cleanly stops all agents
  - `get_session_state/1` returns combined state
  - Uses DynamicSupervisor for agent lifecycle
- **Verification:**
  ```elixir
  {:ok, session_id} = Session.start_session()
  state = Session.get_session_state(session_id)
  assert state.fsm_phase == :preparation
  assert state.director != nil
  :ok = Session.stop_session(session_id)
  ```

### 6.2 Message Flow Integration
- [ ] **Task:** Wire up complete message flow
- **Acceptance Criteria:**
  - User message -> Director -> publishes signal -> all observers receive
  - Observers publish insights -> Director receives
  - Director decides action -> FSM transitions if needed
  - Response returned to caller
- **Verification:**
  ```elixir
  {:ok, session_id} = Session.start_session()
  Session.transition_to(session_id, :opening)
  response = Session.process_message(session_id, "Hello!")
  assert is_binary(response)
  ```

---

## Phase 7: Chat Interface

### 7.1 Interview LiveView
- [ ] **Task:** Create main interview chat interface
- **Acceptance Criteria:**
  - `InterviewStudioWeb.InterviewLive` LiveView created
  - Clean chat UI with message input
  - Displays conversation history
  - Real-time updates via PubSub
  - Starts new session on mount
- **Verification:**
  - Visit http://localhost:4000/interview
  - See chat interface
  - Send message and receive response

### 7.2 Message Handling
- [ ] **Task:** Wire LiveView to session
- **Acceptance Criteria:**
  - Form submission sends message to Director
  - Response displayed in chat
  - Loading state while waiting for LLM
  - Error handling for failures
- **Verification:**
  - Complete a short conversation
  - Messages appear in order
  - No errors in console

### 7.3 Session Lifecycle
- [ ] **Task:** Handle session start/end in LiveView
- **Acceptance Criteria:**
  - New session created on page load
  - Session cleaned up on disconnect
  - "Interview complete" state when reaching closing phase
  - Option to start new interview
- **Verification:**
  - Complete interview through all phases
  - See completion message
  - Refresh starts new session

---

## Phase 8: Debug Interface

### 8.1 Debug LiveView
- [ ] **Task:** Create debug view showing agent activity
- **Acceptance Criteria:**
  - `InterviewStudioWeb.DebugLive` LiveView created
  - Shows current phase in visual FSM diagram
  - Displays live signal stream (filterable)
  - Shows agent status panels
- **Verification:**
  - Visit http://localhost:4000/debug
  - See phase diagram and signal stream

### 8.2 Signal Stream Component
- [ ] **Task:** Create real-time signal display
- **Acceptance Criteria:**
  - LiveComponent showing signal stream
  - Color-coded by signal category
  - Filterable by type pattern
  - Shows timestamp, type, and data preview
- **Verification:**
  - Conduct interview in separate tab
  - See signals appear in real-time

### 8.3 Agent Status Panels
- [ ] **Task:** Create agent status displays
- **Acceptance Criteria:**
  - Panel for each agent showing current state
  - Director: phase, pending questions, themes
  - Scribe: transcript length, quote count
  - Analyst: identified themes
  - Probe Coach: pending suggestions
  - Engagement: current level, trend
- **Verification:**
  - Panels update as interview progresses

### 8.4 Phase Diagram
- [ ] **Task:** Create visual FSM representation
- **Acceptance Criteria:**
  - Shows all 6 phases as nodes
  - Current phase highlighted
  - Transitions shown as arrows
  - Phase history visible
- **Verification:**
  - Diagram updates on phase transitions

---

## Phase 9: Polish & Deploy

### 9.1 Error Handling
- [ ] **Task:** Add comprehensive error handling
- **Acceptance Criteria:**
  - LLM failures don't crash agents
  - Graceful fallbacks for missing responses
  - Errors logged with context
  - User sees friendly error messages
- **Verification:**
  - Simulate LLM timeout
  - App continues functioning

### 9.2 Configuration
- [ ] **Task:** Externalize configuration
- **Acceptance Criteria:**
  - LLM provider/model configurable via env vars
  - API keys loaded from environment
  - Fly.io secrets configured
- **Verification:**
  ```bash
  flyctl secrets list
  # Expected: ANTHROPIC_API_KEY set
  ```

### 9.3 Dockerfile
- [ ] **Task:** Create production Dockerfile
- **Acceptance Criteria:**
  - Multi-stage Dockerfile for Elixir release
  - Assets compiled
  - Health check endpoint
- **Verification:**
  ```bash
  docker build -t interview_studio .
  docker run -p 4000:4000 interview_studio
  # App accessible at localhost:4000
  ```

### 9.4 Deploy to Fly.io
- [ ] **Task:** Deploy application
- **Acceptance Criteria:**
  - App deployed to agentdemov2.fly.dev
  - Health checks passing
  - Interview flow works end-to-end
- **Verification:**
  - Visit https://agentdemov2.fly.dev
  - Complete interview successfully

---

## Summary

| Phase | Tasks | Complete |
|-------|-------|----------|
| 1. Foundation | 4 | 4/4 |
| 2. Signals | 8 | 8/8 |
| 3. Pipeline | 2 | 2/2 |
| 4. Director | 3 | 1/3 |
| 5. Observers | 4 | 0/4 |
| 6. Orchestration | 2 | 0/2 |
| 7. Chat UI | 3 | 0/3 |
| 8. Debug UI | 4 | 0/4 |
| 9. Deploy | 4 | 0/4 |
| **Total** | **34** | **15/34** |
