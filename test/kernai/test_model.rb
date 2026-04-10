# frozen_string_literal: true

require_relative '../test_helper'

class TestModel < Minitest::Test
  include Kernai::TestHelpers

  def test_basic_construction
    m = Kernai::Model.new(id: 'mymodel', capabilities: %i[text vision])
    assert_equal 'mymodel', m.id
    assert_equal 'mymodel', m.to_s
    assert_equal %i[text vision], m.capabilities
  end

  def test_supports_query
    m = Kernai::Model.new(id: 'x', capabilities: %i[text vision audio_in])
    assert m.supports?(:text)
    assert m.supports?(:vision, :audio_in)
    refute m.supports?(:image_gen)
    refute m.supports?(:vision, :video_in)
  end

  def test_supported_media_inputs_maps_capabilities
    m = Kernai::Model.new(id: 'x', capabilities: %i[text vision audio_in video_in])
    assert_equal %i[image audio video], m.supported_media_inputs
  end

  def test_supported_media_inputs_empty_for_text_only
    assert_empty Kernai::Models::TEXT_ONLY.supported_media_inputs
  end

  def test_catalogue_defaults
    assert Kernai::Models::GPT_4O.supports?(:vision)
    assert Kernai::Models::CLAUDE_OPUS_4.supports?(:vision)
    refute Kernai::Models::LLAMA_3_1.supports?(:vision)
    assert Kernai::Models::LLAVA.supports?(:vision)
  end

  def test_equality
    a = Kernai::Model.new(id: 'm', capabilities: %i[text vision])
    b = Kernai::Model.new(id: 'm', capabilities: %i[text vision])
    refute_equal a.object_id, b.object_id
    assert_equal a, b
    assert_equal a.hash, b.hash
  end

  def test_id_is_required
    assert_raises(ArgumentError) { Kernai::Model.new(id: '') }
    assert_raises(ArgumentError) { Kernai::Model.new(id: nil) }
  end
end
