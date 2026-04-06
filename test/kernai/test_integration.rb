require_relative "../test_helper"
require "stringio"

class TestIntegration < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    # Silence logger during tests
    Kernai.config.logger = Kernai::Logger.new(StringIO.new)
  end

  def test_full_agent_scenario_with_skill_and_final
    # Define a "database" skill
    Kernai::Skill.define(:postgres) do
      description "Execute SQL queries"
      input :query, String

      execute do |params|
        case params[:query]
        when /users/i
          '[{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]'
        else
          "[]"
        end
      end
    end

    provider = Kernai::Mock::Provider.new
    provider.respond_with(
      '<block type="plan">I need to query the database for users</block>' \
      '<block type="command" name="postgres">SELECT * FROM users</block>',
      '<block type="final">I found 2 users: Alice and Bob.</block>'
    )

    agent = Kernai::Agent.new(
      instructions: "You are a database assistant. Use blocks to communicate.",
      provider: provider,
      model: "gpt-4",
      max_steps: 5
    )

    events = []
    result = Kernai::Kernel.run(agent, "List all users") do |event|
      events << event
    end

    # Validate result
    assert_equal "I found 2 users: Alice and Bob.", result

    # Validate events
    event_types = events.map(&:type)
    assert_includes event_types, :plan
    assert_includes event_types, :skill_result
    assert_includes event_types, :final

    # Validate skill result event
    skill_event = events.find { |e| e.type == :skill_result }
    assert_equal :postgres, skill_event.data[:skill]
    assert_includes skill_event.data[:result], "Alice"

    # Validate conversation flow
    assert_equal 2, provider.call_count
    second_messages = provider.calls[1][:messages]
    result_msg = second_messages.find { |m| m[:content].include?("result") && m[:content].include?("postgres") }
    assert result_msg
    assert_includes result_msg[:content], "Alice"
  end

  def test_multi_skill_scenario
    Kernai::Skill.define(:search) do
      description "Search documents"
      input :query, String
      execute { |p| "doc_42: relevant content about #{p[:query]}" }
    end

    Kernai::Skill.define(:summarize) do
      description "Summarize text"
      input :query, String
      execute { |p| "Summary: #{p[:query][0..20]}..." }
    end

    provider = Kernai::Mock::Provider.new
    provider.respond_with(
      '<block type="command" name="search">AI agents</block>',
      '<block type="command" name="summarize">doc_42 content</block>',
      '<block type="final">Based on my research, AI agents are autonomous systems.</block>'
    )

    agent = Kernai::Agent.new(
      instructions: "You are a research assistant.",
      provider: provider,
      model: "gpt-4",
      max_steps: 5
    )

    result = Kernai::Kernel.run(agent, "Tell me about AI agents")
    assert_equal "Based on my research, AI agents are autonomous systems.", result
    assert_equal 3, provider.call_count
  end

  def test_hot_reload_instructions_during_execution
    call_count = 0
    instructions = -> { call_count += 1; "You are assistant v#{call_count}." }

    Kernai::Skill.define(:noop) do
      input :query, String
      execute { |_| "done" }
    end

    provider = Kernai::Mock::Provider.new
    provider.respond_with(
      '<block type="command" name="noop">go</block>',
      '<block type="final">Complete</block>'
    )

    agent = Kernai::Agent.new(
      instructions: instructions,
      provider: provider,
      model: "test",
      max_steps: 5
    )

    Kernai::Kernel.run(agent, "Go")

    # Instructions lambda is re-evaluated each step, producing different system messages
    first_system = provider.calls[0][:messages][0][:content]
    second_system = provider.calls[1][:messages][0][:content]
    refute_equal first_system, second_system
    assert_includes first_system, "v"
    assert_includes second_system, "v"
  end

  def test_hot_reload_skills_during_execution
    provider = Kernai::Mock::Provider.new
    provider.on_call do |messages, _model|
      if provider.call_count == 1
        # First call: skill doesn't exist yet
        '<block type="command" name="dynamic_skill">go</block>'
      elsif provider.call_count == 2
        # Skill was registered between calls
        Kernai::Skill.define(:dynamic_skill) do
          input :query, String
          execute { |_| "dynamically loaded" }
        end
        '<block type="command" name="dynamic_skill">go</block>'
      else
        '<block type="final">Done</block>'
      end
    end

    agent = Kernai::Agent.new(
      instructions: "test",
      provider: provider,
      model: "test",
      max_steps: 5
    )

    result = Kernai::Kernel.run(agent, "Go")
    assert_equal "Done", result
  end

  def test_streaming_char_by_char
    provider = Kernai::Mock::Provider.new
    provider.respond_with('Hello <block type="final">world</block>')

    agent = Kernai::Agent.new(
      instructions: "test",
      provider: provider,
      model: "test"
    )

    text_chunks = []
    Kernai::Kernel.run(agent, "Hi") do |event|
      text_chunks << event.data if event.type == :text_chunk
    end

    full_text = text_chunks.join
    assert_equal "Hello ", full_text
  end

  def test_allowed_skills_whitelist
    Kernai::Skill.define(:allowed) do
      input :query, String
      execute { |_| "ok" }
    end

    Kernai::Skill.define(:blocked) do
      input :query, String
      execute { |_| "should not run" }
    end

    Kernai.config.allowed_skills = [:allowed]

    provider = Kernai::Mock::Provider.new
    provider.respond_with(
      '<block type="command" name="blocked">go</block>',
      '<block type="command" name="allowed">go</block>',
      '<block type="final">Done</block>'
    )

    agent = Kernai::Agent.new(
      instructions: "test",
      provider: provider,
      model: "test",
      max_steps: 5
    )

    result = Kernai::Kernel.run(agent, "Go")
    assert_equal "Done", result

    # First call had blocked skill → error injected
    second_messages = provider.calls[1][:messages]
    error_msg = second_messages.find { |m| m[:content].include?("not allowed") }
    assert error_msg
  end

  def test_error_recovery_flow
    call = 0
    Kernai::Skill.define(:flaky) do
      input :query, String
      execute do |_|
        call += 1
        raise "Connection timeout" if call == 1
        "success on retry"
      end
    end

    provider = Kernai::Mock::Provider.new
    provider.respond_with(
      '<block type="command" name="flaky">attempt</block>',
      '<block type="command" name="flaky">retry</block>',
      '<block type="final">Recovered after retry</block>'
    )

    agent = Kernai::Agent.new(
      instructions: "test",
      provider: provider,
      model: "test",
      max_steps: 5
    )

    result = Kernai::Kernel.run(agent, "Do flaky thing")
    assert_equal "Recovered after retry", result
    assert_equal 3, provider.call_count
  end

  def test_json_command_params_parsing
    received_params = nil
    Kernai::Skill.define(:api_call) do
      input :url, String
      input :method, String, default: "GET"

      execute do |params|
        received_params = params
        '{"status": 200}'
      end
    end

    provider = Kernai::Mock::Provider.new
    provider.respond_with(
      '<block type="command" name="api_call">{"url": "https://api.example.com", "method": "POST"}</block>',
      '<block type="final">API call complete</block>'
    )

    agent = Kernai::Agent.new(
      instructions: "test",
      provider: provider,
      model: "test"
    )

    Kernai::Kernel.run(agent, "Call the API")
    assert_equal "https://api.example.com", received_params[:url]
    assert_equal "POST", received_params[:method]
  end

  def test_configure_block_api
    Kernai.configure do |c|
      c.debug = true
      c.allowed_skills = [:search]
    end

    assert Kernai.config.debug
    assert_equal [:search], Kernai.config.allowed_skills
  end

  def test_provider_subclass_works_with_kernel
    custom_provider = Class.new(Kernai::Provider) do
      def call(messages:, model:, &block)
        response = '<block type="final">Custom provider response</block>'
        response.each_char { |c| block.call(c) } if block
        response
      end
    end

    agent = Kernai::Agent.new(
      instructions: "test",
      provider: custom_provider.new,
      model: "custom"
    )

    result = Kernai::Kernel.run(agent, "Hi")
    assert_equal "Custom provider response", result
  end
end
