# Emergent Behavior Examples

This document captures specific examples where agent collaboration produces insights and behaviors that no single agent could produce alone. These examples demonstrate that the Interview Studio multi-agent system is more than a sequential pipeline.

## The Key Test
> "If this can be built as a sequential pipeline, we've failed."

Each example below shows:
1. **Inputs**: What each agent contributes
2. **Emergent Output**: The behavior that emerges from their combination
3. **Why It's Emergent**: Why a single agent or pipeline couldn't produce this

---

## Example 1: Theme-Aware Probe Generation

**Scenario**: Story Analyst shares theme with Probe Coach

**Inputs**:
- **Story Analyst**: Discovers "resilience" theme from user's story about overcoming obstacles
- **Probe Coach**: Receives theme notification via `analyst.theme.discovered` signal

**Emergent Output**:
Probe Coach generates a follow-up question specifically about resilience:
> "You've mentioned facing several challenges. What helped you keep going when things got really tough?"

**Why It's Emergent**:
- Story Analyst alone can identify themes but doesn't generate questions
- Probe Coach alone analyzes utterances but wouldn't know about the "resilience" theme
- The combination produces a theme-informed probe that neither could create independently

---

## Example 2: Engagement-Aware Topic Selection

**Scenario**: Director combines engagement data with theme data for topic selection

**Inputs**:
- **Story Analyst**: Has discovered themes related to "passion" and "origin"
- **Engagement Monitor**: Reports :low engagement with :declining trend
- **Director**: Has both :passion and :moments in remaining topics

**Emergent Output**:
Director selects :passion instead of :moments because it connects to discovered themes AND is a lighter topic suitable for declining engagement.

**Why It's Emergent**:
- A pipeline would follow a fixed topic order
- Story Analyst alone would suggest following the theme
- Engagement Monitor alone would suggest easier questions
- The Director synthesizes BOTH inputs to make an optimal choice

---

## Example 3: Consensus-Blocked Phase Transition

**Scenario**: Agents vote on transition to synthesis

**Inputs**:
- **Story Analyst**: Votes `:not_ready` - "No themes discovered yet"
- **Probe Coach**: Votes `:ready` - "No pending probes"
- **Engagement Monitor**: Votes `:abstain` - "Moderate engagement"

**Emergent Output**:
Director delays transition to synthesis despite completing the topic list, because Story Analyst hasn't identified sufficient themes for a meaningful synthesis.

**Why It's Emergent**:
- A pipeline would transition based on question count alone
- The system waits for collective readiness
- Story Analyst's expertise about theme sufficiency influences the overall flow

---

## Example 4: High-Priority Probe Interruption

**Scenario**: Probe Coach detects emotional content worth immediate exploration

**Inputs**:
- **User**: "When my father passed, I had to take over the family business overnight."
- **Probe Coach**: Detects emotional language, marks probe as `:high` priority
- **Director**: Was planning to ask about "differentiation" next

**Emergent Output**:
Director abandons the planned topic question and asks the high-priority probe instead:
> "That must have been incredibly difficult. How did you navigate that sudden transition?"

**Why It's Emergent**:
- A pipeline follows a fixed question order
- The probe interrupts the normal flow based on real-time content analysis
- Interview adapts dynamically to what the user shares

---

## Example 5: Engagement Alert Cascade

**Scenario**: User indicates desire to wrap up; all agents respond

**Inputs**:
- **User**: "I think we've covered a lot already, let's wrap up"
- **Engagement Monitor**: Detects wrap-up cue, broadcasts `:critical` engagement alert
- **Story Analyst**: Receives alert, pauses deep analysis
- **Probe Coach**: Receives alert, clears low-priority probes
- **Director**: Receives alert, initiates transition to synthesis

**Emergent Output**:
The entire system shifts behavior:
- No more deep analysis consuming resources
- Remaining probes are discarded
- Transition to closing begins immediately

**Why It's Emergent**:
- All agents coordinate their response to a single user signal
- The behavior change is system-wide and immediate
- A pipeline would continue with its script regardless

---

## Example 6: Cross-Theme Pattern Recognition

**Scenario**: Multiple themes combine to suggest a deeper pattern

**Inputs**:
- **Story Analyst**: Theme 1 - "family influence" (evidence: brother, father mentioned)
- **Story Analyst**: Theme 2 - "proving oneself" (evidence: "not the smart one", "had to show")
- **Director**: Receives both themes in synthesis

**Emergent Output**:
Dynamic question that connects both themes:
> "It sounds like family has been a big influence on your journey - both motivating you and maybe adding some pressure. How do you think about that dynamic now?"

**Why It's Emergent**:
- Each theme alone would produce a simpler question
- The combination reveals a deeper pattern
- The question addresses the relationship between themes

---

## Example 7: Weighted Consensus Override

**Scenario**: Engagement Monitor's high weight influences closing decision

**Inputs**:
- **Story Analyst**: Votes `:not_ready` - "Only 1 theme, wanted more"
- **Probe Coach**: Votes `:not_ready` - "Have unexplored probes"
- **Engagement Monitor**: Votes `:ready` with 2x weight - "Critical engagement"

**Emergent Output**:
Despite 2-1 against closing, the weighted consensus passes because Engagement Monitor's vote counts double for closing decisions.

**Why It's Emergent**:
- Simple majority voting would block the transition
- Domain expertise (engagement for closing) is weighted appropriately
- The system respects user energy over interview completeness

---

## Verification Checklist

For each interview session, verify these emergent behaviors occurred:

- [ ] **Theme-aware probes**: Probe Coach generated questions referencing Story Analyst themes
- [ ] **Engagement adaptation**: Question depth/tone changed based on engagement level
- [ ] **Dynamic topic selection**: Topics were re-ordered based on theme relevance
- [ ] **Probe interruptions**: High-priority probes interrupted planned questions
- [ ] **Consensus transitions**: Phase changes waited for (or overrode with logging) agent agreement
- [ ] **Engagement cascades**: Critical engagement triggered system-wide behavior change

## Measuring Collaboration

A session demonstrates true multi-agent collaboration if:

1. **Questions differ from static bank**: Dynamic questions reference specific conversation content
2. **Agent removal changes output**: Disabling any agent noticeably affects behavior
3. **Timing is consensus-based**: Transitions happen based on collective readiness
4. **Real-time adaptation**: Interview flow changes based on what user shares
5. **Combined > sum of parts**: Synthesized outputs couldn't come from any single agent

---

*This document is part of Phase 6: Validation & Testing*
