# frozen_string_literal: true

require_relative '../test_helper'

# `SkillContext#run_context` lets skills reach the per-Kernel.run
# Context (or a host subclass of it) so they can act on domain state
# without thread-locals or globals. Legacy skills (arity 1) are
# unaffected — they never see the skill context and keep working.
class TestSkillRunContext < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai::Skill.reset!
  end

  # --- Direct Skill#call ---

  def test_run_context_defaults_to_nil_when_not_provided
    Kernai::Skill.define(:probe) do
      input :value, String
      execute { |_p, ctx| ctx.run_context.inspect }
    end

    skill = Kernai::Skill.find(:probe)
    assert_equal 'nil', skill.call({ value: 'x' })
  end

  def test_run_context_is_forwarded_to_skill_context
    captured = nil
    Kernai::Skill.define(:probe) do
      input :value, String
      execute { |_p, ctx| captured = ctx.run_context }
    end

    ctx = Kernai::Context.new
    Kernai::Skill.find(:probe).call_in_context({ value: 'x' }, run_context: ctx)

    assert_same ctx, captured
  end

  def test_legacy_single_arg_block_still_works
    Kernai::Skill.define(:legacy) do
      input :value, String
      execute { |p| "got #{p[:value]}" }
    end

    result = Kernai::Skill.find(:legacy).call_in_context({ value: 'hi' }, run_context: Kernai::Context.new)
    assert_equal 'got hi', result
  end

  # --- Host subclass of Context ---

  def test_subclassed_run_context_flows_through_untouched
    captured = nil

    host_context_class = Class.new(Kernai::Context) do
      attr_accessor :host_payload
    end

    Kernai::Skill.define(:probe) do
      input :value, String
      execute do |_p, ctx|
        captured = ctx.run_context
      end
    end

    host_ctx = host_context_class.new
    host_ctx.host_payload = { actor_id: 'a1', ticket_id: 't1' }

    Kernai::Skill.find(:probe).call_in_context({ value: 'x' }, run_context: host_ctx)

    assert_same host_ctx, captured
    assert_equal({ actor_id: 'a1', ticket_id: 't1' }, captured.host_payload)
  end

  # --- End-to-end through Kernel.run ---

  def test_kernel_run_passes_its_context_to_every_skill_invocation
    captured = []
    Kernai::Skill.define(:probe) do
      input :value, String
      execute do |_p, ctx|
        captured << ctx.run_context
        'ok'
      end
    end

    provider = Kernai::Mock::Provider.new
    provider.respond_with_script(
      0 => '<block type="command" name="probe">x</block>',
      1 => '<block type="final">done</block>'
    )

    custom_context = Class.new(Kernai::Context) do
      attr_accessor :marker
    end.new
    custom_context.marker = :present

    agent = Kernai::Agent.new(
      instructions: 'test',
      provider: provider,
      model: Kernai::Model.new(id: 'test'),
      max_steps: 5
    )

    Kernai::Kernel.run(agent, 'Go', context: custom_context)

    assert_equal 1, captured.size
    assert_same custom_context, captured.first
    assert_equal :present, captured.first.marker
  end
end
