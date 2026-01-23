# Infrastructure Generalization Tracker

**Goal:** Transform domain-locked interview system into generic multi-agent framework with swappable agents.

**Current Grade:** B (75/100) - Improved from C+ after Phase 1
**Target Grade:** A- (85/100) after Phase 1-3

---

## Phase 1: Quick Wins - Externalize Simple Configs
**Status:** COMPLETE
**Completed:** 2026-01-23

### Shared Infrastructure Created

**New File:** `lib/interview_studio/config_loader.ex`
- Centralized YAML config loading
- `load/1`, `load/2`, `load_with_defaults/2` functions
- Deep merge support for nested config
- Automatic key atomization

**New Dependency:** `yaml_elixir ~> 2.9` added to `mix.exs`

---

### Task 1.1: Timer Agent Config
**Status:** COMPLETE

**File:** `lib/interview_studio/agents/timer_agent.ex`
**Config:** `priv/config/timer.yaml`

**Changes made:**
- [x] Created `priv/config/timer.yaml` with milestones, tick_interval, wrap_up thresholds, recommendations
- [x] Added `@default_config` fallback
- [x] Added `:config` to struct
- [x] Updated `init/1` to load config via `ConfigLoader.load_with_defaults(:timer, @default_config)`
- [x] Updated `handle_info(:tick, ...)` to use `config[:milestones]`, `config[:tick_interval_ms]`
- [x] Updated `vote_transition` to use `config[:wrap_up]` thresholds
- [x] Updated `emit_timer_signal/3` to use `config[:recommendations]`

---

### Task 1.2: Scribe Agent Config
**Status:** COMPLETE

**File:** `lib/interview_studio/agents/scribe.ex`
**Config:** `priv/config/scribe.yaml`

**Changes made:**
- [x] Created `priv/config/scribe.yaml` with quote_detection settings
- [x] Added `@default_config` fallback with emotional_words, reflection_phrases, key_phrases
- [x] Added `:config` to struct
- [x] Updated `init/1` to load config via `ConfigLoader.load_with_defaults(:scribe, @default_config)`
- [x] Updated `maybe_tag_quote/2` to use `config[:quote_detection][:min_length]`
- [x] Updated `contains_emotional_language?/2` to accept and use config
- [x] Updated `contains_self_reflection?/2` to accept and use config
- [x] Updated `contains_key_phrases?/2` to accept and use config

---

### Task 1.3: Engagement Monitor Config
**Status:** COMPLETE

**File:** `lib/interview_studio/agents/engagement_monitor.ex`
**Config:** `priv/config/engagement.yaml`

**Changes made:**
- [x] Created `priv/config/engagement.yaml` with all markers, scoring, thresholds, recommendations, alerts
- [x] Added `@default_config` fallback with full config structure
- [x] Added `:config` to struct
- [x] Updated `init/1` to load config via `ConfigLoader.load_with_defaults(:engagement, @default_config)`
- [x] Updated `analyze_response/2` to use config for thresholds
- [x] Updated `has_enthusiasm?/2` to use `config[:enthusiasm_markers]`
- [x] Updated `has_resistance?/2` to use `config[:resistance_markers]` and thresholds
- [x] Updated `wants_to_wrap_up?/2` to use `config[:wrap_up_markers]`
- [x] Updated `has_elaboration?/2` to use `config[:elaboration_markers]`
- [x] Updated `estimate_sentiment/2` to use `config[:sentiment]`
- [x] Updated `calculate_engagement/2` to use `config[:scoring]` and `config[:level_thresholds]`
- [x] Updated `emit_status/1` to use `config[:recommendations]`
- [x] Updated `engagement_alert_message/3` to use `config[:alerts]`

---

### Phase 1 Completion Checklist
- [x] All three config files created in `priv/config/`
- [x] Shared `ConfigLoader` module created
- [x] All three agents load from config
- [x] Compilation successful
- [ ] Commit, push, deploy
- [ ] Compact conversation

---

## Phase 2: Prompt Externalization
**Status:** NOT STARTED
**Estimated Time:** 8-12 hours

### Task 2.1: Create Prompt Template System
**Status:** NOT STARTED
**New File:** `lib/interview_studio/prompt_loader.ex`

**Purpose:** Load prompt templates from files with variable substitution

```elixir
defmodule InterviewStudio.PromptLoader do
  def load(domain, agent, prompt_name) do
    # Load from priv/domains/{domain}/prompts/{agent}/{prompt_name}.txt
    # Support {{variable}} substitution
  end
end
```

**Changes needed:**
- [ ] Create `PromptLoader` module
- [ ] Support `{{variable}}` placeholder substitution
- [ ] Support fallback to default domain if specific not found
- [ ] Add caching for performance

---

### Task 2.2: Director Prompts
**Status:** NOT STARTED
**File:** `lib/interview_studio/agents/director.ex`

**Current (hardcoded at lines 928-948, 1015-1060):**
- System prompt with interview rules
- Dynamic question generation prompt
- Topic descriptions

**Target:** Load from `priv/domains/interview/prompts/director/`
```
system.txt
dynamic_question.txt
topic_descriptions.yaml
```

**Changes needed:**
- [ ] Extract system prompt to `system.txt`
- [ ] Extract dynamic question prompt to `dynamic_question.txt`
- [ ] Extract topic descriptions to `topic_descriptions.yaml`
- [ ] Update Director to use PromptLoader
- [ ] Test question generation still works

---

### Task 2.3: Story Analyst Prompts
**Status:** NOT STARTED
**File:** `lib/interview_studio/agents/story_analyst.ex`

**Current (hardcoded at lines 285-308):**
- Theme analysis prompt

**Target:** Load from `priv/domains/interview/prompts/story_analyst/analysis.txt`

**Changes needed:**
- [ ] Extract analysis prompt to file
- [ ] Update Story Analyst to use PromptLoader
- [ ] Test theme detection still works

---

### Task 2.4: Probe Coach Prompts
**Status:** NOT STARTED
**File:** `lib/interview_studio/agents/probe_coach.ex`

**Current (hardcoded at lines 371-397):**
- Probe generation prompt

**Target:** Load from `priv/domains/interview/prompts/probe_coach/`

**Changes needed:**
- [ ] Extract probe prompt to file
- [ ] Extract probe indicators to config
- [ ] Update Probe Coach to use PromptLoader
- [ ] Test probe generation still works

---

### Task 2.5: Sentiment Agent Prompts
**Status:** NOT STARTED
**File:** `lib/interview_studio/agents/sentiment_agent.ex`

**Current (hardcoded at lines 242-272):**
- Sentiment analysis prompt
- Intent guidelines

**Target:** Load from `priv/domains/interview/prompts/sentiment_agent/`

**Changes needed:**
- [ ] Extract sentiment prompt to file
- [ ] Extract intent types to config
- [ ] Update Sentiment Agent to use PromptLoader
- [ ] Test sentiment detection still works

---

### Phase 2 Completion Checklist
- [ ] PromptLoader module created and tested
- [ ] All prompts extracted to `priv/domains/interview/prompts/`
- [ ] All agents updated to use PromptLoader
- [ ] Tests pass
- [ ] Manual testing confirms behavior unchanged
- [ ] Commit, push, deploy
- [ ] Compact conversation

---

## Phase 3: Config-Driven Phases
**Status:** NOT STARTED
**Estimated Time:** 6-8 hours

### Task 3.1: Create Phase Loader
**Status:** NOT STARTED
**File:** `lib/interview_studio/pipeline/phases.ex` (refactor)

**Current:** Phases hardcoded in `@phases` module attribute

**Target:** Load from `priv/domains/interview/phases.yaml`
```yaml
phases:
  - name: preparation
    description: "Initialize agents, load context"
    duration: automatic
    questions: []

  - name: opening
    description: "Greeting, establish rapport"
    duration: "1-2 exchanges"
    questions:
      - id: opening_1
        text: "Hi! I'm excited to learn more about you..."
        purpose: "Set expectations and get consent"

  - name: core_questions
    # ... etc
```

**Changes needed:**
- [ ] Create `priv/domains/interview/phases.yaml`
- [ ] Refactor `Phases` module to load from YAML
- [ ] Keep same public API (`all/0`, `get/1`, `questions/1`, etc.)
- [ ] Add domain parameter to functions
- [ ] Test phase navigation still works

---

### Task 3.2: Update Director for Dynamic Phases
**Status:** NOT STARTED
**File:** `lib/interview_studio/agents/director.ex`

**Current:** References hardcoded `Phases.core_categories()` returning `[:origin, :passion, ...]`

**Target:** Load categories from phase config

**Changes needed:**
- [ ] Update Director to get categories from Phases module
- [ ] Remove hardcoded topic list from Director init
- [ ] Test topic exploration still works

---

### Task 3.3: Update FSM for Dynamic Phases
**Status:** NOT STARTED
**File:** `lib/interview_studio/interview_fsm.ex`

**Current:** Hardcoded phase transitions

**Target:** Load valid transitions from config

**Changes needed:**
- [ ] Update FSM to read phase list from config
- [ ] Make transitions data-driven
- [ ] Test phase transitions still work

---

### Phase 3 Completion Checklist
- [ ] Phase YAML file created
- [ ] Phases module refactored to load from YAML
- [ ] Director updated for dynamic phases
- [ ] FSM updated for dynamic phases
- [ ] Tests pass
- [ ] Manual testing confirms behavior unchanged
- [ ] Commit, push, deploy
- [ ] Compact conversation

---

## Future Phases (Not in Current Scope)

### Phase 4: Agent Plugin System (20-30 hours)
- Config-driven agent loading
- Agent registry
- Generic agent base class

### Phase 5: Generic Director (30-40 hours)
- Separate orchestration from domain logic
- Domain rule engine
- True domain-agnostic orchestrator

---

## Progress Summary

| Phase | Status | Tasks | Completed | Grade Impact |
|-------|--------|-------|-----------|--------------|
| Phase 1 | COMPLETE | 3 | 3/3 | C+ -> B |
| Phase 2 | NOT STARTED | 5 | 0/5 | B -> B+ |
| Phase 3 | NOT STARTED | 3 | 0/3 | B+ -> A- |

---

## Files Changed in Phase 1

### New Files
- `lib/interview_studio/config_loader.ex` - Shared config loading module
- `priv/config/timer.yaml` - Timer agent config
- `priv/config/scribe.yaml` - Scribe agent config
- `priv/config/engagement.yaml` - Engagement monitor config

### Modified Files
- `mix.exs` - Added yaml_elixir dependency
- `lib/interview_studio/agents/timer_agent.ex` - Uses ConfigLoader
- `lib/interview_studio/agents/scribe.ex` - Uses ConfigLoader
- `lib/interview_studio/agents/engagement_monitor.ex` - Uses ConfigLoader

**Last Updated:** 2026-01-23
