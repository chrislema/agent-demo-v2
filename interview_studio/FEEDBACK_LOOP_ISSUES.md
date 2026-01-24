# Feedback Loop Issues to Fix

Created: 2026-01-24
Status: In progress (Issues 1, 2, 3 fixed)

## Summary

Ran automated feedback loop with 3 personas (cooperative, terse, frustrated). Found 4 key issues to address.

---

## Issue 1: Phase Tracking Returns :unknown - FIXED

**Priority: High** | **Status: FIXED** (2026-01-24)

**Root causes found:**
1. `Session.current_phase/1` returned raw atom, but `ConversationRunner` expected `{:ok, phase}` tuple
2. `SignalAnalyzer` looked for `data["phase"]` but FSM publishes `data["phase_name"]`
3. Evaluator compared atoms against string keys in validation logic

**Fixes applied:**
- `lib/interview_studio/session.ex` - Wrap return in `{:ok, phase}` tuple
- `lib/interview_studio_web/live/interview_live.ex` - Handle tuple return
- `lib/interview_studio/testing/feedback_loop/signal_analyzer.ex` - Check `phase_name` field
- `lib/interview_studio/testing/feedback_loop/evaluator.ex` - Normalize atoms to strings

**Results after fix:**
- Score: 85.5 → 99.0 (+13.5 points)
- Phase transition issues: 7 → 1
- `valid_sequence: true`
- `sequence: [:preparation, :opening, :core_questions]`

---

## Issue 2: Director Asks Repetitive Questions - FIXED

**Priority: High** | **Status: FIXED** (2026-01-24)

**Root causes found:**
1. High-priority probes from ProbeCoach took precedence over topic rotation
2. Dynamic question prompt didn't strongly enforce moving to NEW topics
3. LLM was generating natural follow-ups instead of topic transitions

**Fixes applied:**
1. `decide_core_questions_action` now prioritizes topic rotation during core_questions phase
2. Probing only happens AFTER all 5 core topics are covered
3. `dynamic_question.txt` prompt strongly enforces topic pivots with examples

**Results after fix:**
- Cooperative persona now covers all 5 topics: origin → passion → differentiation → moments → vision
- Score remained at 100 for cooperative persona
- Questions now properly transition between topics

---

## Issue 3: Frustrated Persona Fails - FIXED

**Priority: Medium** | **Status: FIXED** (2026-01-24)

**Root causes found:**
1. FSM didn't allow idempotent transitions (closing → closing failed with "Invalid transition")
2. Race condition: FSM shutting down while transition call still in progress
3. Session.do_transition didn't handle EXIT:shutdown gracefully

**Fixes applied:**
- `lib/interview_studio/pipeline/interview_fsm.ex` - Allow idempotent transitions (same phase → same phase is no-op)
- `lib/interview_studio/session.ex` - Catch EXIT:shutdown in do_transition, treat as success during cleanup

**Results after fix:**
- Frustrated persona correctly transitions: preparation → opening → core_questions → synthesis → closing
- Frustration detection working: mild → moderate escalation tracked
- End intent properly triggers graceful closing
- Note: OOM on small VMs is a separate resource concern (increase memory if needed)

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
