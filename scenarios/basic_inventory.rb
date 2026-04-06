# frozen_string_literal: true

# Example scenario: inventory lookup
#
#   ruby scenarios/basic_inventory.rb                    # default (ollama gemma3:27b)
#   ruby scenarios/basic_inventory.rb gemma4:31b         # different model
#   ruby scenarios/basic_inventory.rb gpt-4.1 openai     # OpenAI
#   PROVIDER=anthropic MODEL=claude-sonnet-4-20250514 ruby scenarios/basic_inventory.rb

require_relative 'harness'

Scenarios.define('inventory_lookup', description: 'LLM must query inventory skill to find out-of-stock products') do
  instructions <<~PROMPT
    You are a warehouse inventory assistant. You have NO knowledge of the product catalog.
    You MUST use the inventory skill to look up any product information.
    Never guess or assume product details — always query first.

    You MUST respond using XML blocks:
    <block type="plan">your reasoning</block>
    <block type="command" name="inventory">search query</block>
    <block type="final">your answer</block>

    Available skills:
    - inventory: Look up products. Usage: <block type="command" name="inventory">search query</block>
      Returns a JSON array of products with fields: sku, name, price, stock
  PROMPT

  skill(:inventory) do
    description 'Look up product inventory. Returns JSON with product details and stock info'
    input :query, String

    execute do |_params|
      products = [
        { sku: 'WDG-401', name: 'Titanium Widget', price: 34.99, stock: 142 },
        { sku: 'WDG-402', name: 'Carbon Widget', price: 27.50, stock: 0 },
        { sku: 'SPR-801', name: 'Quantum Sprocket', price: 89.95, stock: 37 },
        { sku: 'GZM-101', name: 'Flux Gizmo', price: 149.99, stock: 8 }
      ]
      JSON.generate(products)
    end
  end

  input 'Which products are out of stock?'
  max_steps 5
end
