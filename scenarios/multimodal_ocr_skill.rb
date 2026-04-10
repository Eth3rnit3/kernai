# frozen_string_literal: true

# Scenario: image input + skill consumer. The agent receives an image
# alongside a request, sees that the `ocr` skill `requires :vision`, and
# calls it to extract a structured result. Validates:
#
#   - Media parts are carried across skill calls (the image stays in the
#     conversation history so the skill's result can reference it).
#   - Skills declared with `requires :vision` are listed to the agent.
#   - The kernel wires a skill result (a JSON String) back into the loop
#     without touching the Media part that came before it.
#
#   ruby scenarios/multimodal_ocr_skill.rb gpt-4o openai
#   PROVIDER=anthropic MODEL=claude-sonnet-4-20250514 \
#     ruby scenarios/multimodal_ocr_skill.rb

require_relative 'harness'
require 'json'

IMAGE_PATH = File.join(__dir__, 'fixtures', 'four_shapes.jpg')

Scenarios.define(
  'multimodal_ocr_skill',
  description: 'Agent uses a vision-gated skill to catalogue the shapes in an image'
) do
  instructions <<~PROMPT
    You are a vision inspection agent. When the user shows you an image,
    you must:

    1. Call the `shape_catalogue` skill to record the shapes you observe.
       The skill takes a single JSON input with a "shapes" array listing
       the shapes you saw in the image (e.g. ["square", "circle"]).
    2. Once you receive the skill's confirmation, emit a final answer
       summarising how many shapes were catalogued.

    Respond exclusively via <block> XML.
  PROMPT

  skill(:shape_catalogue) do
    description 'Record the shapes observed in an image. Input: {"shapes": [...]}'
    input :shapes, Array
    requires :vision
    execute do |params|
      shapes = Array(params[:shapes]).map(&:to_s).map(&:downcase).uniq
      JSON.generate(status: 'ok', count: shapes.size, shapes: shapes)
    end
  end

  input [
    'Catalogue every geometric shape visible in this image.',
    Kernai::Media.from_file(IMAGE_PATH)
  ]

  max_steps 5
end
