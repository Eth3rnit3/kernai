# frozen_string_literal: true

require_relative '../test_helper'

# Encoding contract of the Provider base class: by default strings pass
# through and any Media that isn't explicitly handled is downgraded to a
# text placeholder, so text-only providers never crash on multimodal input.
class TestProviderEncoding < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @text_model = Kernai::Model.new(id: 'text', capabilities: %i[text])
    @vision_model = Kernai::Model.new(id: 'vision', capabilities: %i[text vision])
    @img = Kernai::Media.from_bytes('png', mime_type: 'image/png')
  end

  def test_base_provider_passes_strings_through
    provider = Kernai::Provider.new
    assert_equal %w[hello world], provider.encode(%w[hello world], model: @text_model)
  end

  def test_base_provider_falls_back_for_media
    provider = Kernai::Provider.new
    encoded = provider.encode(['See:', @img], model: @text_model)
    assert_equal 'See:', encoded[0]
    assert_equal '[image unavailable: image/png]', encoded[1]
  end

  def test_subclass_can_encode_media_selectively
    vision_provider = Class.new(Kernai::Provider) do
      def encode_part(part, model:)
        return part if part.is_a?(String)
        return nil unless part.is_a?(Kernai::Media) && model.supports?(:vision)

        { 'type' => 'image', 'id' => part.id }
      end
    end.new

    encoded = vision_provider.encode(['hi', @img], model: @vision_model)
    assert_equal 'hi', encoded[0]
    assert_equal({ 'type' => 'image', 'id' => @img.id }, encoded[1])
  end

  def test_subclass_fallback_kicks_in_for_unsupported_model
    vision_provider = Class.new(Kernai::Provider) do
      def encode_part(part, model:)
        return part if part.is_a?(String)
        return nil unless part.is_a?(Kernai::Media) && model.supports?(:vision)

        { 'type' => 'image', 'id' => part.id }
      end
    end.new

    encoded = vision_provider.encode(['hi', @img], model: @text_model)
    assert_equal 'hi', encoded[0]
    assert_equal '[image unavailable: image/png]', encoded[1]
  end

  # Regression: when the subclass wraps strings in a structured envelope
  # (e.g. OpenAI/Anthropic `{type: "text", text: ...}`), the fallback
  # placeholder must also be re-encoded through `encode_part` so the
  # resulting array is homogeneous. A mixed String + Hash array is
  # silently invalid against both vendors.
  def test_fallback_placeholder_is_re_encoded_by_subclass
    wrapped_provider = Class.new(Kernai::Provider) do
      def encode_part(part, model:)
        return { 'type' => 'text', 'text' => part } if part.is_a?(String)
        return nil unless part.is_a?(Kernai::Media) && model.supports?(:vision)

        { 'type' => 'image', 'id' => part.id }
      end
    end.new

    encoded = wrapped_provider.encode(['hi', @img], model: @text_model)
    assert_equal({ 'type' => 'text', 'text' => 'hi' }, encoded[0])
    assert_equal(
      { 'type' => 'text', 'text' => '[image unavailable: image/png]' },
      encoded[1]
    )
    assert encoded.all?(Hash), 'fallback must produce a homogeneous vendor array'
  end
end
