# frozen_string_literal: true

# Scenario: Sequential pipeline (🟡)
#
# Exercises an ETL-style structured plan: three tasks chained with hard
# dependencies (extract -> transform -> load). Each task runs in an isolated
# sub-agent and receives the previous task's result injected as a
# <block type="result" name="<dep_id>"> prefix.
#
# Expected behavior:
#   1. Root agent emits one <block type="plan"> containing three tasks:
#        - t_extract (no deps)
#        - t_transform (depends_on: [t_extract])
#        - t_load     (depends_on: [t_transform])
#      strategy = "sequential" (or "mixed" with parallel:false on each task).
#   2. TaskScheduler runs them in order, injecting dep results into each
#      sub-agent's input.
#   3. Root agent receives <block type="result" name="tasks"> with the final
#      counts and emits a final summary that cites the row count from t_load.
#
# Failure modes:
#   - Agent calls skills directly without a plan (the task explicitly requests
#     a workflow — direct calls count as a miss).
#   - Scheduler runs tasks out of order (would surface as missing dep data in
#     transform/load responses).
#   - Agent fabricates row counts that don't match the deterministic fixtures
#     (9 raw rows -> 7 cleaned rows -> 7 loaded rows).
#
#   ruby scenarios/sequential_pipeline.rb
#   ruby scenarios/sequential_pipeline.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'sequential_pipeline',
  description: 'Structured plan with three hard-dependent tasks (extract -> transform -> load)'
) do
  instructions <<~PROMPT
    You are a data engineering orchestrator. The user wants to run a small
    ETL job. You MUST use a structured workflow plan: emit a single
    <block type="plan"> containing a JSON workflow with exactly three tasks:

      1. "t_extract"    — pull raw rows from the `extract_rows` skill
      2. "t_transform"  — clean/normalize them via the `transform_rows` skill
                          (depends on t_extract)
      3. "t_load"       — persist the cleaned rows with the `load_rows` skill
                          (depends on t_transform)

    Use strategy "sequential". Do not call any skill directly from the root
    agent — delegate every skill call to the sub-agents via the plan. When
    the task results come back, produce a concise final report that states:
      - raw row count
      - cleaned row count
      - loaded row count
      - dataset name
  PROMPT

  skill(:extract_rows) do
    description 'Extract raw rows from the source system. Returns JSON {dataset, rows: [...]}'
    input :source, String

    execute do |_params|
      JSON.generate(
        dataset: 'signups_2026_q1',
        fetched_at: '2026-04-09T09:00:00Z',
        rows: [
          { id: 1, email: 'alice@example.com', country: 'FR', signed_up: '2026-01-02' },
          { id: 2, email: 'BOB@example.com',   country: 'DE', signed_up: '2026-01-03' },
          { id: 3, email: 'carol@example.com', country: 'FR', signed_up: '2026-01-04' },
          { id: 4, email: nil,                 country: 'ES', signed_up: '2026-01-05' },
          { id: 5, email: 'dave@example.com',  country: 'IT', signed_up: '2026-01-06' },
          { id: 6, email: 'eve@example.com',   country: 'FR', signed_up: '2026-01-07' },
          { id: 7, email: 'frank@example.com', country: 'DE', signed_up: '2026-01-08' },
          { id: 8, email: 'grace@',            country: 'PT', signed_up: '2026-01-09' },
          { id: 9, email: 'heidi@example.com', country: 'FR', signed_up: '2026-01-10' }
        ]
      )
    end
  end

  skill(:transform_rows) do
    description 'Normalize rows: lowercase email, drop rows with missing/invalid email. ' \
                'Returns JSON {cleaned_count, rows}'
    input :payload, String

    execute do |_params|
      # Deterministic: 2 rows dropped (id=4 nil email, id=8 invalid), 7 kept.
      JSON.generate(
        cleaned_count: 7,
        dropped_ids: [4, 8],
        rows: [
          { id: 1, email: 'alice@example.com', country: 'FR' },
          { id: 2, email: 'bob@example.com',   country: 'DE' },
          { id: 3, email: 'carol@example.com', country: 'FR' },
          { id: 5, email: 'dave@example.com',  country: 'IT' },
          { id: 6, email: 'eve@example.com',   country: 'FR' },
          { id: 7, email: 'frank@example.com', country: 'DE' },
          { id: 9, email: 'heidi@example.com', country: 'FR' }
        ]
      )
    end
  end

  skill(:load_rows) do
    description 'Persist cleaned rows into the analytics warehouse. Returns JSON {loaded, table}'
    input :payload, String

    execute do |_params|
      JSON.generate(
        loaded: 7,
        table: 'analytics.signups_2026_q1',
        committed_at: '2026-04-09T09:00:42Z'
      )
    end
  end

  input 'Run the signups_2026_q1 ETL: extract, clean, and load. Report the row counts.'
  max_steps 8
end
