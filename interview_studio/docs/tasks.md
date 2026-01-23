# Multi-Agent Architecture - Task List

This file tracks implementation tasks for transforming the Interview Studio from a sequential pipeline into a true multi-agent collaborative system.

**Reference:** See `multi-agent-architecture-proposal.md` for full architectural details.

**Status Legend:**
- [ ] Not started
- [x] Complete
- [~] In progress

---

## Phase 1: Parallel Analysis with Synchronization

### 1.1 Insight Gathering Function
- [x] **Task:** Create function to gather insights from all agents with timeout
- **Acceptance Criteria:**
  - `gather_insights/2` function in Session module
  - Triggers all observer agents to analyze in parallel
  - Waits for responses with configurable timeout (default 3000ms)
  - Returns consolidated insights map: `%{themes: [...], probes: [...], engagement: :level}`
  - Gracefully handles agent timeouts (uses partial results)
- **Verification:**
  ```elixir
  insights = Session.gather_insights(session_id, timeout: 3000)
  assert Map.has_key?(insights, :themes)
  assert Map.has_key?(insights, :probes)
  assert Map.has_key?(insights, :engagement)
  ```

### 1.2 Synchronization Barrier in Message Flow
- [x] **Task:** Modify message processing to wait for agent insights before Director responds
- **Acceptance Criteria:**
  - `process_message/2` triggers parallel analysis BEFORE Director decides
  - Director receives all agent insights as input to decision
  - Response is blocked until insights gathered (or timeout)
  - Current flow: User Message → Parallel Analysis → Synthesis → Response
- **Verification:**
  ```elixir
  # Director should receive insights in get_next_action
  response = Session.process_message(session_id, "test message")
  # Check logs show parallel analysis completed before response
  ```

### 1.3 Agent Insight Request/Response Protocol
- [x] **Task:** Add request/response signals for synchronous insight gathering
- **Acceptance Criteria:**
  - `insight.request` signal type triggers immediate analysis
  - `insight.response` signal type returns analysis results
  - Each agent responds to requests with current insights
  - Correlation ID links requests to responses
- **Verification:**
  ```elixir
  InterviewBus.publish(%Signal{type: "insight.request", data: %{correlation_id: "123"}})
  # All agents publish insight.response with matching correlation_id
  ```

---

## Phase 2: Dynamic Question Generation

### 2.1 Remove Static Question Bank Dependency
- [x] **Task:** Refactor Director to not rely on static question bank for core questions
- **Acceptance Criteria:**
  - Director no longer picks questions from `Phases.questions/1` during core_questions phase
  - Question bank retained only as fallback/inspiration
  - Director state tracks "topics to explore" rather than "questions to ask"
- **Verification:**
  ```elixir
  state = Director.get_state(session_id)
  # Should have :topics_to_explore instead of :questions_remaining
  ```

### 2.2 Dynamic Question Generation Prompt
- [x] **Task:** Create LLM prompt that generates questions from collective insights
- **Acceptance Criteria:**
  - Prompt includes: conversation history, discovered themes, probe suggestions, engagement level, phase goals
  - Question emerges from synthesis of all inputs
  - Prompt explicitly forbids generic questions
  - Questions must reference specific content from the conversation
- **Verification:**
  ```elixir
  # Generate question with rich context
  question = Director.generate_dynamic_question(session_id, insights)
  # Question should reference specific themes/content, not be generic
  ```

### 2.3 Context-Aware Question Adaptation
- [x] **Task:** Implement question adaptation based on engagement level
- **Acceptance Criteria:**
  - High engagement: Ask deeper, more probing questions
  - Medium engagement: Balanced questions maintaining flow
  - Low engagement: Lighter questions, offer to shift topics
  - Critical engagement: Wrap-up cues, respect user's energy
- **Verification:**
  ```elixir
  # Same topic, different engagement levels produce different questions
  q_high = Director.generate_question(session_id, %{engagement: :high, topic: "career"})
  q_low = Director.generate_question(session_id, %{engagement: :low, topic: "career"})
  assert q_high != q_low
  ```

---

## Phase 3: Agent-to-Agent Communication

### 3.1 Direct Agent Messaging
- [x] **Task:** Add `target` field to signals for direct agent-to-agent messages
- **Acceptance Criteria:**
  - Signals can specify `target: "agent_name"` for direct delivery
  - InterviewBus routes targeted signals only to specified agent
  - Agents can subscribe to direct messages: `subscribe("*.*.target:probe_coach")`
  - Broadcast signals (no target) work as before
- **Verification:**
  ```elixir
  InterviewBus.publish(%Signal{
    type: "analyst.insight.theme",
    source: "story_analyst",
    target: "probe_coach",
    data: %{theme: "resilience"}
  })
  # Only probe_coach receives this signal
  ```

### 3.2 Story Analyst → Probe Coach Communication
- [x] **Task:** Story Analyst shares discovered themes with Probe Coach
- **Acceptance Criteria:**
  - When Story Analyst identifies a theme, it notifies Probe Coach
  - Probe Coach receives theme and generates relevant probe suggestions
  - Probe suggestions are theme-aware, not just utterance-aware
- **Verification:**
  ```elixir
  # Story Analyst discovers "resilience" theme
  # Probe Coach should generate probes specifically about resilience
  probes = ProbeCoach.get_pending_probes(session_id)
  assert Enum.any?(probes, fn p -> String.contains?(p.rationale, "resilience") end)
  ```

### 3.3 Engagement Monitor Broadcast Influence
- [x] **Task:** Engagement Monitor can broadcast signals that influence all agents
- **Acceptance Criteria:**
  - Critical engagement triggers broadcast to all agents
  - Agents adjust behavior based on engagement signals
  - Story Analyst: Pauses deep analysis on low engagement
  - Probe Coach: Reduces probe suggestions on critical engagement
  - Director: Initiates wrap-up on critical engagement
- **Verification:**
  ```elixir
  # Simulate critical engagement
  EngagementMonitor.set_level(session_id, :critical)
  # Director should start wrap-up sequence
  action = Director.get_next_action(session_id)
  assert action.type in [:wrap_up, :transition_to_closing]
  ```

### 3.4 Probe Coach → Director Priority Signals
- [x] **Task:** Probe Coach can mark probes as high-priority for immediate attention
- **Acceptance Criteria:**
  - Probes have priority levels: :low, :medium, :high, :urgent
  - Urgent probes interrupt normal question flow
  - Director weighs probe priority in decision-making
  - High-priority probes surface in Director's next action
- **Verification:**
  ```elixir
  ProbeCoach.suggest_probe(session_id, %{
    topic: "brother relationship",
    priority: :urgent,
    rationale: "emotional content detected"
  })
  action = Director.get_next_action(session_id)
  assert action.source == :probe_coach
  ```

---

## Phase 4: Consensus Mechanisms

### 4.1 Phase Transition Voting
- [ ] **Task:** Implement agent voting for phase transitions
- **Acceptance Criteria:**
  - Before major transitions, Director polls agents for readiness
  - Each agent votes: ready, not_ready, or abstain
  - Transition requires majority (2/3 agents) ready
  - Agents provide rationale with vote
- **Verification:**
  ```elixir
  votes = Director.poll_transition_readiness(session_id, :synthesis)
  # Returns: %{story_analyst: {:ready, "themes complete"}, probe_coach: {:not_ready, "pending probes"}, ...}
  ```

### 4.2 Weighted Consensus for Critical Decisions
- [ ] **Task:** Implement weighted voting for interview-ending decisions
- **Acceptance Criteria:**
  - Engagement Monitor has higher weight for "end interview" decisions
  - Story Analyst has higher weight for "synthesis ready" decisions
  - Weights configurable per decision type
  - Consensus threshold configurable (default: 60%)
- **Verification:**
  ```elixir
  consensus = Director.check_consensus(session_id, :end_interview)
  # Engagement Monitor's :critical vote should heavily influence result
  ```

### 4.3 Disagreement Resolution
- [ ] **Task:** Handle agent disagreements gracefully
- **Acceptance Criteria:**
  - When agents disagree, Director makes final call with logged rationale
  - Disagreements visible in debug panel
  - Director can override consensus in exceptional cases
  - Override reasons tracked for analysis
- **Verification:**
  ```elixir
  # Force disagreement scenario
  # Verify Director resolves and logs decision rationale
  ```

---

## Phase 5: UI Visibility of Collaboration

### 5.1 Agent Communication Log in Debug Panel
- [ ] **Task:** Show agent-to-agent messages in debug panel
- **Acceptance Criteria:**
  - Debug panel shows inter-agent communication
  - Format: `[timestamp] Source → Target: message`
  - Different colors for different communication types
  - Filterable by source/target agent
- **Verification:**
  - Conduct interview
  - See agent-to-agent messages in debug panel
  - Messages show clear source → target flow

### 5.2 Synthesis Visualization
- [ ] **Task:** Show how Director synthesizes agent inputs
- **Acceptance Criteria:**
  - Before each Director response, show inputs received
  - Visual: Themes + Probes + Engagement → Question
  - Highlight which inputs influenced the question
  - Show "decision rationale" from Director
- **Verification:**
  - Each Director response shows contributing factors
  - Can trace why a specific question was asked

### 5.3 Real-Time Collaboration Indicators
- [ ] **Task:** Add visual indicators showing agents are actively collaborating
- **Acceptance Criteria:**
  - Pulsing indicators when agents are analyzing
  - Arrows/lines showing active communication
  - "Synthesizing..." state visible to user
  - Timestamp showing when each agent last contributed
- **Verification:**
  - Visual feedback during parallel analysis phase
  - Clear indication that multiple agents are working

### 5.4 Agent Influence Attribution
- [ ] **Task:** Show which agent(s) influenced each interviewer question
- **Acceptance Criteria:**
  - Each question tagged with contributing agents
  - Hover/click shows detailed attribution
  - Format: "This question was influenced by: Story Analyst (resilience theme), Probe Coach (brother suggestion)"
- **Verification:**
  - Every non-scripted question has visible attribution
  - Attribution matches actual agent contributions

---

## Phase 6: Validation & Testing

### 6.1 Pipeline Comparison Test
- [ ] **Task:** Create test proving system can't be replicated as simple pipeline
- **Acceptance Criteria:**
  - Test runs same conversation through pipeline vs multi-agent
  - Outputs are measurably different
  - Multi-agent version produces more contextually relevant questions
  - Document specific behaviors impossible in pipeline
- **Verification:**
  ```elixir
  pipeline_result = PipelineSimulator.run(conversation)
  multiagent_result = Session.run(conversation)
  assert pipeline_result != multiagent_result
  # Specific: multi-agent references themes pipeline couldn't detect
  ```

### 6.2 Agent Removal Impact Test
- [ ] **Task:** Test that removing each agent noticeably changes output
- **Acceptance Criteria:**
  - Run same conversation with each agent disabled
  - Document specific changes when each agent is missing
  - Story Analyst missing: No theme-based questions
  - Probe Coach missing: No follow-up probes
  - Engagement Monitor missing: No energy-based adaptation
- **Verification:**
  ```elixir
  full_result = Session.run(conversation, agents: :all)
  no_analyst = Session.run(conversation, agents: [:probe_coach, :engagement])
  # Questions in no_analyst should lack theme references
  ```

### 6.3 Emergent Behavior Documentation
- [ ] **Task:** Document examples of emergent behavior from agent collaboration
- **Acceptance Criteria:**
  - Capture 5+ examples where combined output > individual outputs
  - Show specific cases where agent interaction produced unique insights
  - Example: "Brother dynamic + resilience theme → probe about sibling influence on career"
- **Verification:**
  - Each example clearly shows inputs from multiple agents
  - Combined insight not present in any single agent's output

### 6.4 Dynamic Question Uniqueness Test
- [ ] **Task:** Verify no two similar interviews produce identical questions
- **Acceptance Criteria:**
  - Run 10 interviews with similar content
  - Core questions should all be different (adapted to context)
  - Only scripted opening/closing can match
  - Measure question diversity score
- **Verification:**
  ```elixir
  questions = for _ <- 1..10, do: run_interview_collect_questions(similar_content)
  unique_questions = questions |> List.flatten() |> Enum.uniq()
  assert length(unique_questions) / length(List.flatten(questions)) > 0.8
  ```

---

## Phase 7: Performance & Reliability

### 7.1 Parallel Analysis Performance
- [ ] **Task:** Ensure parallel analysis doesn't significantly increase response time
- **Acceptance Criteria:**
  - Total response time < 5 seconds (including LLM calls)
  - Parallel analysis adds < 500ms over sequential
  - Timeout handling prevents hung responses
  - Performance metrics logged
- **Verification:**
  ```elixir
  {time, _result} = :timer.tc(fn -> Session.process_message(session_id, msg) end)
  assert time < 5_000_000  # 5 seconds in microseconds
  ```

### 7.2 Agent Failure Isolation
- [ ] **Task:** Ensure single agent failure doesn't break the system
- **Acceptance Criteria:**
  - If Story Analyst crashes, interview continues
  - Director uses partial insights when agents fail
  - Failed agents logged and optionally restarted
  - User experience unaffected by background failures
- **Verification:**
  ```elixir
  # Kill Story Analyst mid-interview
  Process.exit(story_analyst_pid, :kill)
  # Interview should continue with remaining agents
  response = Session.process_message(session_id, "test")
  assert is_binary(response)
  ```

### 7.3 Insight Caching
- [ ] **Task:** Cache recent insights to avoid redundant analysis
- **Acceptance Criteria:**
  - Recent themes/probes cached for quick retrieval
  - Cache invalidated on new user message
  - Cache reduces LLM calls for repeated queries
  - Cache TTL configurable
- **Verification:**
  ```elixir
  # First call triggers analysis
  insights1 = Session.gather_insights(session_id)
  # Second call within TTL uses cache
  insights2 = Session.gather_insights(session_id)
  # LLM call count should be same
  ```

---

## Summary

| Phase | Tasks | Complete |
|-------|-------|----------|
| 1. Parallel Analysis | 3 | 3/3 |
| 2. Dynamic Questions | 3 | 3/3 |
| 3. Agent Communication | 4 | 4/4 |
| 4. Consensus Mechanisms | 3 | 0/3 |
| 5. UI Visibility | 4 | 0/4 |
| 6. Validation & Testing | 4 | 0/4 |
| 7. Performance | 3 | 0/3 |
| **Total** | **24** | **0/24** |

---

## Success Criteria Checklist

Before considering this work complete, verify:

- [ ] **Can't replicate with pipeline**: No sequence of LLM calls could produce the same behavior
- [ ] **Agent removal changes output**: Disabling any agent noticeably affects interview quality
- [ ] **Visible collaboration**: Debug panel shows agents influencing each other in real-time
- [ ] **Dynamic questions**: No two interviews with similar content produce identical questions
- [ ] **Whole > sum of parts**: Combined agent output demonstrably better than any single agent
