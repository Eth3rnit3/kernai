# frozen_string_literal: true

# Scenario: Customer support triage
#
# The agent must discover skills via /skills, then chain multiple lookups
# to triage a customer complaint. Tests:
#   - /skills discovery (no skills injected in instructions)
#   - Multi-step skill chaining (customer -> orders -> known issues)
#   - Reasoning across results to produce a coherent answer
#   - Handling of JSON data from multiple sources
#
#   ruby scenarios/customer_support_triage.rb                       # default
#   ruby scenarios/customer_support_triage.rb gemma3:27b            # specific model
#   ruby scenarios/customer_support_triage.rb gpt-4.1 openai        # OpenAI

require_relative 'harness'

Scenarios.define(
  'customer_support_triage',
  description: 'Agent must discover skills, then chain customer + orders + known_issues to triage a complaint'
) do
  instructions <<~PROMPT
    You are a customer support triage agent. Your job is to investigate customer
    complaints by gathering all relevant information before responding.

    You have access to tools but you don't know which ones yet.
    Start by discovering available skills, then use them to investigate.

    Rules:
    - ALWAYS gather customer info AND order history before responding
    - Check for known issues that might explain the problem
    - Include the customer's name and plan in your response
    - If a known issue matches, mention it explicitly
    - Be concise and factual

    Example interaction flow:

    User: Customer #7 says they can't log in
    Assistant: <block type="command" name="/skills"></block>
    System: <block type="result" name="/skills">- customer_lookup: ...</block>
    Assistant: <block type="command" name="customer_lookup">7</block>
    System: <block type="result" name="customer_lookup">{"name": "Alice", ...}</block>
    Assistant: <block type="final">Alice (premium plan) is experiencing login issues. ...</block>
  PROMPT

  skill(:customer_lookup) do
    description 'Look up customer information by ID. Returns JSON with name, email, plan, and signup date'
    input :customer_id, String

    execute do |params|
      customers = {
        '42' => { id: 42, name: 'Marie Dupont', email: 'marie@example.com', plan: 'premium',
                  since: '2024-03-15', lifetime_orders: 23 },
        '99' => { id: 99, name: 'Jean Martin', email: 'jean@example.com', plan: 'free',
                  since: '2025-01-08', lifetime_orders: 2 }
      }
      id = params[:customer_id].to_s.gsub(/[^0-9]/, '')
      found = customers[id]
      JSON.generate(found || { error: "Customer ##{id} not found" })
    end
  end

  skill(:order_history) do
    description 'Fetch recent orders for a customer. Returns JSON array of orders with status'
    input :customer_id, String

    execute do |params|
      orders = {
        '42' => [
          { order_id: 'ORD-1081', date: '2025-03-28', items: ['Widget Pro x2'], total: 89.98,
            status: 'delivered', tracking: 'TR-9981' },
          { order_id: 'ORD-1094', date: '2025-04-01', items: ['Mega Pack'], total: 149.99,
            status: 'shipped', tracking: 'TR-10042' },
          { order_id: 'ORD-1102', date: '2025-04-04', items: ['Widget Pro x1', 'Adapter Cable'], total: 67.49,
            status: 'processing', tracking: nil }
        ],
        '99' => [
          { order_id: 'ORD-1055', date: '2025-03-10', items: ['Starter Kit'], total: 29.99,
            status: 'delivered', tracking: 'TR-8877' }
        ]
      }
      id = params[:customer_id].to_s.gsub(/[^0-9]/, '')
      found = orders[id]
      JSON.generate(found || [])
    end
  end

  skill(:known_issues) do
    description 'Check current known issues and service disruptions. No input required'
    input :query, String, default: 'all'

    execute do |_params|
      issues = [
        { id: 'INC-2041', severity: 'high', title: 'Shipping delays in EU-West region',
          affected: 'Orders shipped via TR-100xx tracking numbers',
          status: 'investigating', since: '2025-04-02',
          details: 'Carrier partner reporting 3-5 day delays for EU-West warehouse shipments' },
        { id: 'INC-2039', severity: 'low', title: 'Email notifications delayed',
          affected: 'All customers', status: 'resolved', since: '2025-03-30',
          details: 'Email queue backlog cleared, notifications now sending normally' }
      ]
      JSON.generate(issues)
    end
  end

  input "Customer #42 reports their latest order hasn't arrived yet. They're asking for a refund."
  max_steps 8
end
