# frozen_string_literal: true

require_relative '../test_helper'

# End-to-end: does the kernel thread Media through the loop, hand it to
# providers, surface it from skills, and filter skills by model capability?
class TestMultimodalKernel < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
    @vision_model = Kernai::Model.new(id: 'vision-1', capabilities: %i[text vision])
    @text_model = Kernai::Model.new(id: 'text-1', capabilities: %i[text])
  end

  # --- Input ---

  def test_media_input_reaches_provider_as_part
    img = Kernai::Media.from_bytes('png', mime_type: 'image/png')
    agent = Kernai::Agent.new(
      instructions: 'describe the image',
      provider: @provider,
      model: @vision_model,
      max_steps: 2
    )

    @provider.respond_with('<block type="final">a cat</block>')
    Kernai::Kernel.run(agent, ['What is this?', img])

    user_msg = @provider.last_call[:messages].find { |m| m[:role] == :user }
    assert_equal 'What is this?', user_msg[:content][0]
    assert_same img, user_msg[:content][1]
  end

  def test_media_input_registered_in_store
    img = Kernai::Media.from_bytes('png', mime_type: 'image/png')
    agent = Kernai::Agent.new(
      instructions: 'x', provider: @provider, model: @vision_model, max_steps: 2
    )
    @provider.respond_with('<block type="final">ok</block>')

    ctx = Kernai::Context.new
    Kernai::Kernel.run(agent, [img], context: ctx)

    assert_same img, ctx.media_store.fetch(img.id)
  end

  # --- Skill returning media ---

  def test_skill_returning_media_injects_media_part_in_result_message
    generated = Kernai::Media.from_bytes('imgdata', mime_type: 'image/png')
    Kernai::Skill.define(:draw) do
      description 'Draw an image'
      input :prompt, String
      produces :image
      execute { |_| generated }
    end

    agent = Kernai::Agent.new(
      instructions: 'draw things',
      provider: @provider,
      model: @vision_model,
      max_steps: 3,
      skills: :all
    )

    @provider.respond_with(
      '<block type="command" name="draw">a cat</block>',
      '<block type="final">drawn</block>'
    )

    ctx = Kernai::Context.new
    Kernai::Kernel.run(agent, 'draw a cat', context: ctx)

    second_call_user_msgs = @provider.calls[1][:messages].select { |m| m[:role] == :user }
    result_msg = second_call_user_msgs.find { |m| m[:content].grep(Kernai::Media).any? }
    refute_nil result_msg, 'skill result must carry the produced media as a part'
    assert_same generated, result_msg[:content].grep(Kernai::Media).first
    assert_includes result_msg[:content].join, '<block type="media"'
    assert_same generated, ctx.media_store.fetch(generated.id)
  end

  # --- Capability-driven skill filtering ---

  def test_runnable_on_filters_vision_skill_on_text_only_model
    Kernai::Skill.define(:describe_image) do
      description 'Describe an image'
      input :image, Kernai::Media
      requires :vision
      execute { |_| 'ok' }
    end
    Kernai::Skill.define(:echo) do
      description 'Echo text'
      input :text, String
      execute { |p| p[:text] }
    end

    listing = Kernai::Skill.listing(:all, model: @text_model)
    refute_includes listing, 'describe_image'
    assert_includes listing, 'echo'

    listing_vision = Kernai::Skill.listing(:all, model: @vision_model)
    assert_includes listing_vision, 'describe_image'
    assert_includes listing_vision, 'echo'
  end

  def test_skills_builtin_scopes_to_runnable
    Kernai::Skill.define(:describe_image) do
      description 'Describe an image'
      input :image, Kernai::Media
      requires :vision
      execute { |_| 'ok' }
    end

    agent = Kernai::Agent.new(
      instructions: 'x',
      provider: @provider,
      model: @text_model,
      max_steps: 3,
      skills: :all
    )

    @provider.respond_with(
      '<block type="command" name="/skills"></block>',
      '<block type="final">ok</block>'
    )

    Kernai::Kernel.run(agent, 'list')

    skills_result = @provider.calls[1][:messages].find do |m|
      m[:role] == :user && m[:content].join.include?('name="/skills"')
    end
    refute_includes skills_result[:content].join, 'describe_image'
  end

  # --- Instruction builder sections ---

  def test_instruction_builder_injects_media_input_section_on_vision_model
    builder = Kernai::InstructionBuilder.new('Base.', model: @vision_model, skills: :all)
    rendered = builder.build
    assert_includes rendered, 'MULTIMODAL INPUTS'
    assert_includes rendered, 'image'
  end

  def test_instruction_builder_skips_media_sections_on_text_only_model
    builder = Kernai::InstructionBuilder.new('Base.', model: @text_model, skills: :all)
    rendered = builder.build
    refute_includes rendered, 'MULTIMODAL INPUTS'
    refute_includes rendered, 'MULTIMODAL OUTPUTS'
  end

  def test_instruction_builder_injects_media_output_section_on_image_gen_model
    model = Kernai::Model.new(id: 'gen-1', capabilities: %i[text image_gen])
    builder = Kernai::InstructionBuilder.new('Base.', model: model, skills: :all)
    rendered = builder.build
    assert_includes rendered, 'MULTIMODAL OUTPUTS'
    assert_includes rendered, 'images'
  end
end
