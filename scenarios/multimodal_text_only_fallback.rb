# frozen_string_literal: true

# Scenario: degradation. Force a text-only capability set on whichever
# model we run against, then feed it an image in the user message. The
# provider's base-class fallback should swap the Media for a textual
# placeholder (`[image unavailable: image/jpeg]`), and the agent should
# still produce a coherent — even if apologetic — final answer.
#
# This scenario is deliberately the same prompt as
# `multimodal_describe_image` with one difference: `capabilities [:text]`.
# Comparing the two side by side is the fastest way to see that the
# kernel is honouring the model's declared capabilities instead of
# shoving image bytes into a text-only endpoint.
#
#   ruby scenarios/multimodal_text_only_fallback.rb gpt-4o openai
#   PROVIDER=anthropic MODEL=claude-sonnet-4-20250514 \
#     ruby scenarios/multimodal_text_only_fallback.rb

require_relative 'harness'

IMAGE_PATH = File.join(__dir__, 'fixtures', 'four_shapes.jpg')

Scenarios.define(
  'multimodal_text_only_fallback',
  description: 'Send an image to a text-only model and verify the fallback placeholder flows cleanly'
) do
  # Force text-only regardless of what the model is actually capable of.
  capabilities %i[text]

  instructions <<~PROMPT
    You are an assistant running on a text-only channel. If the user
    sends you an image but you cannot see it, acknowledge that, explain
    what you would need to help, and ask for a textual description
    instead. Always respond via <block type="final">.
  PROMPT

  input [
    'Tell me what shapes are in this image.',
    Kernai::Media.from_file(IMAGE_PATH)
  ]

  max_steps 3
end
