# frozen_string_literal: true

# Scenario Harness for Kernai
#
# Convention:
#   - Each scenario is a standalone .rb file in scenarios/
#   - A scenario defines deterministic skills, a system prompt, and a user input
#   - The harness runs it, records everything, and dumps a readable report
#   - Nothing here is tracked by git — this is your experimentation sandbox
#
# Usage:
#   ruby scenarios/my_scenario.rb                        # default model
#   ruby scenarios/my_scenario.rb gemma3:27b             # override model
#   ruby scenarios/my_scenario.rb gemma3:27b ollama      # override model + provider
#   PROVIDER=ollama MODEL=gemma3:27b ruby scenarios/my_scenario.rb
#
# Providers: "ollama" (default), "openai", "anthropic"
#
# Output:
#   - Colored report to stdout
#   - Full JSON recording saved to scenarios/logs/<name>_<model>_<timestamp>.json
#
# To turn a finding into a test:
#   1. Copy the recorder JSON into a test fixture
#   2. Use Mock::Provider.respond_with() with the raw_response from each step
#   3. Assert the behavior you want to validate

require 'bundler/setup'
require 'dotenv/load'
require 'kernai'
require 'json'
require 'fileutils'

# Load example providers
require_relative '../examples/providers/ollama_provider'
require_relative '../examples/providers/openai_provider'
require_relative '../examples/providers/anthropic_provider'

module Scenarios
  class Harness
    PROVIDERS = {
      'ollama' => -> { Kernai::Examples::OllamaProvider.new },
      'openai' => -> { Kernai::Examples::OpenaiProvider.new },
      'anthropic' => -> { Kernai::Examples::AnthropicProvider.new }
    }.freeze

    DEFAULT_PROVIDER = 'ollama'
    DEFAULT_MODELS = {
      'ollama' => 'gemma3:27b',
      'openai' => 'gpt-4.1',
      'anthropic' => 'claude-sonnet-4-20250514'
    }.freeze

    attr_reader :recorder, :result, :events

    def initialize(name:, description: nil)
      @name = name
      @description = description
      @skills = []
      @instructions = nil
      @input = nil
      @max_steps = 10
    end

    def instructions(text = nil, &block)
      @instructions = block || text
    end

    def skill(name, &block)
      @skills << { name: name, block: block }
    end

    def input(text)
      @input = text
    end

    def max_steps(n)
      @max_steps = n
    end

    def run!
      provider_name = ENV['PROVIDER'] || ARGV[1] || DEFAULT_PROVIDER
      model = ENV['MODEL'] || ARGV[0] || DEFAULT_MODELS[provider_name]

      abort "Unknown provider: #{provider_name}" unless PROVIDERS.key?(provider_name)

      Kernai.reset!
      Kernai.config.debug = true

      # Silence default logger — we'll print our own report
      Kernai.config.logger = Kernai::Logger.new(File.open(File::NULL, 'w'))

      # Register skills
      @skills.each do |s|
        Kernai::Skill.define(s[:name], &s[:block])
      end

      provider = PROVIDERS[provider_name].call
      @recorder = Kernai::Recorder.new
      @events = []

      skill_names = @skills.map { |s| s[:name] }

      agent = Kernai::Agent.new(
        instructions: @instructions,
        provider: provider,
        model: model,
        max_steps: @max_steps,
        skills: skill_names.any? ? skill_names : nil
      )

      header(provider_name, model)

      @failure = nil

      begin
        @result = Kernai::Kernel.run(agent, @input, recorder: @recorder) do |event|
          @events << event
          print_event_live(event)
        end
      rescue Kernai::MaxStepsReachedError => e
        @result = nil
        @failure = { type: 'max_steps_reached', message: e.message }
        @recorder.record(step: -1, event: :error, data: @failure)
        print_error("MaxStepsReached: #{e.message}")
      rescue Kernai::ProviderError => e
        @result = nil
        @failure = { type: 'provider_error', message: e.message }
        @recorder.record(step: -1, event: :error, data: @failure)
        print_error("ProviderError: #{e.message}")
      end

      report(provider_name, model)
      save_log(provider_name, model)
    end

    private

    # --- Output ---

    def header(provider_name, model)
      puts
      puts "\e[1;36m#{'=' * 70}\e[0m"
      puts "\e[1;36m  SCENARIO: #{@name}\e[0m"
      puts "\e[36m  #{@description}\e[0m" if @description
      puts "\e[36m  Provider: #{provider_name} | Model: #{model}\e[0m"
      puts "\e[36m  Input: #{@input}\e[0m"
      puts "\e[1;36m#{'=' * 70}\e[0m"
      puts
    end

    def print_event_live(event)
      case event.type
      when :block_start
        type = event.data[:type]
        name = event.data[:name]
        label = name ? "#{type}:#{name}" : type.to_s
        print "\e[33m  [#{label}]\e[0m "
      when :text_chunk
        print "\e[2m#{event.data}\e[0m"
      when :block_content
        print event.data
      when :skill_result
        puts
        puts "\e[32m  => #{event.data[:skill]}: #{truncate(event.data[:result], 200)}\e[0m"
      when :skill_error
        puts
        puts "\e[31m  !! #{event.data[:skill]}: #{event.data[:error]}\e[0m"
      when :builtin_result
        puts
        puts "\e[36m  => #{event.data[:command]}: #{truncate(event.data[:result], 200)}\e[0m"
      when :final
        puts
      when :plan
        puts
      end
    end

    def print_error(msg)
      puts "\e[1;31m  ERROR: #{msg}\e[0m"
    end

    def report(_provider_name, _model)
      puts
      puts "\e[1;35m#{'─' * 70}\e[0m"
      puts "\e[1;35m  REPORT\e[0m"
      puts "\e[1;35m#{'─' * 70}\e[0m"

      steps = @recorder.steps
      puts "  Steps: #{steps.size}"

      steps.each do |step|
        entries = @recorder.for_step(step)
        entries.map { |e| e[:event] }

        messages_sent = entries.find { |e| e[:event] == :messages_sent }
        msg_count = messages_sent ? messages_sent[:data].size : 0
        raw = entries.find { |e| e[:event] == :raw_response }
        blocks = entries.find { |e| e[:event] == :blocks_parsed }
        block_types = blocks ? blocks[:data].map { |b| b[:type] } : []

        puts
        puts "  \e[1mStep #{step}\e[0m"
        puts "    Messages sent: #{msg_count}"
        puts "    Blocks parsed: #{block_types.join(', ')}"

        # Show plan blocks
        entries.select { |e| e[:event] == :plan }.each do |e|
          puts "    \e[2mPlan: #{truncate(e[:data], 120)}\e[0m"
        end

        # Show builtin commands
        entries.select { |e| e[:event] == :builtin_result }.each do |e|
          puts "    \e[36mBuiltin: #{e[:data][:command]} => #{truncate(e[:data][:result].to_s, 120)}\e[0m"
        end
        entries.select { |e| e[:event] == :builtin_error }.each do |e|
          puts "    \e[31mBuiltin error: #{e[:data][:command]} (#{e[:data][:error]})\e[0m"
        end

        # Show skill calls
        entries.select { |e| e[:event] == :skill_execute }.each do |e|
          puts "    \e[33mSkill call: #{e[:data][:skill]}(#{format_params(e[:data][:params])})\e[0m"
        end
        entries.select { |e| e[:event] == :skill_result }.each do |e|
          puts "    \e[32mSkill result: #{truncate(e[:data][:result].to_s, 120)}\e[0m"
        end
        entries.select { |e| e[:event] == :skill_error }.each do |e|
          puts "    \e[31mSkill error: #{e[:data][:error]}\e[0m"
        end

        # Show JSON blocks
        entries.select { |e| e[:event] == :json }.each do |e|
          puts "    \e[35mJSON: #{truncate(e[:data], 120)}\e[0m"
        end

        # Show raw response (truncated)
        puts "    Raw response: #{truncate(raw[:data], 200)}" if raw
      end

      puts
      if @result
        puts "  \e[1;32mResult: #{truncate(@result, 500)}\e[0m"
      else
        puts "  \e[1;31mNo result (max steps reached or error)\e[0m"
      end

      puts "\e[1;35m#{'─' * 70}\e[0m"
    end

    def save_log(provider_name, model)
      slug = model.gsub(/[^a-zA-Z0-9._-]/, '_')
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      filename = "#{@name}_#{slug}_#{timestamp}.json"
      logs_dir = File.join(__dir__, 'logs')
      path = File.join(logs_dir, filename)

      log = {
        scenario: @name,
        description: @description,
        provider: provider_name,
        model: model,
        input: @input,
        max_steps: @max_steps,
        skills: @skills.map { |s| s[:name].to_s },
        result: @result,
        ok: !@result.nil?,
        failure: @failure,
        steps: root_steps_count,
        started_at: @recorder.entries.first&.dig(:timestamp),
        finished_at: @recorder.entries.last&.dig(:timestamp),
        recording: @recorder.to_a
      }

      FileUtils.mkdir_p(logs_dir)
      File.write(path, JSON.pretty_generate(log))
      update_manifest(logs_dir, filename, log)
      puts "  \e[2mLog saved: #{path}\e[0m"
      puts
    end

    # Root-only step count — recorder entries from sub-agents reset their
    # own `step` counters, so the overall "steps used" number should only
    # count depth-0 entries to stay comparable across runs.
    def root_steps_count
      root_entries = @recorder.entries.select { |e| e[:depth].to_i.zero? }
      root_entries.map { |e| e[:step] }.reject { |s| s.nil? || s.negative? }.uniq.size
    end

    # Append-only index of every run in `scenarios/logs/manifest.json`.
    # The observer UI can read this single file instead of globbing and
    # parsing every log just to list available runs.
    def update_manifest(logs_dir, filename, log)
      manifest_path = File.join(logs_dir, 'manifest.json')
      manifest = File.exist?(manifest_path) ? safe_load_manifest(manifest_path) : []

      entry = {
        file: filename,
        scenario: log[:scenario],
        description: log[:description],
        provider: log[:provider],
        model: log[:model],
        ok: log[:ok],
        steps: log[:steps],
        max_steps: log[:max_steps],
        started_at: log[:started_at],
        finished_at: log[:finished_at]
      }

      manifest << entry
      File.write(manifest_path, JSON.pretty_generate(manifest))
    end

    def safe_load_manifest(path)
      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    # --- Helpers ---

    def truncate(str, max)
      str = str.to_s
      str.length > max ? "#{str[0...max]}..." : str
    end

    def format_params(params)
      return '' unless params

      params.map { |k, v| "#{k}: #{truncate(v.to_s, 50)}" }.join(', ')
    end
  end

  def self.define(name, description: nil, &block)
    harness = Harness.new(name: name, description: description)
    harness.instance_eval(&block)
    harness.run!
    harness
  end
end
