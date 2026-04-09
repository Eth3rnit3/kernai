# frozen_string_literal: true

# Scenario: MCP memory store & recall (🟡)
#
# Tests stateful, multi-call MCP usage against the official knowledge-graph
# memory server (@modelcontextprotocol/server-memory). The agent must:
#   1. Create entities in the knowledge graph (tools/call create_entities)
#   2. Link them with relations (tools/call create_relations)
#   3. Query the graph back (tools/call search_nodes or read_graph)
#   4. Answer a question that can only be solved by reading what it just stored
#
# This stresses:
#   - Multi-step tool selection against a non-trivial tool catalog
#   - State persistence across MCP calls inside the same session
#   - Schema-driven argument construction (entities and relations are structured)
#
# Failure modes:
#   - Agent tries to answer from the prompt alone without storing anything
#   - Agent forgets to read back and hallucinates the relations
#   - Agent picks a tool whose schema it didn't inspect first and sends malformed args
#
# Prerequisites:
#   - `gem install mcp_client`
#   - Node.js + npx
#
# Usage:
#   ruby scenarios/mcp_memory_store_recall.rb

require_relative 'harness'

Scenarios.define(
  'mcp_memory_store_recall',
  description: 'Stateful knowledge-graph round trip against the MCP memory server'
) do
  mcp_config(
    'servers' => {
      'memory' => {
        'transport' => 'stdio',
        'command' => 'npx',
        'args' => ['-y', '@modelcontextprotocol/server-memory']
      }
    }
  )

  protocols [:mcp]

  instructions <<~PROMPT
    You are an agent with access to an external knowledge-graph memory system
    through an MCP protocol. Your job is to persist a set of facts into that
    system, then read them back from the SAME system to answer a question.

    Facts to persist (these are the only facts you know — put them into the
    memory system verbatim and structured):
      - Alice is a Person. She works at Acme Corp.
      - Bob is a Person. He works at Acme Corp.
      - Acme Corp is an Organization headquartered in Paris.
      - Carol is the CTO of Acme Corp. Both Alice and Bob report to Carol.

    Question to answer at the end:
      Who does Alice report to, in which city is Alice's employer based, and
      who else reports to the same person as Alice?

    Evaluation rules:
      - You MUST read the data back from the memory system before answering.
        Answering directly from the prompt text defeats the exercise and
        counts as a failure.
      - Every fact in your final answer must be traceable to an actual tool
        result you observed, not to the prompt.
      - The memory system is the only source of truth for your answer.
  PROMPT

  input 'Persist the facts I gave you into the memory system, then read them ' \
        'back from there and answer the question.'
  max_steps 15
end
