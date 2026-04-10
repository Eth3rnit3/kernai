# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Integration tests for the Kernel's structured plan workflow: plan parsing,
# sub-agent dispatch, parallelism, dependencies, depth protection and the
# /workflow and /tasks built-in commands.
class TestWorkflow < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
    @agent = Kernai::Agent.new(
      instructions: 'You are a manager.',
      provider: @provider,
      model: Kernai::Model.new(id: 'test-model'),
      max_steps: 5,
      skills: :all
    )
    @manager_calls = []
  end

  def plan_block(tasks, strategy: 'mixed', goal: 'test')
    json = JSON.generate(goal: goal, strategy: strategy, tasks: tasks)
    "<block type=\"plan\">#{json}</block>"
  end

  # Dispatch incoming provider calls: a call is either the manager (system
  # instructions contain /workflow) or a sub-agent (they don't). The block
  # form lets each test supply deterministic responses.
  def wire(manager:, sub:)
    manager_step = 0
    @provider.on_call do |messages, _model|
      system_msg = messages[0][:content].join
      if system_msg.include?('/workflow')
        @manager_calls << { messages: messages }
        response = manager.call(manager_step, messages)
        manager_step += 1
        response
      else
        sub.call(messages.last[:content].join, messages)
      end
    end
  end

  # --- Simple workflow ---

  def test_single_task_workflow_returns_final_answer
    wire(
      manager: lambda { |step, _m|
        step.zero? ? plan_block([{ id: 'greet', input: 'say hello' }]) : '<block type="final">all done</block>'
      },
      sub: ->(_input, _m) { '<block type="final">hello</block>' }
    )

    result = Kernai::Kernel.run(@agent, 'greet')
    assert_equal 'all done', result
  end

  def test_manager_receives_aggregated_results
    wire(
      manager: lambda { |step, _m|
        if step.zero?
          plan_block([{ id: 't1', input: 'do one' }, { id: 't2', input: 'do two' }])
        else
          '<block type="final">ok</block>'
        end
      },
      sub: lambda do |input, _m|
        if input.include?('do one')
          '<block type="final">result-1</block>'
        else
          '<block type="final">result-2</block>'
        end
      end
    )

    Kernai::Kernel.run(@agent, 'go')

    second_manager_call = @manager_calls.last
    result_msg = second_manager_call[:messages].find do |m|
      m[:role] == :user && m[:content].join.include?('<block type="result" name="tasks">')
    end
    refute_nil result_msg
    assert_includes result_msg[:content].join, 'result-1'
    assert_includes result_msg[:content].join, 'result-2'
  end

  # --- Parallelism ---

  def test_parallel_tasks_execute_concurrently
    mutex = Mutex.new
    current = 0
    max_concurrent = 0

    wire(
      manager: lambda { |step, _m|
        if step.zero?
          plan_block(
            [
              { id: 'a', input: 'do a', parallel: true },
              { id: 'b', input: 'do b', parallel: true },
              { id: 'c', input: 'do c', parallel: true }
            ],
            strategy: 'parallel'
          )
        else
          '<block type="final">finished</block>'
        end
      },
      sub: lambda do |_input, _m|
        mutex.synchronize do
          current += 1
          max_concurrent = current if current > max_concurrent
        end
        sleep 0.03
        mutex.synchronize { current -= 1 }
        '<block type="final">done</block>'
      end
    )

    Kernai::Kernel.run(@agent, 'go')
    assert_equal 3, max_concurrent
  end

  # --- Dependencies ---

  def test_dependencies_respected
    order = []
    order_mutex = Mutex.new

    wire(
      manager: lambda { |step, _m|
        if step.zero?
          plan_block(
            [
              { id: 'b', input: 'task-b', depends_on: ['a'] },
              { id: 'a', input: 'task-a' }
            ]
          )
        else
          '<block type="final">ok</block>'
        end
      },
      sub: lambda do |input, _m|
        letter = input.include?('task-a') ? 'a' : 'b'
        order_mutex.synchronize { order << letter }
        "<block type=\"final\">done-#{letter}</block>"
      end
    )

    Kernai::Kernel.run(@agent, 'go')
    assert_equal %w[a b], order
  end

  def test_dependency_result_injected_into_dependent_task_input
    seen_b_input = nil

    wire(
      manager: lambda { |step, _m|
        if step.zero?
          plan_block(
            [
              { id: 'a', input: 'task-a' },
              { id: 'b', input: 'task-b', depends_on: ['a'] }
            ]
          )
        else
          '<block type="final">ok</block>'
        end
      },
      sub: lambda do |input, _m|
        if input.include?('task-a')
          '<block type="final">A-RESULT</block>'
        else
          seen_b_input = input
          '<block type="final">B-RESULT</block>'
        end
      end
    )

    Kernai::Kernel.run(@agent, 'go')
    refute_nil seen_b_input
    assert_includes seen_b_input, 'A-RESULT'
    assert_includes seen_b_input, 'task-b'
  end

  # --- Depth protection ---

  def test_sub_agent_cannot_spawn_nested_plan
    sub_called = 0
    wire(
      manager: lambda { |step, _m|
        step.zero? ? plan_block([{ id: 'work', input: 'work' }]) : '<block type="final">manager done</block>'
      },
      sub: lambda do |_input, _m|
        sub_called += 1
        # Sub-agent returns a nested plan (which must be ignored) plus a final.
        "#{plan_block([{ id: 'nested', input: 'should be ignored' }])}<block type=\"final\">sub-done</block>"
      end
    )

    result = Kernai::Kernel.run(@agent, 'go')
    assert_equal 'manager done', result
    assert_equal 1, sub_called, 'only the top-level sub-agent call should have run'

    manager_result = @manager_calls.last[:messages].find do |m|
      m[:role] == :user && m[:content].join.include?('<block type="result" name="tasks">')
    end
    refute_nil manager_result
    assert_includes manager_result[:content].join, 'sub-done'
  end

  def test_sub_agent_system_instructions_omit_workflow_hint
    captured_system = nil
    wire(
      manager: lambda { |step, _m|
        step.zero? ? plan_block([{ id: 'x', input: 'x' }]) : '<block type="final">ok</block>'
      },
      sub: lambda do |_input, messages|
        captured_system = messages[0][:content]
        '<block type="final">x-done</block>'
      end
    )

    Kernai::Kernel.run(@agent, 'go')
    refute_nil captured_system
    refute_includes captured_system, '/workflow'
    refute_includes captured_system, '/tasks'
  end

  # Regression: sub-agents must inherit the parent's full max_steps budget.
  # Previously they silently received parent.max_steps / 2, which left
  # verbose models stuck at MaxStepsReachedError right after they had
  # completed the useful work — the halved budget was not enough to emit
  # a <final> block at the end of a realistic tool-calling loop.
  def test_sub_agent_inherits_full_max_steps_from_parent
    # Feed the sub-agent enough turns that it would exceed the old halved
    # budget (parent.max_steps = 5, old sub budget = 2) but stay within
    # the full inherited budget (= 5). A 3-turn sub-agent run proves the
    # budget is > 2.
    sub_steps = 0
    wire(
      manager: lambda { |step, _m|
        step.zero? ? plan_block([{ id: 'long', input: 'work' }]) : '<block type="final">ok</block>'
      },
      sub: lambda do |_input, _messages|
        sub_steps += 1
        case sub_steps
        when 1 then '<block type="command" name="/skills"></block>'
        when 2 then '<block type="command" name="/skills"></block>'
        when 3 then '<block type="command" name="/skills"></block>'
        else        '<block type="final">sub-done</block>'
        end
      end
    )

    result = Kernai::Kernel.run(@agent, 'go')
    assert_equal 'ok', result
    assert_equal 4, sub_steps, 'sub-agent must be allowed more than parent.max_steps / 2 steps'
  end

  # --- Isolation ---

  def test_parallel_sub_agents_run_in_isolation
    thread_ids = []
    mutex = Mutex.new

    wire(
      manager: lambda { |step, _m|
        if step.zero?
          plan_block(
            [
              { id: 'p1', input: 'p1', parallel: true },
              { id: 'p2', input: 'p2', parallel: true }
            ]
          )
        else
          '<block type="final">done</block>'
        end
      },
      sub: lambda do |_input, _m|
        mutex.synchronize { thread_ids << Thread.current.object_id }
        sleep 0.02
        '<block type="final">ok</block>'
      end
    )

    Kernai::Kernel.run(@agent, 'go')
    assert_equal 2, thread_ids.uniq.size, 'parallel sub-agents must run on separate threads'
  end

  # --- Fail-safe ---

  def test_invalid_plan_content_is_ignored_and_falls_through_to_final
    @provider.respond_with(
      '<block type="plan">not valid json</block><block type="final">done</block>'
    )
    result = Kernai::Kernel.run(@agent, 'go')
    assert_equal 'done', result
  end

  def test_plan_block_without_tasks_emits_plan_event_not_workflow
    @provider.respond_with(
      '<block type="plan">I am thinking about this.</block><block type="final">OK</block>'
    )
    events = []
    Kernai::Kernel.run(@agent, 'go') { |e| events << e.type }
    assert_includes events, :plan
    refute_includes events, :workflow_start
  end

  # --- /workflow ---

  def test_workflow_command_returns_documentation
    @provider.respond_with(
      '<block type="command" name="/workflow"></block>',
      '<block type="final">ok</block>'
    )

    Kernai::Kernel.run(@agent, 'show docs')

    doc_msg = @provider.calls[1][:messages].find do |m|
      m[:role] == :user && m[:content].join.include?('<block type="result" name="/workflow">')
    end
    refute_nil doc_msg
    assert_includes doc_msg[:content].join, 'strategy'
    assert_includes doc_msg[:content].join, 'depends_on'
    assert_includes doc_msg[:content].join, 'parallel'
  end

  def test_workflow_command_emits_builtin_result_event
    @provider.respond_with(
      '<block type="command" name="/workflow"></block>',
      '<block type="final">ok</block>'
    )
    events = []
    Kernai::Kernel.run(@agent, 'go') { |e| events << e if e.type == :builtin_result }
    assert_equal 1, events.size
    assert_equal '/workflow', events.first.data[:command]
  end

  # --- /tasks ---

  def test_tasks_command_returns_empty_state_before_plan
    @provider.respond_with(
      '<block type="command" name="/tasks"></block>',
      '<block type="final">ok</block>'
    )

    Kernai::Kernel.run(@agent, 'show state')

    tasks_msg = @provider.calls[1][:messages].find do |m|
      m[:role] == :user && m[:content].join.include?('<block type="result" name="/tasks">')
    end
    refute_nil tasks_msg
    payload = tasks_msg[:content].join[%r{<block type="result" name="/tasks">(.*?)</block>}m, 1]
    parsed = JSON.parse(payload)
    assert_kind_of Hash, parsed
    assert_equal [], parsed['tasks']
    assert_equal 0, parsed['depth']
  end

  def test_tasks_command_reflects_hydrated_plan_state
    wire(
      manager: lambda do |step, _m|
        case step
        when 0
          plan_block([{ id: 'a', input: 'task-a' }, { id: 'b', input: 'task-b' }])
        when 1
          '<block type="command" name="/tasks"></block>'
        else
          '<block type="final">done</block>'
        end
      end,
      sub: lambda do |input, _m|
        letter = input.include?('task-a') ? 'A' : 'B'
        "<block type=\"final\">#{letter}</block>"
      end
    )

    Kernai::Kernel.run(@agent, 'go')

    # After workflow + /tasks, the third manager call carries the /tasks result
    tasks_msg = @manager_calls[2][:messages].find do |m|
      m[:role] == :user && m[:content].join.include?('<block type="result" name="/tasks">')
    end
    refute_nil tasks_msg
    payload = tasks_msg[:content].join[%r{<block type="result" name="/tasks">(.*?)</block>}m, 1]
    parsed = JSON.parse(payload)
    assert_equal 2, parsed['tasks'].size
    ids = parsed['tasks'].map { |t| t['id'] }.sort
    assert_equal %w[a b], ids
    assert(parsed['tasks'].all? { |t| t['status'] == 'done' })
    assert_equal 'A', parsed['task_results']['a']
    assert_equal 'B', parsed['task_results']['b']
  end

  # --- Unknown command stays unknown ---

  def test_unknown_builtin_still_errors
    @provider.respond_with(
      '<block type="command" name="/mystery"></block>',
      '<block type="final">ok</block>'
    )
    result = Kernai::Kernel.run(@agent, 'go')
    assert_equal 'ok', result
    err = @provider.calls[1][:messages].find do |m|
      m[:content].join.include?('error') && m[:content].join.include?('/mystery')
    end
    refute_nil err
  end

  # --- Instruction hint ---

  def test_instructions_include_workflow_hint_when_enabled
    text = @agent.resolve_instructions(workflow_enabled: true)
    assert_includes text, '/workflow'
    assert_includes text, '/tasks'
    assert_includes text, 'Structured workflows'
  end

  def test_instructions_omit_workflow_hint_when_disabled
    text = @agent.resolve_instructions(workflow_enabled: false)
    refute_includes text, '/workflow'
    refute_includes text, '/tasks'
    refute_includes text, 'Structured workflows'
  end

  # --- Recorder captures workflow events ---

  def test_recorder_captures_workflow_lifecycle
    wire(
      manager: lambda { |step, _m|
        step.zero? ? plan_block([{ id: 't', input: 't' }]) : '<block type="final">done</block>'
      },
      sub: ->(_input, _m) { '<block type="final">result</block>' }
    )

    recorder = Kernai::Recorder.new
    Kernai::Kernel.run(@agent, 'go', recorder: recorder)

    starts = recorder.for_event(:workflow_start)
    completes = recorder.for_event(:workflow_complete)
    assert_equal 1, starts.size
    assert_equal 1, completes.size
  end
end
