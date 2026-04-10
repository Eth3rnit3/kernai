# frozen_string_literal: true

require 'json'

module ScenarioHelpers
  # --- Skills ---

  def setup_calculator_skill
    Kernai::Skill.define(:calculator) do
      description 'Evaluate a mathematical expression and return the numeric result'
      input :expression, String

      execute do |params|
        expr = params[:expression].strip
        # Normalize natural language operators to Ruby syntax
        expr = expr.gsub(/\bdivided by\b/i, '/')
        expr = expr.gsub(/\btimes\b/i, '*')
        expr = expr.gsub(/\bplus\b/i, '+')
        expr = expr.gsub(/\bminus\b/i, '-')
        expr = expr.gsub(/\bmodulo\b/i, '%')
        # Controlled test context only — the calculator skill helper
        # receives strings the test wrote itself, never user input.
        result = eval(expr) # rubocop:disable Security/Eval
        result.to_s
      rescue StandardError => e
        "Error: #{e.message}"
      end
    end
  end

  def setup_inventory_skill
    Kernai::Skill.define(:inventory) do
      description 'Look up product inventory. Returns JSON with product details and stock info'
      input :query, String

      execute do |_params|
        products = [
          { sku: 'WDG-401', name: 'Titanium Widget', price: 34.99, stock: 142, warehouse: 'EU-West' },
          { sku: 'WDG-402', name: 'Carbon Widget', price: 27.50, stock: 0, warehouse: 'EU-West' },
          { sku: 'SPR-801', name: 'Quantum Sprocket', price: 89.95, stock: 37, warehouse: 'US-East' },
          { sku: 'SPR-802', name: 'Nano Sprocket', price: 62.00, stock: 215, warehouse: 'US-East' },
          { sku: 'GZM-101', name: 'Flux Gizmo', price: 149.99, stock: 8, warehouse: 'AP-South' }
        ]
        JSON.generate(products)
      end
    end
  end

  def setup_weather_skill
    Kernai::Skill.define(:weather) do
      description 'Get current weather for a given city. Returns JSON with temp (celsius), condition, humidity'
      input :city, String

      execute do |params|
        data = {
          'Paris' => { temp: 18, condition: 'Partly cloudy', wind: '12 km/h', humidity: 65 },
          'London' => { temp: 11, condition: 'Rainy', wind: '25 km/h', humidity: 88 },
          'Tokyo' => { temp: 26, condition: 'Sunny', wind: '5 km/h', humidity: 40 },
          'New York' => { temp: 22, condition: 'Clear', wind: '8 km/h', humidity: 55 }
        }
        city = params[:city].strip
        found = data.find { |k, _| k.downcase == city.downcase }
        if found
          JSON.generate(found[1])
        else
          JSON.generate({ error: "City '#{city}' not found. Available: #{data.keys.join(', ')}" })
        end
      end
    end
  end

  def setup_user_database_skill
    Kernai::Skill.define(:user_database) do
      description 'Query the user database. Returns a JSON array of user records'
      input :query, String

      execute do |_params|
        users = [
          { id: 1, name: 'Alice Martin', email: 'alice@example.com', status: 'active', plan: 'premium',
            signup_date: '2024-01-15' },
          { id: 2, name: 'Bob Smith', email: 'bob@example.com', status: 'active', plan: 'free',
            signup_date: '2024-03-22' },
          { id: 3, name: 'Charlie Brown', email: 'charlie@example.com', status: 'inactive', plan: 'premium',
            signup_date: '2023-11-08' },
          { id: 4, name: 'Diana Prince', email: 'diana@example.com', status: 'active', plan: 'premium',
            signup_date: '2024-06-01' },
          { id: 5, name: 'Eve Wilson', email: 'eve@example.com', status: 'active', plan: 'free',
            signup_date: '2024-07-19' },
          { id: 6, name: 'Frank Lee', email: 'frank@example.com', status: 'inactive', plan: 'free',
            signup_date: '2023-09-30' }
        ]
        JSON.generate(users)
      end
    end
  end

  # --- Instruction templates ---

  BLOCK_PROTOCOL = <<~BLOCK
    You MUST respond ONLY using XML blocks with this EXACT syntax:
    <block type="TYPE">content</block>

    CRITICAL: The tag name is always "block" with a type attribute. Never use shorthand like <final> or <command>.

    Available block types:
    - command: execute a skill. Requires a name attribute: <block type="command" name="SKILL">params</block>
    - final: your final answer: <block type="final">Your answer here</block>
    - plan: optional reasoning: <block type="plan">Your thinking</block>

    After receiving a skill result, analyze it and either use another skill or provide your final answer.
  BLOCK

  CALCULATOR_INSTRUCTIONS = <<~PROMPT.freeze
    You are a math assistant. You MUST use the calculator skill for ALL computations, no matter how simple.
    You are FORBIDDEN from computing any math yourself. Even 1+1 must go through the calculator skill.
    If you return a number without having used the calculator skill first, it is an error.

    #{BLOCK_PROTOCOL}
    Available skills:
    - calculator: Evaluate a math expression. Usage: <block type="command" name="calculator">EXPRESSION</block>
      Example: <block type="command" name="calculator">15 * 7 + 23</block>
  PROMPT

  INVENTORY_INSTRUCTIONS = <<~PROMPT.freeze
    You are a warehouse inventory assistant. You have NO knowledge of the product catalog.
    You MUST use the inventory skill to look up any product information.
    Never guess or assume product details — always query first.

    #{BLOCK_PROTOCOL}
    Available skills:
    - inventory: Look up products. Usage: <block type="command" name="inventory">search query</block>
      Returns a JSON array of products with fields: sku, name, price, stock, warehouse
  PROMPT

  WEATHER_ADVISOR_INSTRUCTIONS = <<~PROMPT.freeze
    You are a helpful travel advisor. You must check the weather before making any outdoor activity recommendation.
    Always use the weather skill to get real data — never guess or assume weather conditions.

    #{BLOCK_PROTOCOL}
    Available skills:
    - weather: Get weather for a city. Usage: <block type="command" name="weather">CITY_NAME</block>
      Example: <block type="command" name="weather">Paris</block>
      Returns JSON: {"temp": 18, "condition": "Partly cloudy", "wind": "12 km/h", "humidity": 65}
  PROMPT

  DATA_ANALYST_INSTRUCTIONS = <<~PROMPT.freeze
    You are a data analyst assistant. You have access to a user database and a calculator.
    You have NO knowledge of what users exist in the database. You MUST query the database to get any user data.
    You MUST use the calculator for ALL arithmetic — never compute numbers yourself.

    Your workflow for ANY data question:
    1. FIRST: query the database with user_database skill
    2. THEN: use calculator skill for any math (counts, percentages, averages)
    3. FINALLY: provide your answer in a final block

    #{BLOCK_PROTOCOL}
    Available skills:
    - user_database: Fetch all users. Usage: <block type="command" name="user_database">fetch all</block>
      Returns a JSON array of users with fields: id, name, email, status (active/inactive), plan (free/premium), signup_date
    - calculator: Math computation. Usage: <block type="command" name="calculator">EXPRESSION</block>
      Use arithmetic operators: +, -, *, /. Example: <block type="command" name="calculator">2.0 / 4</block>
      Returns the numeric result as a string
  PROMPT
end
