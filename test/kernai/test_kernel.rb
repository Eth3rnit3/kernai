require_relative "../test_helper"
require "json"

class TestKernel < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
    @agent = Kernai::Agent.new(
      instructions: "You are a helpful assistant. Use XML blocks.",
      provider: @provider,
      model: "test-model",
      max_steps: 10
    )
  end

  # --- Basic execution ---

  def test_run_with_final_block
    @provider.respond_with('<block type="final">Hello, world!</block>')
    result = Kernai::Kernel.run(@agent, "Hi")
    assert_equal "Hello, world!", result
  end

  def test_run_with_plain_text_no_blocks
    @provider.respond_with("Just a plain answer")
    result = Kernai::Kernel.run(@agent, "Hi")
    assert_equal "Just a plain answer", result
  end

  def test_run_with_text_and_final_block
    @provider.respond_with('Here is my answer: <block type="final">The result</block>')
    result = Kernai::Kernel.run(@agent, "Hi")
    assert_equal "The result", result
  end

  # --- Command execution ---

  def test_run_with_command_executes_skill
    Kernai::Skill.define(:search) do
      input :query, String
      execute { |params| "Found: #{params[:query]}" }
    end

    @provider.respond_with(
      '<block type="command" name="search">test query</block>',
      '<block type="final">Done searching</block>'
    )

    result = Kernai::Kernel.run(@agent, "Search for test")
    assert_equal "Done searching", result
    assert_equal 2, @provider.call_count
  end

  def test_command_result_injected_as_user_message
    Kernai::Skill.define(:lookup) do
      input :query, String
      execute { |params| "user_123" }
    end

    @provider.respond_with(
      '<block type="command" name="lookup">find user</block>',
      '<block type="final">Found the user</block>'
    )

    Kernai::Kernel.run(@agent, "Find user")

    # Second call should include the result message
    second_call = @provider.calls[1]
    messages = second_call[:messages]
    result_msg = messages.find { |m| m[:content].include?("result") && m[:content].include?("lookup") }
    assert result_msg, "Result block should be injected"
    assert_includes result_msg[:content], "user_123"
  end

  def test_command_with_json_params
    received = nil
    Kernai::Skill.define(:search) do
      input :query, String
      input :limit, Integer, default: 10
      execute { |params| received = params; "ok" }
    end

    @provider.respond_with(
      '<block type="command" name="search">{"query": "alice", "limit": 5}</block>',
      '<block type="final">Done</block>'
    )

    Kernai::Kernel.run(@agent, "Search")
    assert_equal "alice", received[:query]
    assert_equal 5, received[:limit]
  end

  def test_command_skill_not_found
    @provider.respond_with(
      '<block type="command" name="unknown_skill">test</block>',
      '<block type="final">Handled error</block>'
    )

    result = Kernai::Kernel.run(@agent, "Do something")
    assert_equal "Handled error", result

    # Error should have been injected
    second_call = @provider.calls[1]
    error_msg = second_call[:messages].find { |m| m[:content].include?("error") && m[:content].include?("unknown_skill") }
    assert error_msg, "Error block should be injected for missing skill"
  end

  def test_command_skill_not_allowed
    Kernai::Skill.define(:forbidden) do
      input :query, String
      execute { |params| "secret" }
    end
    Kernai.config.allowed_skills = [:other_skill]

    @provider.respond_with(
      '<block type="command" name="forbidden">test</block>',
      '<block type="final">Handled</block>'
    )

    result = Kernai::Kernel.run(@agent, "Do forbidden thing")
    assert_equal "Handled", result

    second_call = @provider.calls[1]
    error_msg = second_call[:messages].find { |m| m[:content].include?("error") && m[:content].include?("not allowed") }
    assert error_msg, "Error block should be injected for disallowed skill"
  end

  def test_command_skill_execution_error
    Kernai::Skill.define(:failing) do
      input :query, String
      execute { |_| raise "Something went wrong" }
    end

    @provider.respond_with(
      '<block type="command" name="failing">test</block>',
      '<block type="final">Recovered</block>'
    )

    result = Kernai::Kernel.run(@agent, "Try failing")
    assert_equal "Recovered", result

    second_call = @provider.calls[1]
    error_msg = second_call[:messages].find { |m| m[:content].include?("error") && m[:content].include?("Something went wrong") }
    assert error_msg, "Error block should be injected for skill failure"
  end

  def test_command_without_name_returns_error
    @provider.respond_with(
      '<block type="command">do something</block>',
      '<block type="final">OK</block>'
    )

    result = Kernai::Kernel.run(@agent, "Go")
    assert_equal "OK", result
  end

  # --- Max steps ---

  def test_max_steps_raises_error
    agent = Kernai::Agent.new(
      instructions: "test",
      provider: @provider,
      model: "test",
      max_steps: 2
    )

    Kernai::Skill.define(:loop_skill) do
      input :query, String
      execute { |_| "looping" }
    end

    @provider.respond_with('<block type="command" name="loop_skill">go</block>')

    assert_raises(Kernai::MaxStepsReachedError) do
      Kernai::Kernel.run(agent, "Loop forever")
    end
  end

  # --- Provider resolution ---

  def test_provider_override_in_run
    override = Kernai::Mock::Provider.new
    override.respond_with('<block type="final">From override</block>')

    result = Kernai::Kernel.run(@agent, "Hi", provider: override)
    assert_equal "From override", result
    assert_equal 1, override.call_count
    assert_equal 0, @provider.call_count
  end

  def test_default_provider_fallback
    agent = Kernai::Agent.new(instructions: "test", model: "test", max_steps: 5)
    default = Kernai::Mock::Provider.new
    default.respond_with('<block type="final">From default</block>')
    Kernai.config.default_provider = default

    result = Kernai::Kernel.run(agent, "Hi")
    assert_equal "From default", result
  end

  def test_no_provider_raises_error
    agent = Kernai::Agent.new(instructions: "test", model: "test")
    assert_raises(Kernai::ProviderError) do
      Kernai::Kernel.run(agent, "Hi")
    end
  end

  # --- Streaming events ---

  def test_streaming_text_chunk_events
    @provider.respond_with("Hello world")
    chunks = []

    Kernai::Kernel.run(@agent, "Hi") do |event|
      chunks << event.data if event.type == :text_chunk
    end

    assert_equal "Hello world", chunks.join
  end

  def test_streaming_final_event
    @provider.respond_with('<block type="final">The answer</block>')
    final_data = nil

    Kernai::Kernel.run(@agent, "Hi") do |event|
      final_data = event.data if event.type == :final
    end

    assert_equal "The answer", final_data
  end

  def test_streaming_skill_result_event
    Kernai::Skill.define(:ping) do
      input :query, String
      execute { |_| "pong" }
    end

    @provider.respond_with(
      '<block type="command" name="ping">test</block>',
      '<block type="final">Done</block>'
    )

    skill_events = []
    Kernai::Kernel.run(@agent, "Ping") do |event|
      skill_events << event if event.type == :skill_result
    end

    assert_equal 1, skill_events.size
    assert_equal :ping, skill_events[0].data[:skill]
    assert_equal "pong", skill_events[0].data[:result]
  end

  def test_streaming_skill_error_event
    Kernai::Skill.define(:boom) do
      input :query, String
      execute { |_| raise "kaboom" }
    end

    @provider.respond_with(
      '<block type="command" name="boom">go</block>',
      '<block type="final">Recovered</block>'
    )

    error_events = []
    Kernai::Kernel.run(@agent, "Boom") do |event|
      error_events << event if event.type == :skill_error
    end

    assert_equal 1, error_events.size
    assert_equal :boom, error_events[0].data[:skill]
    assert_includes error_events[0].data[:error], "kaboom"
  end

  # --- Conversation model ---

  def test_system_message_always_first
    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, "Hi")

    messages = @provider.last_call[:messages]
    assert_equal :system, messages[0][:role]
    assert_equal "You are a helpful assistant. Use XML blocks.", messages[0][:content]
  end

  def test_user_input_as_second_message
    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, "Hello there")

    messages = @provider.last_call[:messages]
    assert_equal :user, messages[1][:role]
    assert_equal "Hello there", messages[1][:content]
  end

  def test_model_passed_to_provider
    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, "Hi")
    assert_equal "test-model", @provider.last_call[:model]
  end

  # --- Hot reload instructions ---

  def test_instructions_hot_reload_during_loop
    call_count = 0
    instructions = -> { call_count += 1; "Instructions v#{call_count}" }

    agent = Kernai::Agent.new(
      instructions: instructions,
      provider: @provider,
      model: "test",
      max_steps: 5
    )

    Kernai::Skill.define(:noop) do
      input :query, String
      execute { |_| "ok" }
    end

    @provider.respond_with(
      '<block type="command" name="noop">go</block>',
      '<block type="final">Done</block>'
    )

    Kernai::Kernel.run(agent, "Go")

    # System message should be updated on each step
    first_system = @provider.calls[0][:messages][0][:content]
    second_system = @provider.calls[1][:messages][0][:content]
    assert_includes first_system, "v"
    assert_includes second_system, "v"
    refute_equal first_system, second_system
  end

  # --- Multi-step ---

  def test_multi_step_command_chain
    Kernai::Skill.define(:step_a) do
      input :query, String
      execute { |_| "result_a" }
    end

    Kernai::Skill.define(:step_b) do
      input :query, String
      execute { |_| "result_b" }
    end

    @provider.respond_with(
      '<block type="command" name="step_a">go</block>',
      '<block type="command" name="step_b">go</block>',
      '<block type="final">All done</block>'
    )

    result = Kernai::Kernel.run(@agent, "Do both steps")
    assert_equal "All done", result
    assert_equal 3, @provider.call_count
  end

  # --- Plan and JSON blocks ---

  def test_plan_block_emits_event
    @provider.respond_with(
      '<block type="plan">I will search first</block><block type="final">Done</block>'
    )

    plan_events = []
    Kernai::Kernel.run(@agent, "Go") do |event|
      plan_events << event if event.type == :plan
    end

    assert_equal 1, plan_events.size
    assert_equal "I will search first", plan_events[0].data
  end

  def test_json_block_emits_event
    @provider.respond_with(
      '<block type="json">{"key": "value"}</block><block type="final">Done</block>'
    )

    json_events = []
    Kernai::Kernel.run(@agent, "Go") do |event|
      json_events << event if event.type == :json
    end

    assert_equal 1, json_events.size
    assert_includes json_events[0].data, '"key"'
  end

  # --- Conversation history ---

  def test_history_empty_by_default
    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, "Hi")

    messages = @provider.last_call[:messages]
    assert_equal 2, messages.size
    assert_equal :system, messages[0][:role]
    assert_equal :user, messages[1][:role]
  end

  def test_history_inserted_between_system_and_user
    history = [
      { role: :user, content: "What is 2+2?" },
      { role: :assistant, content: "4" }
    ]

    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, "And 3+3?", history: history)

    messages = @provider.last_call[:messages]
    assert_equal 4, messages.size
    assert_equal :system,    messages[0][:role]
    assert_equal :user,      messages[1][:role]
    assert_equal "What is 2+2?", messages[1][:content]
    assert_equal :assistant, messages[2][:role]
    assert_equal "4",        messages[2][:content]
    assert_equal :user,      messages[3][:role]
    assert_equal "And 3+3?", messages[3][:content]
  end

  def test_history_preserves_multiple_turns
    history = [
      { role: :user, content: "Turn 1" },
      { role: :assistant, content: "Reply 1" },
      { role: :user, content: "Turn 2" },
      { role: :assistant, content: "Reply 2" }
    ]

    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, "Turn 3", history: history)

    messages = @provider.last_call[:messages]
    # system + 4 history + current user = 6
    assert_equal 6, messages.size
    assert_equal "Turn 1",  messages[1][:content]
    assert_equal "Reply 1", messages[2][:content]
    assert_equal "Turn 2",  messages[3][:content]
    assert_equal "Reply 2", messages[4][:content]
    assert_equal "Turn 3",  messages[5][:content]
  end

  def test_history_persists_across_tool_steps
    Kernai::Skill.define(:greet) do
      input :query, String
      execute { |params| "Hello #{params[:query]}!" }
    end

    history = [
      { role: :user, content: "My name is Alice" },
      { role: :assistant, content: "Nice to meet you, Alice!" }
    ]

    @provider.respond_with(
      '<block type="command" name="greet">Alice</block>',
      '<block type="final">Greeted!</block>'
    )

    Kernai::Kernel.run(@agent, "Greet me", history: history)

    # Both calls should include the history
    first_messages = @provider.calls[0][:messages]
    second_messages = @provider.calls[1][:messages]

    # First call: system + history(2) + user = 4
    assert_equal 4, first_messages.size
    assert_equal "My name is Alice", first_messages[1][:content]

    # Second call: system + history(2) + user + assistant + skill_result = 6
    assert_equal 6, second_messages.size
    assert_equal "My name is Alice", second_messages[1][:content]
  end

  def test_history_with_hot_reload_instructions
    call_count = 0
    instructions = -> { call_count += 1; "Instructions v#{call_count}" }

    agent = Kernai::Agent.new(
      instructions: instructions,
      provider: @provider,
      model: "test",
      max_steps: 5
    )

    Kernai::Skill.define(:noop_hist) do
      input :query, String
      execute { |_| "ok" }
    end

    history = [
      { role: :user, content: "Previous question" },
      { role: :assistant, content: "Previous answer" }
    ]

    @provider.respond_with(
      '<block type="command" name="noop_hist">go</block>',
      '<block type="final">Done</block>'
    )

    Kernai::Kernel.run(agent, "New question", history: history)

    # Both steps should have history AND updated system instructions
    first_messages = @provider.calls[0][:messages]
    second_messages = @provider.calls[1][:messages]

    assert_includes first_messages[0][:content], "v"
    assert_equal "Previous question", first_messages[1][:content]

    assert_includes second_messages[0][:content], "v"
    assert_equal "Previous question", second_messages[1][:content]
    refute_equal first_messages[0][:content], second_messages[0][:content]
  end

  # --- Allowed skills nil means all allowed ---

  def test_allowed_skills_nil_allows_all
    Kernai::Skill.define(:any_skill) do
      input :query, String
      execute { |_| "works" }
    end

    assert_nil Kernai.config.allowed_skills

    @provider.respond_with(
      '<block type="command" name="any_skill">go</block>',
      '<block type="final">OK</block>'
    )

    result = Kernai::Kernel.run(@agent, "Go")
    assert_equal "OK", result
  end
end
