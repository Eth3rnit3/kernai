# frozen_string_literal: true

# Scenario: Invalid plan is ignored — agent must fall back (⚫)
#
# This scenario tests Plan.parse's fail-safe contract. The system prompt
# primes the agent to emit a DELIBERATELY malformed plan on its first turn
# (missing required fields), then fall back to direct skill calls.
#
# The kernel should:
#   - Parse the first plan block, get back `nil` from Plan.parse, and leave
#     `ctx.plan` unset.
#   - Treat the block as purely informational (emit_informational_blocks).
#   - Continue the loop. Because no command block was produced on step 1,
#     the agent emits nothing actionable and the next step should recover.
#
# Expected behavior:
#   1. Step 1: agent produces a plan JSON missing the "tasks" key (or with
#      an empty tasks array). Kernel silently discards it.
#   2. Step 2: agent notices nothing happened, switches to direct
#      <block type="command" name="fx_rate"> calls.
#   3. Step 3: agent produces a final answer citing the rate from the skill.
#
# Failure modes:
#   - Kernel crashes on the invalid plan instead of ignoring it.
#   - Kernel tries to execute the malformed plan (e.g. treating 0 tasks as
#     a successful workflow and returning an empty result block).
#   - Agent never recovers and reaches max_steps.
#
#   ruby scenarios/invalid_plan_fallback.rb
#   ruby scenarios/invalid_plan_fallback.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'invalid_plan_fallback',
  description: 'Malformed plan must be ignored by Plan.parse — agent has to fall back to direct skill calls'
) do
  instructions <<~PROMPT
    You are a currency conversion agent. On your FIRST turn, as a self-test
    of the workflow system, emit this deliberately malformed plan EXACTLY:

    <block type="plan">{"goal": "convert currency", "strategy": "parallel"}</block>

    (Note: it has no "tasks" field — this is intentional. The framework
    should treat it as invalid and ignore it.)

    On your SECOND turn, if nothing has happened, switch to direct skill
    calls: use `fx_rate` to look up the EUR->USD rate, then produce a
    <block type="final"> answer with the numeric rate and the quoted
    timestamp. Never mix a plan block and a command block in the same turn.
  PROMPT

  skill(:fx_rate) do
    description 'Look up a spot FX rate. Returns JSON {pair, rate, quoted_at}.'
    input :pair, String

    execute do |params|
      pair = params[:pair].to_s.upcase.delete(' ').gsub('/', '')
      rates = {
        'EURUSD' => { pair: 'EUR/USD', rate: 1.0842, quoted_at: '2026-04-09T12:00:00Z' },
        'USDJPY' => { pair: 'USD/JPY', rate: 151.74, quoted_at: '2026-04-09T12:00:00Z' }
      }
      JSON.generate(rates[pair] || { error: "No quote for #{pair}" })
    end
  end

  input 'What is the current EUR/USD rate?'
  max_steps 6
end
