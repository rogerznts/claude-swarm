# Claude Swarm

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Crystal](https://img.shields.io/badge/crystal-1.19+-ff6f00.svg)](https://crystal-lang.org/)

Dependency-aware multi-agent orchestration for Claude-style coding workflows, now ported to Crystal.

Claude Swarm decomposes a large engineering task into subtasks, executes them through a pluggable agent runtime, runs an optional quality gate, and records every session for replay.

## What It Does

```text
You: "Refactor auth module from Express middleware to Next.js API routes"

Claude Swarm:
  Phase 1:   Decompose the task into a dependency graph
  Phase 2:   Execute agent tasks with budget/retry/file-lock control
  Phase 2.5: Run a quality gate across combined outputs
  Phase 3:   Print results and persist a replayable session
```

- Task decomposition into `SwarmTask` graphs with dependencies and file ownership hints
- Budget enforcement, retry tracking, conflict detection, and session recording
- Replayable JSONL timelines in `~/.claude-swarm/sessions/<session-id>/`
- Demo mode that works without an API key
- YAML config auto-detection from `swarm.yaml` or `.claude/swarm.yaml`
- Crystal CLI with terminal dashboard output and subcommands for `sessions` and `replay`

## Quick Start

### Requirements

- Crystal 1.19+
- Shards 0.20+
- `claude` installed and authenticated, or a custom `CLAUDE_SWARM_AGENT_CMD`

### Run the demo

```bash
crystal run bin/claude-swarm -- --demo
```

### Build the binary

```bash
crystal build bin/claude-swarm
./claude-swarm --version
```

### Run a swarm

```bash
./claude-swarm "Refactor auth module from Express middleware to Next.js API routes"
```

### Dry run

```bash
./claude-swarm --dry-run "Add user authentication with JWT"
```

### Sessions and replay

```bash
./claude-swarm sessions
./claude-swarm replay swarm-abc123def456
```

## Agent Runtime

The Crystal port talks to the `claude` CLI directly from Crystal.

By default Claude Swarm runs:

```bash
claude --print --output-format stream-json
```

and parses the resulting event stream natively in Crystal.

If `CLAUDE_SWARM_AGENT_CMD` is set, Claude Swarm instead executes that custom command and expects the internal `SWARM_*` protocol on stdout.

The command contract is:

- stdin: full prompt text
- stdout `SWARM_TEXT\t<text>`: explicit text chunk
- stdout `SWARM_TOOL\t<tool>\t<json>`: tool-use event recorded in the session
- stdout `SWARM_COST\t<number>`: total USD cost for the run

Direct Claude binary override:

```bash
export CLAUDE_BIN=/path/to/claude
```

Custom command override:

```bash
export CLAUDE_SWARM_AGENT_CMD='/path/to/custom_swarm_runtime'
```

The custom command path is optional and exists only for non-`claude` runtimes. The default path is now fully native Crystal.

## CLI Reference

```bash
claude-swarm [OPTIONS] TASK

Options:
  -d, --cwd PATH
  -n, --max-agents N
  -m, --model MODEL
  -b, --budget USD
  -r, --retry N
  -c, --config PATH
  --dry-run
  --demo
  --scenario auth|api
  --quality-gate
  --no-quality-gate
  --no-ui
  -v, --version

Subcommands:
  claude-swarm sessions
  claude-swarm replay <session-id>
```

## YAML Configuration

```yaml
swarm:
  name: full-stack-review
  max_concurrent: 4
  budget_usd: 5.0
  model: opus

agents:
  security-reviewer:
    description: Reviews code for OWASP vulnerabilities
    model: opus
    tools: [Read, Grep, Glob]
    prompt: |
      Analyze the code for SQL injection, XSS, CSRF...

  tester:
    description: Writes and runs tests
    model: haiku
    tools: [Read, Write, Edit, Bash]
    prompt: |
      Write comprehensive tests. Ensure 80% coverage...

connections:
  - from: coder
    to: security-reviewer
  - from: coder
    to: tester
  - from: [security-reviewer, tester]
    to: reviewer
```

## Project Layout

```text
bin/claude-swarm          Crystal entrypoint
src/claude_swarm.cr       top-level requires
src/claude_swarm/*.cr     Crystal implementation
spec/*.cr                 Crystal specs
examples/swarm.yaml       sample topology config
```

The repository now contains only the active Crystal implementation.

## Development

```bash
# format
crystal tool format src spec bin/claude-swarm

# run specs
crystal spec --error-trace

# build
crystal build bin/claude-swarm --error-trace

# smoke test demo
crystal run bin/claude-swarm -- --demo --no-ui
```

## Verification

Current Crystal port verification:

- `crystal build bin/claude-swarm --error-trace`
- `crystal spec --error-trace`
- `crystal run bin/claude-swarm -- --version`
- `crystal run bin/claude-swarm -- sessions`
- `crystal run bin/claude-swarm -- --demo --no-ui`

## License

MIT
