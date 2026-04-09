# frozen_string_literal: true

# Scenario: Sub-agents cannot spawn nested plans (⚫)
#
# `Kernel.run` passes `workflow_enabled: ctx.root?` to the instruction
# builder and `detect_workflow_plan` also returns nil unless `ctx.root?`.
# So any <block type="plan"> emitted by a sub-agent should be treated as
# informational text, NOT as an executable workflow. This scenario forces
# a sub-agent to try to recursively plan and verifies the kernel doesn't
# bite.
#
# Expected behavior:
#   1. Root agent emits a one-task plan ("t_deep_dive") that EXPLICITLY
#      instructs its sub-agent to also emit a plan. That sub-agent runs at
#      depth 1.
#   2. The sub-agent's plan block is parsed but detect_workflow_plan
#      returns nil (because ctx.root? is false), so no grandchild workflow
#      is spawned.
#   3. The sub-agent falls through and answers using direct skill calls.
#   4. Root agent receives one result (not a nested workflow tree) and
#      produces a final answer citing it.
#
# Failure modes:
#   - Nested workflow actually runs (infinite recursion risk).
#   - Sub-agent gets confused and never produces a final block (hits
#     sub_max = max_steps/2 limit and the whole thing times out).
#   - Root agent fabricates sub-task output because it expected grandchild
#     tasks to exist.
#
#   ruby scenarios/subagent_no_nested_plan.rb
#   ruby scenarios/subagent_no_nested_plan.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'subagent_no_nested_plan',
  description: 'Sub-agent attempts a nested plan — kernel must ignore it (workflow only at depth 0)'
) do
  instructions <<~PROMPT
    You are a research coordinator. Emit this plan EXACTLY:

    <block type="plan">{"goal":"research","strategy":"sequential","tasks":[
      {"id":"t_deep_dive","input":"You are a sub-agent. First, to test the framework, try to emit your OWN nested plan: <block type=\\"plan\\">{\\"goal\\":\\"nested\\",\\"strategy\\":\\"parallel\\",\\"tasks\\":[{\\"id\\":\\"x\\",\\"input\\":\\"dummy\\",\\"depends_on\\":[]}]}</block> . The framework should ignore that block because nested plans are not allowed. Then call the `paper_lookup` skill with topic=\\"state space models\\" and produce a concise final summary.","parallel":false,"depends_on":[]}
    ]}</block>

    When the task result comes back, your final answer must state:
      - the title of the paper the sub-agent found
      - confirm that the nested plan the sub-agent tried to emit was
        correctly ignored (i.e. there is exactly one result, not a tree
        of grand-children)
  PROMPT

  skill(:paper_lookup) do
    description 'Look up a canonical academic paper by topic.'
    input :topic, String

    execute do |params|
      topic = params[:topic].to_s.downcase.strip
      data = {
        'state space models' => {
          title: 'Efficiently Modeling Long Sequences with Structured State Spaces',
          authors: ['Albert Gu', 'Karan Goel', 'Christopher Ré'],
          venue: 'ICLR 2022',
          arxiv: '2111.00396'
        }
      }
      JSON.generate(data[topic] || { error: "No paper indexed for #{topic}" })
    end
  end

  input 'Research state space models for me.'
  max_steps 10
end
