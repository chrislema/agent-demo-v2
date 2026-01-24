# Feedback Loop Issues to Fix

Created: 2026-01-24
Status: Ready for implementation

## Summary

Ran automated feedback loop with 3 personas (cooperative, terse, frustrated). Found 4 key issues to address.

---

## Issue 1: Phase Tracking Returns :unknown

**Priority: High**

All phases show as `:unknown` instead of actual phases (opening, core_questions, probing, etc.)

**Evidence:**
- `phase: :unknown` for all exchanges
- `sequence: ["unknown", "unknown", "unknown", "unknown"]`
- 6 "Poor Phase Transitions" issues detected

**Root cause hypothesis:**
- `ConversationRunner.get_current_phase/1` calls `Session.current_phase/1`
- The initial "[Session started]" message may not trigger proper FSM transitions
- FSM may not be transitioning during automated conversations

**Files to check:**
- `lib/interview_studio/testing/feedback_loop/conversation_runner.ex:185-189`
- `lib/interview_studio/session.ex` - `current_phase/1`
- `lib/interview_studio/pipeline/interview_fsm.ex`

---

## Issue 2: Director Asks Repetitive Questions

**Priority: High**

Director stays on same topic, doesn't rotate through origin → passion → differentiation → moments → vision

**Evidence from cooperative persona:**
- 5 exchanges ALL about "parents' support" and "risk-taking"
- Never moved from origin topic
- Repetitive patterns: "Can you elaborate...", "I'd love to dive deeper..."

**Root cause hypothesis:**
- Director prompt doesn't enforce topic rotation strongly enough
- `topics_explored` tracking may have issues
- Themes (47 discovered) and probes (124 suggested) not being used

**Files to tune:**
- `priv/domains/interview/prompts/director/*.txt`
- `priv/domains/interview/heuristics/director.yaml`
- `lib/interview_studio/agents/director.ex` - `get_next_action` logic

---

## Issue 3: Frustrated Persona Fails

**Priority: Medium**

Frustrated persona conversation failed with process_message error

**Evidence:**
- 1 of 3 runs failed
- Error: `Process Message Failed: 1`
- Score: 0 for frustrated persona

**Root cause hypothesis:**
- Short, hostile responses may trigger edge cases
- Null/empty handling issues in agents
- SentimentAgent or EngagementMonitor may not handle frustration correctly

**Files to check:**
- `lib/interview_studio/agents/sentiment_agent.ex`
- `lib/interview_studio/agents/engagement_monitor.ex`
- `lib/interview_studio/session.ex` - error handling

---

## Issue 4: Director Ignores Discovered Themes/Probes

**Priority: Medium**

StoryAnalyst discovers themes, ProbeCoach suggests probes, but Director doesn't use them

**Evidence:**
- 47 themes discovered
- 124 probes suggested
- Director questions don't reference these insights

**Root cause hypothesis:**
- `last_insights` not properly used in Director
- Prompt template may not include theme/probe context
- Insight passing may be broken

**Files to check:**
- `lib/interview_studio/agents/director.ex` - `synthesize_insights/2`
- `priv/domains/interview/prompts/director/ask_dynamic.txt`
- `lib/interview_studio/session.ex` - `gather_insights/2`

---

## Next Steps

1. Fix Issue 1 (phase tracking) first - this affects all evaluations
2. Fix Issue 2 (repetitive questions) - highest impact on interview quality
3. Investigate Issue 3 (frustrated persona) - may reveal other edge cases
4. Fix Issue 4 (theme usage) - improves agent collaboration

## Verification

After fixes, run:
```bash
fly ssh console -a agentdemov2 -C "/app/bin/interview_studio remote"
# Then in IEx:
alias InterviewStudio.Testing.FeedbackLoop.{BatchRunner, ReportGenerator}
results = BatchRunner.run(count: 5, personas: [:cooperative, :terse, :frustrated], max_exchanges: 8)
IO.puts(ReportGenerator.generate(results, :cli))
```

Expected improvements:
- Phases should show actual values (opening, core_questions, etc.)
- Questions should rotate through all 5 topics
- Frustrated persona should complete without errors
- Score should improve from 88 to 90+
