# Kernai

A minimal, extensible Ruby gem for building AI agents through a **universal structured block protocol**. Simple orchestration, dynamic skills, streaming support, full observability — zero external dependencies.

## Philosophy

- **Simplicity** over magic
- **Protocol** over abstraction
- **Backend control** over LLM control
- **Dynamic** over static
- **Pure conversation** over special roles
- **Zero dependencies**

## Installation

Add to your Gemfile:

```ruby
gem "kernai"
```

Or install directly:

```sh
gem install kernai
```

Requires Ruby >= 3.0.

## Quick Start

```ruby
require "kernai"

# 1. Define skills (tools the agent can use)
Kernai::Skill.define(:search) do
  description "Search the knowledge base"
  input :query, String

  execute do |params|
    MySearchEngine.query(params[:query])
  end
end

# 2. Implement a provider (LLM backend)
class MyProvider < Kernai::Provider
  def call(messages:, model:, &block)
    # Call your LLM API here
    # Yield chunks to `block` for streaming
    # Return the complete response string
  end
end

# 3. Create an agent
agent = Kernai::Agent.new(
  instructions: "You are a helpful assistant. Use <block> XML tags to structure your responses.",
  provider: MyProvider.new,
  model: "gpt-4.1",
  max_steps: 10
)

# 4. Run
result = Kernai::Kernel.run(agent, "Find information about Ruby agents") do |event|
  case event.type
  when :text_chunk then print event.data
  when :skill_result then puts "Skill executed: #{event.data[:skill]}"
  when :final then puts "\nDone!"
  end
end
```

## Architecture

```
User Input
    |
    v
 Kernel.run(agent, input)
    |
    v
 Build Messages [system, user]
    |
    v
 +------ Execution Loop ------+
 |  1. Hot reload instructions |
 |  2. Provider.call (LLM)    |
 |  3. StreamParser -> blocks  |
 |  4. Dispatch:               |
 |     command -> skill.call   |
 |     final   -> return       |
 |     plan    -> emit event   |
 |     json    -> emit event   |
 |  5. Inject results          |
 |  6. Repeat or stop          |
 +-----------------------------+
    |
    v
 Final Result
```

### Core Components

| Component | Role |
|-----------|------|
| **Kernel** | Execution loop — orchestrates messages, provider calls, block dispatch, and skill execution |
| **Agent** | Configuration holder — instructions, provider, model, max steps |
| **Skill** | Callable tools with typed inputs, validation, and a thread-safe registry |
| **Block** | Structured XML protocol unit with type (`command`, `final`, `json`, `plan`, `result`, `error`) and optional name |
| **Parser** | Regex-based parser for complete text responses |
| **StreamParser** | State-machine parser for streaming chunks — handles tags split across boundaries |
| **Provider** | Abstract LLM backend interface with streaming support |
| **Message** | Conversation message (`system`, `user`, `assistant`) compatible with LLM APIs |
| **Config** | Global configuration (debug mode, default provider, allowed skills) |
| **Logger** | Structured event-based logging |

### The Block Protocol

All structured communication between the LLM and the kernel uses XML blocks:

```xml
<block type="command" name="search">
  {"query": "Ruby agents"}
</block>

<block type="final">
  Here is the summarized result...
</block>
```

**Block types:**

| Type | Purpose | Kernel behavior |
|------|---------|-----------------|
| `command` | Invoke a skill | Executes skill, injects result as `user` message, continues loop |
| `final` | Agent's final answer | Stops the loop, returns content |
| `plan` | Reasoning / chain of thought | Emits `:plan` event, continues |
| `json` | Structured data output | Emits `:json` event, continues |
| `result` | Skill execution result (injected by kernel) | Read by LLM on next iteration |
| `error` | Skill execution error (injected by kernel) | Read by LLM on next iteration |

### Conversation Model

The kernel maintains a standard conversation with three roles:

- **system** — Agent instructions (single message, always first, replaced on hot reload)
- **user** — User input + internal communication (skill results/errors injected as `user` messages with block markup)
- **assistant** — LLM responses

This keeps the protocol compatible with any conversational LLM API.

## Skills

### Defining Skills

```ruby
Kernai::Skill.define(:database_query) do
  description "Execute SQL queries"

  input :sql, String                   # Required
  input :timeout, Integer, default: 30 # Optional with default

  execute do |params|
    DB.execute(params[:sql], timeout: params[:timeout])
  end
end
```

Skills validate parameter types at call time and apply defaults automatically.

### Registry

```ruby
Kernai::Skill.all                   # List all skills
Kernai::Skill.find(:search)        # Lookup by name
Kernai::Skill.register(skill)      # Manual registration
Kernai::Skill.unregister(:search)  # Remove a skill
Kernai::Skill.reset!               # Clear all
```

### Hot Reload

Skills can be loaded from files and reloaded at runtime without restart:

```ruby
Kernai::Skill.load_from("app/skills/**/*.rb")

# Later, after files change:
Kernai::Skill.reload!
```

The registry is thread-safe (Mutex-protected).

### Parameter Parsing

When the LLM sends a command block, the kernel parses parameters automatically:

- **JSON content** — parsed as a hash: `{"sql": "SELECT 1", "timeout": 60}`
- **Plain text + single input** — wrapped into the skill's input name: `"SELECT 1"` becomes `{sql: "SELECT 1"}`
- **Plain text + multiple inputs** — fallback to `{input: "..."}` 

## Agent

```ruby
agent = Kernai::Agent.new(
  instructions: "You are a helpful assistant...",
  provider: MyProvider.new,
  model: "gpt-4.1",
  max_steps: 10
)
```

### Dynamic Instructions (Hot Reload)

Instructions can be a lambda, re-evaluated at each execution step:

```ruby
agent = Kernai::Agent.new(
  instructions: -> { PromptStore.fetch_current },
  provider: provider,
  max_steps: 10
)
```

Or updated mid-execution:

```ruby
agent.update_instructions("New instructions...")
```

## Provider

Implement the abstract `Kernai::Provider` to connect any LLM:

```ruby
class OpenAIProvider < Kernai::Provider
  def call(messages:, model:, &block)
    response = ""
    client.chat(model: model, messages: messages, stream: true) do |chunk|
      text = chunk.dig("choices", 0, "delta", "content") || ""
      block&.call(text)   # Stream chunk to parser
      response << text
    end
    response               # Return complete text
  end
end
```

**Resolution order:** `Kernel.run(provider:)` override > `agent.provider` > `Kernai.config.default_provider` > error.

## Streaming

The kernel streams LLM output through a state-machine parser that handles tags split across chunk boundaries:

```ruby
Kernai::Kernel.run(agent, input) do |event|
  case event.type
  when :text_chunk   then print event.data       # Raw text outside blocks
  when :plan         then log_reasoning(event.data)
  when :json         then process_data(event.data)
  when :skill_result then track(event.data)
  when :skill_error  then handle_error(event.data)
  when :final        then display(event.data)
  end
end
```

## Configuration

```ruby
Kernai.configure do |c|
  c.debug = true                            # Enable debug logging
  c.default_provider = MyProvider.new       # Fallback provider
  c.allowed_skills = [:search, :calculate]  # Whitelist (nil = all allowed)
end
```

## Security

- **Max steps** — Every agent has a `max_steps` limit (default: 10). Raises `MaxStepsReachedError` if the loop doesn't terminate.
- **Skill whitelist** — Restrict which skills an agent can invoke via `config.allowed_skills`. Unauthorized calls raise `SkillNotAllowedError`.
- **Provider abstraction** — All LLM communication goes through a pluggable interface, enabling request inspection, auth, and rate limiting.

## Testing

Kernai ships with `Kernai::Mock::Provider` for testing:

```ruby
provider = Kernai::Mock::Provider.new
provider.respond_with(
  '<block type="command" name="search">test</block>',
  '<block type="final">Done</block>'
)

agent = Kernai::Agent.new(instructions: "...", provider: provider)
result = Kernai::Kernel.run(agent, "test")

assert_equal "Done", result
assert_equal 2, provider.call_count
```

Run the test suite:

```sh
bundle exec rake test
```

## Project Structure

```
lib/kernai/
  agent.rb          # Agent config and instruction management
  kernel.rb         # Execution loop and orchestration
  skill.rb          # Skill DSL, registry, and execution
  block.rb          # Block types and handler registry
  parser.rb         # Regex-based block parser (complete text)
  stream_parser.rb  # State-machine block parser (streaming)
  message.rb        # Conversation message abstraction
  provider.rb       # Abstract LLM provider interface
  config.rb         # Global configuration
  logger.rb         # Structured event logging
  mock/
    provider.rb     # Mock provider for testing
```

## License

MIT
