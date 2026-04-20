# frozen_string_literal: true

require_relative '../test_helper'

# Token-accounting helpers on Recorder, driven by `:llm_response` entries.
class TestRecorderTokens < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @recorder = Kernai::Recorder.new
    @provider = Kernai::Mock::Provider.new
    @agent = Kernai::Agent.new(
      instructions: 'test',
      provider: @provider,
      model: Kernai::Model.new(id: 'test'),
      max_steps: 5
    )
  end

  # --- Empty / no llm_response entries ---

  def test_token_usage_when_no_llm_response_recorded
    usage = @recorder.token_usage
    assert_nil usage[:prompt_tokens]
    assert_nil usage[:completion_tokens]
    assert_nil usage[:total_tokens]
  end

  def test_token_usage_per_step_empty
    assert_empty @recorder.token_usage_per_step
  end

  # --- Single-step aggregate ---

  def test_token_usage_aggregates_single_response
    @provider
      .respond_with('<block type="final">OK</block>')
      .with_token_counter { |_m, _c| { prompt_tokens: 10, completion_tokens: 5 } }

    Kernai::Kernel.run(@agent, 'hi', recorder: @recorder)

    usage = @recorder.token_usage
    assert_equal 10, usage[:prompt_tokens]
    assert_equal 5, usage[:completion_tokens]
    assert_equal 15, usage[:total_tokens]
  end

  # --- Multi-step aggregation ---

  def test_token_usage_sums_across_steps
    Kernai::Skill.define(:tick) do
      input :value, String
      execute { |_p| 'done' }
    end

    @provider
      .respond_with(
        '<block type="command" name="tick">go</block>',
        '<block type="final">All done</block>'
      )
      .with_token_counter { |_m, c| { prompt_tokens: 20, completion_tokens: c.length } }

    Kernai::Kernel.run(@agent, 'hi', recorder: @recorder)

    usage = @recorder.token_usage
    assert_equal 40, usage[:prompt_tokens] # 20 + 20 across both steps

    per_step = @recorder.token_usage_per_step
    assert_equal [0, 1], per_step.keys.sort
    assert_equal 20, per_step[0][:prompt_tokens]
    assert_equal 20, per_step[1][:prompt_tokens]
  end

  # --- Missing fields (provider didn't fill them) ---

  def test_token_usage_nil_when_provider_does_not_fill
    @provider.respond_with('<block type="final">OK</block>')
    # no with_token_counter → LlmResponse has nil tokens

    Kernai::Kernel.run(@agent, 'hi', recorder: @recorder)

    usage = @recorder.token_usage
    assert_nil usage[:prompt_tokens]
    assert_nil usage[:completion_tokens]
    assert_nil usage[:total_tokens]
  end

  def test_token_usage_partial_fill
    Kernai::Skill.define(:noop) do
      input :value, String
      execute { |_| 'ok' }
    end

    # Step 0 fills tokens, step 1 does not.
    call_count = 0
    @provider
      .respond_with(
        '<block type="command" name="noop">x</block>',
        '<block type="final">done</block>'
      )
      .with_token_counter do |_m, _c|
        call_count += 1
        call_count == 1 ? { prompt_tokens: 10, completion_tokens: 3 } : {}
      end

    Kernai::Kernel.run(@agent, 'hi', recorder: @recorder)

    usage = @recorder.token_usage
    assert_equal 10, usage[:prompt_tokens]
    assert_equal 3, usage[:completion_tokens]
    assert_equal 13, usage[:total_tokens]
  end

  # --- token_usage_per_task ---

  def test_token_usage_per_task_groups_under_root_when_no_task_id
    @provider
      .respond_with('<block type="final">OK</block>')
      .with_token_counter { |_m, _c| { prompt_tokens: 7, completion_tokens: 2 } }

    Kernai::Kernel.run(@agent, 'hi', recorder: @recorder)

    per_task = @recorder.token_usage_per_task
    assert_equal [:root], per_task.keys
    assert_equal 7, per_task[:root][:prompt_tokens]
  end

  def test_token_usage_per_task_separates_sub_agent_scopes
    # Simulate a sub-agent scope by writing llm_response entries directly.
    @recorder.record(step: 0, event: :llm_response,
                     data: { prompt_tokens: 5, completion_tokens: 1, total_tokens: 6 })
    @recorder.record(step: 0, event: :llm_response,
                     data: { prompt_tokens: 3, completion_tokens: 2, total_tokens: 5 },
                     scope: { depth: 1, task_id: 'task_a' })
    @recorder.record(step: 0, event: :llm_response,
                     data: { prompt_tokens: 4, completion_tokens: 1, total_tokens: 5 },
                     scope: { depth: 1, task_id: 'task_b' })

    per_task = @recorder.token_usage_per_task
    assert_equal 5, per_task[:root][:prompt_tokens]
    assert_equal 3, per_task['task_a'][:prompt_tokens]
    assert_equal 4, per_task['task_b'][:prompt_tokens]
  end
end
