# Interview Studio - Fix Plan

## Task Tracking
**Primary task list**: `docs/tasks.md`

All tasks with acceptance criteria and verification steps are maintained in `docs/tasks.md`.
This file provides a quick reference to current priorities.

---

## Current Priority Queue

### Phase 4: Director Agent (In Progress)
- [x] 4.1 Director Core - skeleton created
- [ ] 4.2 Director Decision Logic - complete decision implementation
- [ ] 4.3 Director LLM Integration - add jido_ai response generation

### Phase 5: Observer Agents (Next)
- [ ] 5.1 Scribe Agent - transcript and quotes
- [ ] 5.2 Story Analyst Agent - theme extraction (LLM)
- [ ] 5.3 Probe Coach Agent - follow-up suggestions (LLM)
- [ ] 5.4 Engagement Monitor Agent - heuristic-based

### Phase 6: Session Orchestration
- [ ] 6.1 Interview Session - coordinate all agents
- [ ] 6.2 Message Flow Integration - wire up complete flow

### Phase 7: Chat Interface
- [ ] 7.1 Interview LiveView
- [ ] 7.2 Message Handling
- [ ] 7.3 Session Lifecycle

### Phase 8: Debug Interface
- [ ] 8.1 Debug LiveView
- [ ] 8.2 Signal Stream Component
- [ ] 8.3 Agent Status Panels
- [ ] 8.4 Phase Diagram

### Phase 9: Deploy
- [ ] 9.1 Error Handling
- [ ] 9.2 Configuration
- [ ] 9.3 Dockerfile
- [ ] 9.4 Deploy to Fly.io

---

## Progress Summary
- **Complete**: Phases 1-3 (Foundation, Signals, Pipeline)
- **In Progress**: Phase 4 (Director)
- **Remaining**: Phases 5-9

## Notes
- Use `mix compile` to verify Elixir code
- Run from `interview_studio/` directory
- LLM features require ANTHROPIC_API_KEY
- See `docs/tasks.md` for full acceptance criteria
