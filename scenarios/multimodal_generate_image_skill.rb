# frozen_string_literal: true

# Scenario: skill produces a Media. Validates the "output" half of the
# multimodal loop — a skill returns a `Kernai::Media`, the kernel
# registers it in the store, injects a <block type="media"/> reference
# into the conversation, and the vision model gets a chance to describe
# what the skill just produced.
#
# The skill re-uses the pre-baked fixture image so no external image
# generation API is needed; it is still enough to exercise the full
# round-trip (Media → store → provider encode → next model turn).
#
#   ruby scenarios/multimodal_generate_image_skill.rb gpt-4o openai
#   PROVIDER=anthropic MODEL=claude-sonnet-4-20250514 \
#     ruby scenarios/multimodal_generate_image_skill.rb

require_relative 'harness'

IMAGE_PATH = File.join(__dir__, 'fixtures', 'four_shapes.jpg')

Scenarios.define(
  'multimodal_generate_image_skill',
  description: 'Skill returns a Kernai::Media, vision model then describes it'
) do
  instructions <<~PROMPT
    You are an art director. When the user asks for an image, you MUST:

    1. Call the `render_scene` skill with a short text prompt.
    2. The skill returns an image. Look at it, then emit a <block
       type="final"> describing the shapes visible in the rendered image
       (lowercased, comma-separated).

    Do not answer from imagination — always wait for the image and
    describe what you actually see.
  PROMPT

  skill(:render_scene) do
    description 'Render an illustration of the prompt. Returns an image.'
    input :prompt, String
    produces :image
    execute do |_params|
      # Deterministic stand-in for a real image generator: return the
      # fixture image as raw bytes so the scenario is reproducible
      # offline. The model still sees the bytes as an inline image in
      # the next turn.
      Kernai::Media.from_file(IMAGE_PATH)
    end
  end

  input 'Render a scene with geometric shapes, then tell me which shapes appear in it.'

  max_steps 5
end
