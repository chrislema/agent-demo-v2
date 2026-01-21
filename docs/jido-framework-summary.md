# Jido Framework Deep Dive Summary

## Overview

Jido (自動, meaning "automatic/automated" in Japanese - 自 "self" + 動 "movement") is an autonomous agent framework for Elixir created by Mike Hostetler. It provides foundational primitives for building distributed, autonomous agent systems that can plan, execute, and adapt their behavior.

**Key Philosophy**: The core framework intentionally contains ZERO LLM or AI code. It's designed as pure data structures and OTP patterns first, with AI capabilities layered on top via separate packages. This enables both LLM-based agents and classical AI planning algorithms (behavior trees, zipper trees).

**Performance Claim**: 10,000+ agents at approximately 25KB each.

**Current Version**: v2.0 (as of January 2026)

---

## Core Architecture

### The Fundamental Pattern

The central operation in Jido is: `{agent, directives} = MyAgent.cmd(agent, action)`

This embodies a pure functional design inspired by Elm/Redux where:
- Agents are immutable data structures
- Actions transform state (pure data transformations)
- Directives describe external effects (never modify state directly)
- State operations are internal transitions handled by the strategy layer during cmd/2

### Key Invariants

1. cmd/2 is a PURE FUNCTION - same inputs always produce same outputs
2. The returned agent is complete (no separate "apply directives" step)
3. Directives describe what should happen but don't execute it
4. The OTP runtime (AgentServer) handles directive execution

---

## Core Primitives

### Actions

Discrete, reusable units of work that serve as "LEGO bricks for agents." Each action includes:
- Schema validation via NimbleOptions
- Rich metadata (name, description, category, tags)
- Standard interface via run/2 function
- Designed for AI agents to reason about and combine dynamically

Actions exist specifically to support AI agent systems where agents need to make autonomous decisions about what steps to take, packaging functionality into discrete units the agent can reason about.

### Agents

Stateful entities defined at compile-time that:
- Maintain schema-validated state
- Have a registered list of allowed actions
- Include pending_instructions queue
- Support lifecycle hooks (on_before_validate_state, on_after_validate_state, on_before_plan, on_before_run, on_after_run, on_error, shutdown)
- Cannot be defined at runtime (compile-time only)

Each agent module defines its own struct type with fields: actions, category, description, dirty_state?, id, name, pending_instructions, result, runner, schema, state, tags, vsn.

### Signals

Universal message format based on CloudEvents v1.0.2 specification. Signals serve as the "nervous system" of agent networks with:
- Hierarchical dot notation for types (e.g., "user.created", "jido.ai.**")
- Standard fields: type, source, data, id, time, subject, datacontenttype, dataschema, extensions
- jido_dispatch field for routing configuration
- Multiple dispatch adapters: pid, named, pubsub, bus, logger, console, noop, http, webhook
- Flexible extension system for custom metadata

### Skills

Modular, reusable behavior modules that extend agents with specific capabilities:
- Define signal patterns they respond to (wildcard support)
- router/1 function maps signals to Instructions
- handle_signal/2 preprocesses incoming signals
- transform_result/3 post-processes results
- mount/2 initialization hook
- State isolation per skill with automatic schema merging

### Directives

External effects described as data, executed by the OTP runtime:
- Emit: Dispatch a signal via configured adapters
- Error: Signal an error from cmd/2
- Spawn: Spawn a generic BEAM child process
- SpawnAgent: Spawn a child Jido agent with hierarchy tracking
- StopChild: Gracefully stop a tracked child agent
- Schedule: Schedule a delayed message
- Stop: Stop the agent process
- Protocol-based extensibility for custom directives

### Sensors

Event-driven data gathering processes for real-time monitoring:
- GenServer-based with schema-validated configuration
- mount/1 and handle_info/2 callbacks
- Emit signals based on external events
- Support agents by monitoring environmental changes

---

## Execution Strategies

Jido supports multiple execution patterns via the runner field:
- Direct execution: Simple, synchronous workflows
- FSM (Finite State Machine): State-driven workflows with validated transitions
- Extensible strategy protocol: Custom execution patterns

The default runner is Jido.Runner.Simple.

---

## Runtime Architecture

### AgentServer / Runtime

GenServer-based runtime for production deployment that:
- Wraps the pure functional agent
- Executes directives
- Handles process lifecycle
- Supports max_queue_size configuration (default 10000)

### PubSub Events Emitted

- jido.agent.started: Runtime initialization complete
- jido.agent.state_changed: Runtime state transitions
- jido.agent.cmd_completed: Action execution completed
- jido.agent.queue_overflow: Queue size exceeded max_queue_size

### Commands

- act: Asynchronous action
- manage: Synchronous management commands (pause, resume)
- cmd: Synchronous action with result
- cmd_async: Asynchronous action

### Supervision

Agents fit into standard OTP supervision trees with:
- Parent-child agent hierarchies via SpawnAgent directive
- Dynamic supervisors for agent lifecycle management
- Instance-scoped supervision for multi-tenant deployments

---

## Jido.Signal Package (jido_signal)

Standalone package providing sophisticated agent communication:

### Signal Bus

In-memory GenServer-based pub/sub system with:
- Partitioning for high volume (configurable partition count)
- Rate limiting per partition (e.g., 50,000 signals/sec)
- Burst size configuration
- Complete signal history with replay capabilities

### Routing Engine

Trie-based pattern matching with:
- Exact matches (highest priority)
- Single-level wildcards (user.*.updated)
- Multi-level wildcards (audit.**)
- Priority-based execution ordering
- Custom pattern matching functions

### Persistent Subscriptions

Reliable message delivery with:
- Acknowledgment system (ack)
- Automatic replay of unacknowledged signals on reconnect
- Subscriber crash recovery

### Causality Tracking (Journal)

Complete signal relationship graphs:
- Cause-effect chain analysis
- Conversation grouping
- Temporal ordering
- System traceability for debugging

### Signal History & Replay

- Query signals matching patterns since a timestamp
- New subscribers can request historical replay
- Snapshots for point-in-time analysis

### Serialization

Multiple formats supported: JSON, MessagePack, Erlang Term Format

---

## Jido.Chat Package (jido_chat)

Structured chat room system for human + AI agent collaboration:

### Participant Types

- :human - Human users
- :agent - AI agent participants

### Features

- Flexible room creation with custom configurations
- Dynamic supervision (OTP-based room lifecycle)
- Thread support for conversation organization
- @mentions for targeting specific participants
- Rich message types (text, system, rich content with payloads)
- Role-based access with participant permissions
- Real-time status tracking

### Custom Room Behaviors

Implement custom logic via use Jido.Chat.Room with callbacks:
- handle_message/2
- handle_join/2

### Supervision Tree

```
Jido.Chat.Application.Supervisor
├── Registry
└── Jido.Chat.Supervisor
    ├── Room 1
    ├── Room 2
    └── Room N
```

---

## Jido.AI Package (jido_ai)

Extends core Jido with AI capabilities:

### Provider Support

57+ LLM providers via ReqLLM including Anthropic, OpenAI, Google (Gemini), OpenRouter, Cloudflare, Mistral.

### AI Agent Extensions

- chat_response/2: General chat interactions
- tool_response/2: Tool-augmented responses
- boolean_response/2: Yes/no with explanation and confidence

### Advanced Reasoning Techniques

- Chain-of-Thought
- ReAct
- Tree-of-Thoughts
- Self-Consistency
- GEPA

### Structured Prompts

Template-based prompts with EEx and Liquid support, including:
- MessageItem module for conversation messages
- Roles: user, assistant, system, function
- Rich content support (images, files)
- Prompt.Splitter for token management

### Tool Integration

Jido Actions automatically convert to LLM tool definitions. The LLM decides when to call tools, Jido executes them, results flow back to LLM.

### Conversation Management

Stateful multi-turn conversations with ETS storage and automatic context window management (token counting, truncation strategies).

### Keyring System

API key management supporting environment variables, application config, and session-based keys.

---

## Additional Packages

### jido_behaviortree (EXPERIMENTAL)

Behavior tree library for deterministic agent decision-making. Provides classical AI patterns complementing LLM-based reasoning. Mike Hostetler noted these are "more practical in the real-world because they are more reliable."

### jido_action

Standalone action definitions package.

### jido_keys

API key management for multi-provider scenarios.

### llm_db

Model database defining provider and model capabilities, costs, and limits.

### req_llm

Req plugin for AI providers (333 stars), supporting 57+ providers.

### jido_character

Character/persona definitions for agents.

---

## Multi-Agent Coordination Patterns

### Signal-Based Fan-Out

Multiple agents subscribe to the same signal bus topics. When a signal is published, all subscribers receive it simultaneously (leveraging BEAM's process model for true parallelism).

### Parent-Child Hierarchies

SpawnAgent directive creates managed child agents with:
- Hierarchy tracking
- Lifecycle management
- Supervised relationships

### Chat Room Collaboration

Jido.Chat enables structured multi-party (human + AI) collaboration in isolated rooms with threading, mentions, and rich content.

### Workflow Coordination

Signals track workflow progress with causality chains:
- workflow.started
- step.completed (multiple)
- workflow.completed

Commands become events with causal links stored in Journal for audit trails.

---

## Key Design Decisions

### Why No AI in Core

The foundational library intentionally excludes LLM dependencies to:
- Support both LLM-based agents AND classical AI planning algorithms
- Keep core primitives pure and testable
- Allow flexible integration of any AI provider
- Enable behavior trees, zipper trees, and other deterministic patterns

### OTP Foundation

Built on battle-tested OTP patterns with 20+ years of proven reliability:
- Hot-swap agent code at runtime via OTP release handling
- Supervision trees for fault tolerance
- Lightweight processes (0.5-2KB vs 8MB for OS threads)
- One agent per user session becomes trivial

### Elm/Redux Inspiration

Pure functional agent design where:
- State changes are data transformations
- Side effects are described, not executed
- Testing requires no processes
- Deterministic, reproducible behavior

---

## Ecosystem Summary Table

| Package | Purpose | Key Feature |
|---------|---------|-------------|
| jido | Core agent primitives | Pure functional agents, cmd/2, directives |
| jido_signal | Communication backbone | Pub/sub, routing, causality tracking |
| jido_chat | Collaboration rooms | Human + AI multi-party chat |
| jido_ai | LLM integration | 57+ providers, tool calling, reasoning |
| jido_behaviortree | Decision trees | Deterministic agent reasoning |
| jido_action | Action definitions | Reusable work units |
| jido_keys | Key management | Multi-provider credentials |
| llm_db | Model database | Capabilities, costs, limits |
| req_llm | HTTP client | AI provider requests |
| jido_character | Personas | Agent character definitions |
| jido_workbench | Demo app | Phoenix examples |

---

## Documentation Locations

- Main site: https://agentjido.xyz
- Core docs: https://hexdocs.pm/jido
- AI docs: https://hexdocs.pm/jido_ai
- Signal docs: https://hexdocs.pm/jido_signal
- Chat docs: https://hexdocs.pm/jido_chat
- GitHub org: https://github.com/agentjido

---

## Relevance to Multi-Agent Systems

### For Interview Engine / Podcast Generation

- Signal-based architecture ideal for multi-step conversational flows
- Skills handle different phases (research, outline, script, voice synthesis)
- Directive system coordinates side effects cleanly
- Conversation management preserves context

### For MCode Voice Assessment

- MCode assessment logic becomes callable Jido Actions
- Agent orchestrates interview flow
- Tool integration allows LLM to invoke assessment functions
- Structured output via Ecto schemas for results

### For Concurrent Observer Patterns

Jido provides the foundation but requires explicit architecture:
- Multiple AgentServers run simultaneously (one per observer)
- Sensors emit signals that multiple agents subscribe to
- Pubsub dispatch adapter enables fan-out patterns
- Signal Bus handles parallel delivery to all subscribers
- Each observer processes in its own BEAM process (true parallelism)

---

## Current Limitations & Gaps

1. Documentation is limited with few complete examples
2. Some abstractions are tightly coupled (e.g., passing state into tool calls requires source modifications)
3. jido_memory package exists but lacks deep documentation
4. Behavior tree integration patterns are experimental
5. Concrete multi-agent team orchestration examples are sparse

---

## Creator Vision

From Mike Hostetler (Elixir Forum):

"I see a future where we each have thousands of Agents working for us constantly - like a swarm of ants. No other framework or platform comes close to making this happen - so I started from first principles with Elixir."

---

*Document created: January 2026*
*Based on research of Jido v2.0, jido_ai v0.5.2, jido_signal v1.2.0*
