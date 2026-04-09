# frozen_string_literal: true

# Scenario: Parallel fan-out + aggregation (🔴)
#
# Three independent market feeds must be queried in parallel, then one
# aggregator task (depending on all three) computes a weighted average.
# This scenario directly stresses the TaskScheduler's parallel execution
# branch AND its dependency gating: the aggregator MUST wait for all
# parallel feeds to complete before it receives their results.
#
# Expected plan shape:
#   strategy: "mixed" (or "parallel" with aggregator manually flagged
#   sequential via depends_on — the scheduler still waits on deps even in
#   "parallel" mode, so either is correct).
#
#   tasks:
#     - t_feed_ny    (parallel: true, depends_on: [])
#     - t_feed_ln    (parallel: true, depends_on: [])
#     - t_feed_tk    (parallel: true, depends_on: [])
#     - t_aggregate  (parallel: false, depends_on: [t_feed_ny, t_feed_ln, t_feed_tk])
#
# Expected behavior:
#   1. Root agent emits the plan above in a single <block type="plan">.
#   2. Scheduler runs the three feed tasks concurrently (verify via thread
#      timing if needed — they should not be serialized).
#   3. Aggregator sub-agent receives all three result blocks as prefix and
#      returns a weighted average using the volumes.
#   4. Root agent reports: per-venue price, weighted average, dominant venue.
#
# Failure modes:
#   - Agent emits a single task that loops over venues (defeats parallelism).
#   - Aggregator runs before one of the feeds finishes.
#   - Root agent bypasses the plan and calls feeds directly.
#   - Final report cites a naïve arithmetic mean instead of a weighted one.
#
# Deterministic expected result:
#   NY:  price=101.20, volume=5_000_000
#   LN:  price=100.80, volume=3_000_000
#   TK:  price=101.00, volume=2_000_000
#   weighted avg = (101.20*5 + 100.80*3 + 101.00*2) / 10 = 101.04
#
#   ruby scenarios/parallel_fanout_aggregation.rb
#   ruby scenarios/parallel_fanout_aggregation.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'parallel_fanout_aggregation',
  description: 'Parallel fan-out (3 market feeds) + one aggregator task depending on all of them'
) do
  instructions <<~PROMPT
    You are a trading desk assistant. The user wants the current consolidated
    price for ticker ACME across three venues (NY, LN, TK).

    You MUST emit a structured workflow plan that:
      - Queries every venue IN PARALLEL via `market_feed`
        (one task per venue, parallel: true, no depends_on).
      - Aggregates results in a SINGLE "t_aggregate" task that depends_on
        the three feed task ids.

    The aggregator sub-agent should compute a volume-weighted average price
    and identify the dominant venue (highest volume). Do NOT call skills
    directly from the root agent — everything goes through the plan.

    When the <block type="result" name="tasks"> comes back, your final
    answer must include: per-venue price, weighted average price (2 decimals),
    total volume, and the dominant venue.
  PROMPT

  skill(:market_feed) do
    description 'Fetch the latest trade print for a ticker on a specific venue. Returns JSON.'
    input :venue, String

    execute do |params|
      venue = params[:venue].to_s.upcase.strip
      data = {
        'NY' => { venue: 'NY', ticker: 'ACME', price: 101.20, volume: 5_000_000,
                  as_of: '2026-04-09T13:00:00Z' },
        'LN' => { venue: 'LN', ticker: 'ACME', price: 100.80, volume: 3_000_000,
                  as_of: '2026-04-09T13:00:00Z' },
        'TK' => { venue: 'TK', ticker: 'ACME', price: 101.00, volume: 2_000_000,
                  as_of: '2026-04-09T13:00:00Z' }
      }
      # Simulate network latency so parallel execution is observable in logs.
      sleep 0.3
      JSON.generate(data[venue] || { error: "Unknown venue #{venue}" })
    end
  end

  input 'Give me the consolidated price for ACME across NY, LN and TK right now.'
  max_steps 8
end
