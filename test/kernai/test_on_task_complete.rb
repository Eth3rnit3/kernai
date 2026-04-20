# frozen_string_literal: true

require_relative '../test_helper'

# The `on_task_complete` callback on Kernel.run fires once per workflow
# sub-task (both on success and on error). It is distinct from the
# streaming `&callback` block: it's a structured completion hook meant
# for per-task persistence by the host application.
class TestOnTaskComplete < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
    @agent = Kernai::Agent.new(
      instructions: 'test',
      provider: @provider,
      model: Kernai::Model.new(id: 'test'),
      max_steps: 5
    )
  end

  # --- Not fired when no workflow ---

  def test_not_invoked_on_linear_run
    @provider.respond_with('<block type="final">OK</block>')
    fired = []

    Kernai::Kernel.run(@agent, 'hi', on_task_complete: ->(**args) { fired << args })

    assert_empty fired
  end

  # --- Fired on each successful sub-task ---

  def test_invoked_once_per_task_on_success
    plan = JSON.generate(
      goal: 'demo',
      strategy: 'sequential',
      tasks: [
        { id: 'a', input: 'do A' },
        { id: 'b', input: 'do B' }
      ]
    )

    # Root: emit the plan. Then every sub-agent (step 0 for each) emits a final.
    @provider.on_call do |messages, _model|
      joined = messages.map { |m| Array(m[:content]).grep(String).join(' ') }.join(' ')
      if joined.include?('do A')
        '<block type="final">result A</block>'
      elsif joined.include?('do B')
        '<block type="final">result B</block>'
      else
        "<block type=\"plan\">#{plan}</block>"
      end
    end

    fired = []
    Kernai::Kernel.run(@agent, 'go', on_task_complete: ->(**args) { fired << args })

    task_ids = fired.map { |f| f[:task_id] }
    assert_equal %w[a b], task_ids.sort

    fired.each do |entry|
      assert entry[:duration_ms].is_a?(Integer) && entry[:duration_ms] >= 0
      assert_nil entry[:error]
      refute_nil entry[:result]
    end
  end

  # --- Receives input, result, duration_ms, error ---

  def test_hook_receives_full_payload
    plan = JSON.generate(
      goal: 'demo',
      tasks: [{ id: 'only', input: 'produce the letter X' }]
    )

    @provider.on_call do |messages, _model|
      joined = messages.map { |m| Array(m[:content]).grep(String).join(' ') }.join(' ')
      if joined.include?('produce the letter X')
        '<block type="final">X</block>'
      else
        "<block type=\"plan\">#{plan}</block>"
      end
    end

    fired = []
    Kernai::Kernel.run(@agent, 'go', on_task_complete: ->(**args) { fired << args })

    assert_equal 1, fired.size
    entry = fired.first
    assert_equal 'only', entry[:task_id]
    assert_equal 'produce the letter X', entry[:input]
    assert_equal 'X', entry[:result]
    assert_nil entry[:error]
  end

  # --- Fired on error too ---

  def test_hook_fires_with_error_when_sub_agent_raises
    plan = JSON.generate(
      goal: 'demo',
      tasks: [{ id: 'busts', input: 'bad task' }]
    )

    @provider.on_call do |messages, _model|
      joined = messages.map { |m| Array(m[:content]).grep(String).join(' ') }.join(' ')
      if joined.include?('<block type="result" name="tasks">')
        # Root turn after the workflow completed with an error
        '<block type="final">wrapped up</block>'
      elsif joined.include?('bad task')
        # Sub-agent: never produces a terminal block → MaxStepsReachedError
        '<block type="plan">thinking</block>'
      else
        "<block type=\"plan\">#{plan}</block>"
      end
    end

    fired = []
    Kernai::Kernel.run(@agent, 'go', on_task_complete: ->(**args) { fired << args })

    assert_equal 1, fired.size
    entry = fired.first
    assert_equal 'busts', entry[:task_id]
    assert_nil entry[:result]
    refute_nil entry[:error]
    assert_match(/maximum steps|reached/i, entry[:error])
  end

  # --- Parallel tasks ---

  def test_hook_fires_for_each_parallel_task
    plan = JSON.generate(
      goal: 'demo',
      strategy: 'parallel',
      tasks: [
        { id: 'p1', input: 'do P1', parallel: true },
        { id: 'p2', input: 'do P2', parallel: true },
        { id: 'p3', input: 'do P3', parallel: true }
      ]
    )

    @provider.on_call do |messages, _model|
      joined = messages.map { |m| Array(m[:content]).grep(String).join(' ') }.join(' ')
      case joined
      when /do P1/ then '<block type="final">R1</block>'
      when /do P2/ then '<block type="final">R2</block>'
      when /do P3/ then '<block type="final">R3</block>'
      else "<block type=\"plan\">#{plan}</block>"
      end
    end

    mutex = Mutex.new
    fired = []
    Kernai::Kernel.run(@agent, 'go',
                       on_task_complete: ->(**args) { mutex.synchronize { fired << args } })

    assert_equal %w[p1 p2 p3], fired.map { |f| f[:task_id] }.sort
  end
end
