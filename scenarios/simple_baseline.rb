# frozen_string_literal: true

# Scenario: Simple baseline (🟢)
#
# Minimum viable exercise: one user question, one skill lookup, one final answer.
# Used as a smoke test — if this fails, the block protocol / skill dispatch is broken.
#
# Expected behavior:
#   1. Agent discovers skills via /skills (or uses the pre-injected catalog).
#   2. Agent calls `weather_report` once with the city name.
#   3. Agent returns a <block type="final"> that mentions temperature, condition
#      and the source timestamp from the skill payload.
#
# Failure modes:
#   - Agent hallucinates a weather report without calling the skill.
#   - Agent loops (calls the skill more than twice).
#   - Agent emits a structured plan for a trivial one-shot question (wasteful).
#
#   ruby scenarios/simple_baseline.rb
#   ruby scenarios/simple_baseline.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'simple_baseline',
  description: 'Single-skill lookup — smoke test for block protocol and skill dispatch'
) do
  instructions <<~PROMPT
    You are a concise weather assistant. You have NO prior knowledge of any weather data.
    You MUST call the `weather_report` skill exactly once before answering.
    Never guess temperature, condition, or timestamps — always cite what the skill returns.

    Your final answer must mention: city, temperature (°C), condition, and the
    observation timestamp. Keep it under 3 sentences.
  PROMPT

  skill(:weather_report) do
    description 'Fetch the latest weather observation for a city. Returns deterministic JSON.'
    input :city, String

    execute do |params|
      city = params[:city].to_s.downcase.strip
      data = {
        'paris' => { city: 'Paris', temp_c: 14.2, condition: 'Light rain',
                     observed_at: '2026-04-09T08:00:00Z', source: 'meteo-fr' },
        'tokyo' => { city: 'Tokyo', temp_c: 19.8, condition: 'Clear',
                     observed_at: '2026-04-09T08:00:00Z', source: 'jma' }
      }
      JSON.generate(data[city] || { error: "No station data for #{city}" })
    end
  end

  input 'What is the current weather in Paris?'
  max_steps 4
end
