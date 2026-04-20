# frozen_string_literal: true

require_relative '../test_helper'

class TestSkillResult < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @store = Kernai::MediaStore.new
    @img = Kernai::Media.from_bytes('png', mime_type: 'image/png')
  end

  # --- Normalisation (legacy shapes still supported) ---

  def test_wrap_string
    assert_equal ['hello'], Kernai::SkillResult.wrap('hello', @store)
  end

  def test_wrap_media_registers_in_store
    parts = Kernai::SkillResult.wrap(@img, @store)
    assert_equal [@img], parts
    assert_same @img, @store.fetch(@img.id)
  end

  def test_wrap_mixed_array
    parts = Kernai::SkillResult.wrap(['look:', @img], @store)
    assert_equal ['look:', @img], parts
    assert_same @img, @store.fetch(@img.id)
  end

  def test_wrap_nil_yields_empty_string
    assert_equal [''], Kernai::SkillResult.wrap(nil, @store)
  end

  def test_wrap_non_string_coerces_to_string
    assert_equal ['42'], Kernai::SkillResult.wrap(42, @store)
  end

  # --- Rich value object ---

  def test_new_defaults
    result = Kernai::SkillResult.new
    assert_equal '', result.text
    assert_empty result.media
    assert_empty result.metadata
  end

  def test_new_full
    result = Kernai::SkillResult.new(text: 'done', media: [@img], metadata: { score: 8 })
    assert_equal 'done', result.text
    assert_equal [@img], result.media
    assert_equal({ score: 8 }, result.metadata)
  end

  def test_new_coerces_nil_media_to_empty
    result = Kernai::SkillResult.new(text: 'x', media: nil)
    assert_empty result.media
  end

  def test_new_accepts_single_media_without_array
    result = Kernai::SkillResult.new(text: 'x', media: @img)
    assert_equal [@img], result.media
  end

  def test_to_h
    result = Kernai::SkillResult.new(text: 'ok', media: [@img], metadata: { count: 1 })
    hash = result.to_h
    assert_equal 'ok', hash[:text]
    assert_equal 1, hash[:media].size
    assert_equal({ count: 1 }, hash[:metadata])
  end

  # --- wrap with rich SkillResult ---

  def test_wrap_skill_result_splits_text_and_media
    rich = Kernai::SkillResult.new(text: 'found: ', media: [@img])
    parts = Kernai::SkillResult.wrap(rich, @store)
    assert_equal ['found: ', @img], parts
    assert_same @img, @store.fetch(@img.id)
  end

  def test_wrap_skill_result_with_text_only
    rich = Kernai::SkillResult.new(text: 'done')
    parts = Kernai::SkillResult.wrap(rich, @store)
    assert_equal ['done'], parts
  end

  # --- metadata_of helper ---

  def test_metadata_of_on_rich_result
    rich = Kernai::SkillResult.new(text: 'x', metadata: { score: 9 })
    assert_equal({ score: 9 }, Kernai::SkillResult.metadata_of(rich))
  end

  def test_metadata_of_on_legacy_returns_empty
    assert_empty Kernai::SkillResult.metadata_of('just a string')
    assert_empty Kernai::SkillResult.metadata_of(@img)
    assert_empty Kernai::SkillResult.metadata_of(nil)
  end

  # --- text_of helper ---

  def test_text_of_rich
    rich = Kernai::SkillResult.new(text: 'hello')
    assert_equal 'hello', Kernai::SkillResult.text_of(rich)
  end

  def test_text_of_string
    assert_equal 'plain', Kernai::SkillResult.text_of('plain')
  end

  def test_text_of_nil
    assert_equal '', Kernai::SkillResult.text_of(nil)
  end

  def test_text_of_array_joins_string_parts
    assert_equal 'ab', Kernai::SkillResult.text_of(['a', @img, 'b'])
  end

  # --- Kernel integration: rich SkillResult surfaces metadata in recorder ---

  def test_rich_skill_result_records_text_and_metadata
    recorder = Kernai::Recorder.new
    provider = Kernai::Mock::Provider.new
    agent = Kernai::Agent.new(
      instructions: 'test',
      provider: provider,
      model: Kernai::Model.new(id: 'test'),
      max_steps: 5
    )

    Kernai::Skill.define(:score) do
      input :value, String
      execute do |p|
        Kernai::SkillResult.new(text: "scored: #{p[:value]}", metadata: { score: 42 })
      end
    end

    provider.respond_with(
      '<block type="command" name="score">abc</block>',
      '<block type="final">OK</block>'
    )

    Kernai::Kernel.run(agent, 'Go', recorder: recorder)

    entry = recorder.for_event(:skill_result).first
    assert_equal 'scored: abc', entry[:data][:result]
    assert_equal({ score: 42 }, entry[:data][:metadata])
  end

  def test_legacy_skill_return_records_raw_value_without_metadata_key
    recorder = Kernai::Recorder.new
    provider = Kernai::Mock::Provider.new
    agent = Kernai::Agent.new(
      instructions: 'test',
      provider: provider,
      model: Kernai::Model.new(id: 'test'),
      max_steps: 5
    )

    Kernai::Skill.define(:echo) do
      input :value, String
      execute { |p| "echo: #{p[:value]}" }
    end

    provider.respond_with(
      '<block type="command" name="echo">abc</block>',
      '<block type="final">OK</block>'
    )

    Kernai::Kernel.run(agent, 'Go', recorder: recorder)

    entry = recorder.for_event(:skill_result).first
    assert_equal 'echo: abc', entry[:data][:result]
    refute entry[:data].key?(:metadata)
  end

  def test_rich_skill_result_text_goes_into_result_block
    recorder = Kernai::Recorder.new
    provider = Kernai::Mock::Provider.new
    agent = Kernai::Agent.new(
      instructions: 'test',
      provider: provider,
      model: Kernai::Model.new(id: 'test'),
      max_steps: 5
    )

    Kernai::Skill.define(:note) do
      input :value, String
      execute do |p|
        Kernai::SkillResult.new(text: "wrote: #{p[:value]}", metadata: { internal: true })
      end
    end

    provider.respond_with(
      '<block type="command" name="note">hello</block>',
      '<block type="final">OK</block>'
    )

    Kernai::Kernel.run(agent, 'Go', recorder: recorder)

    # Step 1 is the LLM reading the result block — check the messages it received.
    step1_messages = recorder.for_step(1).find { |e| e[:event] == :messages_sent }[:data]
    result_msg = step1_messages.find { |m| m[:content].to_s.include?('wrote: hello') }
    assert result_msg, 'Expected the injected result block to contain the rich text'
    refute_includes result_msg[:content].to_s, 'internal',
                    'Metadata must NOT leak into the LLM-facing result block'
  end
end
