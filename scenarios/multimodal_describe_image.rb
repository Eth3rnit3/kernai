# frozen_string_literal: true

# Scenario: vision input — the model must actually look at an image and
# name the geometric shapes it sees. No skills, no tools: this isolates
# the "did the image travel end-to-end through the provider?" question.
#
#   ruby scenarios/multimodal_describe_image.rb gpt-4o openai
#   PROVIDER=anthropic MODEL=claude-sonnet-4-20250514 \
#     ruby scenarios/multimodal_describe_image.rb
#   PROVIDER=ollama    MODEL=llava \
#     ruby scenarios/multimodal_describe_image.rb

require_relative 'harness'

IMAGE_PATH = File.join(__dir__, 'fixtures', 'four_shapes.jpg')

Scenarios.define(
  'multimodal_describe_image',
  description: 'Vision model must name the shapes in an image passed as a Media part'
) do
  instructions <<~PROMPT
    You are a vision test subject. The user will provide an image
    alongside a text question. Look at the image, then respond with a
    SINGLE <block type="final"> listing the geometric shapes you can
    see, lowercased, comma-separated, in no particular order.

    The image will be a simple figure on white background containing a
    square, a circle, a triangle, and a rounded rectangle (four shapes
    total). Do not invent shapes that are not there.

    You MUST respond with exactly one <block type="final">...</block>
    and nothing else.
  PROMPT

  input [
    'List every distinct geometric shape you see in this image.',
    Kernai::Media.from_file(IMAGE_PATH)
  ]

  max_steps 3
end
