# Changelog

All notable changes to Kernai are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Kernai::Protocol`** — generic, thread-safe registry for external
  protocol adapters, symmetric to `Kernai::Skill`. Any registered
  protocol claims a block type, and the kernel dispatches matching
  blocks through the same execution loop as skills. Core ships
  protocol-agnostic; adapters plug in from outside.
- **`Kernai::MCP`** (optional) — adapter bridging the `:mcp` protocol
  to the upstream [`ruby-mcp-client`](https://rubygems.org/gems/ruby-mcp-client)
  gem. Exposes the native MCP verbs (`tools/list`, `tools/call`,
  `tools/describe`, `resources/list`, `resources/read`, `prompts/list`,
  `prompts/get`) plus a `servers/list` Kernai extension for the
  multiplexing layer. YAML config with `${ENV}` expansion, support for
  stdio / sse / streamable_http transports, test-time dependency
  injection via `Adapter.new(config, client:)`. Opt-in via
  `require 'kernai/mcp'`; `require 'kernai'` still pulls in nothing
  external.
- **`/protocols` built-in command** — lists every registered protocol
  and its documentation, symmetric to `/skills` and `/workflow`.
- **`Agent#protocols` whitelist** — `nil` (default, all allowed),
  `[]` (none, explicit opt-out), or `[:mcp, :a2a]` (scoped).
  Symmetric to `Kernai.config.allowed_skills`.
- **Informational-only turn handling in the kernel loop** — a response
  containing only `<plan>` and/or `<json>` blocks (no actionable
  command, protocol, or final) no longer terminates the loop. The
  kernel injects a corrective `<block type="error">` as a user message
  and gives the agent another step. This accommodates small models
  that split reasoning and action across turns. Observable via the
  new `:informational_only` recorder/callback event.
- **MCP adapter helpful error messages** — when the LLM confuses a
  tool name with an MCP protocol method, the adapter detects the
  mistake and suggests the correct `tools/call` form with the tool's
  arguments preserved, so the agent can recover on its next turn.
- **Three live MCP scenarios** under `scenarios/` driving real public
  MCP servers via `npx`:
  - `mcp_filesystem_exploration.rb` —
    `@modelcontextprotocol/server-filesystem` exploratory flow
  - `mcp_memory_store_recall.rb` —
    `@modelcontextprotocol/server-memory` stateful round trip
  - `mcp_mixed_skill_and_protocol.rb` — interleaves a local skill
    with an MCP tool call in a single agent run
- **`scenarios/run_matrix.rb`** — cross-run harness that executes
  every scenario against every `(provider, model)` pair declared in
  MATRIX, prints a colored summary table, and writes a machine-readable
  matrix JSON under `scenarios/logs/` for later inspection.
- **`Scenarios.register_provider` API** — scenario scripts can plug in
  custom providers without editing `scenarios/harness.rb`. Built-in
  Ollama / OpenAI / Anthropic providers are registered via the same
  public API so the code is self-documenting.
- **Hero infographic** (`docs/kernai.png`) embedded at the top of the
  README, plus three Mermaid architecture diagrams (execution flow,
  sub-agents and scoping, observability rail) and a complete example
  conversation tape showing how skills and protocols interleave.
- **README "Protocols" section** covering the generic registry
  contract, the handler return-type contract (String or
  `Kernai::Message`), the `/protocols` built-in, and the MCP adapter
  with its YAML config.

### Changed

- **Sub-agents inherit the parent's full `max_steps`** budget. Previously
  they silently received `parent.max_steps / 2` with a floor of 3,
  which left verbose models stuck at `MaxStepsReachedError` right
  after they had completed the useful work. Full inheritance is a
  simpler, more predictable contract and makes workflows portable
  across models of different verbosity.
- **Reinforced system prompt rules** in `Kernai::InstructionBuilder` —
  a new `## RESPONSE FORMAT (non-negotiable)` section at the top
  explicitly states that plain prose outside of blocks is discarded,
  narrating intent is forbidden (use `<block type="plan">` instead),
  and every response must contain at least one block. Small models
  that previously terminated scenarios by narrating in prose now
  reliably emit structured blocks.
- **Block protocol is injected as soon as skills OR protocols exist**
  (previously skills-only). An agent configured with `protocols: [:mcp]`
  but no local skills now correctly receives the block-format rules
  — before this, it silently reverted to chatbot mode and narrated
  in prose.
- **`Kernai::Error` hierarchy is now consistent** — `Kernai::MCP::ConfigError`,
  `Kernai::MCP::DependencyMissingError`, and
  `Kernai::TaskScheduler::DeadlockError` all inherit from
  `Kernai::Error`, so a single `rescue Kernai::Error` in user code
  catches every framework-raised exception. The base class is now
  declared before the internal `require_relative` chain so subclasses
  at any depth can reference it during load.
- **VCR recording default is stricter** in `test/examples/vcr_helper.rb`.
  Previously, merely having `OLLAMA_API_KEY`, `OPENAI_API_KEY`, or
  `ANTHROPIC_API_KEY` in the local environment silently switched VCR
  to `:new_episodes` mode, which could mutate cassettes on the first
  test run. Now, recording is explicit: `VCR_RECORD=new` for
  `:new_episodes`, `VCR_RECORD=all` for full re-record, unset stays
  at `:none`.

### Fixed

- **Informational-only loop termination bug** — before this release,
  if an agent emitted a response with only a `<plan>` block (no
  actionable block), the kernel would treat it as "final" and return
  the raw plan text. That punished small models which legitimately
  separate thinking and acting across turns.
- **Protocol-only agents no longer get a stripped-down system prompt**
  — `InstructionBuilder` previously short-circuited on `@skills.nil?`
  and skipped the entire block-protocol section, leaving agents
  configured with `protocols: [:mcp]` but no local skills without
  any format guidance. They would respond in prose and terminate
  immediately.
- **CI VCR mismatch** — `OLLAMA_BASE_URL=https://api.ollama.com` is
  now set in the GitHub Actions workflow so that the runtime URI the
  OllamaProvider constructs matches what the cassettes were recorded
  against (the public Ollama Cloud API). Aligns with the pattern
  already used by OpenAI and Anthropic cassettes.
- **Command/protocol interleaving order** — when a single LLM
  response contains both commands and protocol blocks, they are now
  executed in the exact source order rather than always firing
  commands first. Deterministic and matches the LLM's intent.
- **`ruby-mcp-client` hidden dependency** — the upstream gem uses
  `base64` internally without declaring it as a runtime dependency,
  which breaks under Ruby ≥ 3.4 where `base64` has been removed from
  the default gems. Added `base64` to the dev/test group of the
  Gemfile with an inline explanation.

### Developer experience

- Full Rubocop baseline is clean (`0 offenses` across 78 files). The
  config has been realigned to accept the project's natural cadence:
  `ModuleLength` disabled for the kernel's dispatch module,
  `BlockLength` excluded for `scenarios/**` and `test/**` (DSL
  patterns), `ParameterLists` bumped to 7 (kernel helpers pass a
  natural `rec/ctx/step/callback` quartet), `AbcSize` / `MethodLength`
  bumped to 40 (with test files excluded). A handful of intentionally
  long cohesive dispatch methods (`Kernel.run`, `execute_protocol`,
  `execute_skill`, `Parser.parse`, `Harness#report`, etc.) carry
  targeted `rubocop:disable` comments that explain *why* they resist
  splitting, so a future reader can judge when the rationale no
  longer applies.
- Test suite runs 420+ unit + integration tests (0 failures, 0 errors)
  in under 400 ms locally when API keys are absent. Tests use the
  real `ruby-mcp-client` classes via dependency-injected test-doubles
  so upstream signature drift breaks the suite immediately instead of
  silently masking drift in a hand-maintained fake.

## Older history

Prior to this changelog, development happened directly on `main`
without version tags. Notable earlier milestones visible in the git
history:

- Declarative workflow plans with sub-agent scheduling (`TaskScheduler`,
  DAG of sub-agents, `/workflow` and `/tasks` built-in commands).
- Structured `Kernai::LlmResponse` returned by every provider with
  latency and token usage.
- `Kernai::Recorder` scope (depth, task_id, timestamp) and structured
  task/plan events.
- Conversation history support in `Kernel.run`.
- Auto-generated block protocol instructions based on registered
  skills.
- OpenAI, Anthropic and Ollama example providers with VCR-backed
  tests.
