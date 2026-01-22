# Interview Studio - Agent Instructions

## Project Type
Elixir/Phoenix web application with multi-agent system using Jido framework.

## Prerequisites
- Elixir 1.15+
- Erlang/OTP 26+
- Node.js (for assets)

## Environment Variables
```bash
export ANTHROPIC_API_KEY="your-key"  # Required for LLM features
```

## Quick Start
```bash
cd interview_studio
mix deps.get          # Install dependencies
mix compile           # Compile project
mix phx.server        # Start server at http://localhost:4000
```

## Common Commands
```bash
# From interview_studio/ directory:
mix compile                    # Compile and check for errors
mix test                       # Run tests
mix phx.server                 # Start dev server
iex -S mix phx.server          # Start with interactive shell

# Useful iex commands:
InterviewStudio.InterviewBus.subscribe("**")  # Subscribe to all signals
InterviewStudio.Pipeline.InterviewFSM.start_link(session_id: "test")
```

## Project Structure
```
interview_studio/
├── lib/
│   ├── interview_studio/
│   │   ├── agents/           # Agent implementations
│   │   │   └── director.ex   # Main orchestrator
│   │   ├── pipeline/         # Interview flow
│   │   │   ├── interview_fsm.ex
│   │   │   └── phases.ex
│   │   ├── signals/          # Signal definitions
│   │   ├── application.ex    # Supervision tree
│   │   └── interview_bus.ex  # Pub/sub bus
│   └── interview_studio_web/
│       ├── live/             # LiveView modules
│       └── router.ex
├── config/
├── mix.exs
└── mix.lock
```

## Key Modules
- `InterviewStudio.InterviewBus` - Central signal pub/sub
- `InterviewStudio.Pipeline.InterviewFSM` - Phase state machine
- `InterviewStudio.Pipeline.Phases` - Phase definitions & questions
- `InterviewStudio.Agents.Director` - Main orchestrator agent

## Deployment
```bash
# Fly.io deployment
flyctl deploy
flyctl secrets set ANTHROPIC_API_KEY="your-key"
```

App URL: https://agentdemov2.fly.dev

## Debugging
```bash
# Check compilation
mix compile --warnings-as-errors

# Interactive debugging
iex -S mix phx.server

# View logs
mix phx.server 2>&1 | tee debug.log
```

## Testing Changes
After making changes:
1. Run `mix compile` - must succeed
2. Run verification command from task (if any)
3. Test manually if UI changes
