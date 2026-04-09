#!/usr/bin/env ruby
# frozen_string_literal: true

# Matrix runner for Kernai scenarios.
#
# Runs every scenario resolved from SCENARIOS_SPEC against every
# (provider, model) pair in MATRIX, then prints a colored summary table
# and writes a machine-readable summary JSON under scenarios/logs/.
#
# Each scenario runs as an isolated subprocess so a failure on one row does
# not contaminate the next, and each still produces its own per-run log
# under scenarios/logs/<scenario>_<model>_<timestamp>.json (the per-scenario
# log is where you go when you want to drill into what actually happened).
#
# Usage:
#   bundle exec ruby scenarios/run_matrix.rb
#
# Edit the MATRIX and SCENARIOS_SPEC constants below to pick what you want to run.
# Environment variables like OPENAI_API_KEY / OLLAMA_API_KEY / etc. must be
# set (the harness loads them from .env automatically).

require 'json'
require 'open3'
require 'fileutils'
require 'time'

# --- EDIT ME: (provider, model) pairs to run ------------------------------
MATRIX = [
  { provider: 'openai',    model: 'gpt-4.1' },
  { provider: 'anthropic', model: 'claude-sonnet-4-20250514' },
  { provider: 'ollama',    model: 'gemma4:31b-cloud' }
  # { provider: 'ollama',    model: 'gemma3:27b' },
  # { provider: 'ollama',    model: 'qwen3-coder-next' },
].freeze

# --- EDIT ME: scenario files to run ---------------------------------------
# Use :all to auto-discover every scenario under scenarios/ (recommended),
# or pass an explicit whitelist of basenames (without .rb) to restrict the
# runner to a subset.
#
#   SCENARIOS = :all
#   SCENARIOS = %w[mcp_filesystem_exploration simple_baseline]
SCENARIOS_SPEC = :all
# --------------------------------------------------------------------------

ROOT = File.expand_path('..', __dir__)
SCENARIOS_DIR = __dir__
LOGS_DIR = File.join(SCENARIOS_DIR, 'logs')

# Files in scenarios/ that are NOT themselves scenarios and must be
# excluded from auto-discovery.
NON_SCENARIO_FILES = %w[
  harness
  run_matrix
].freeze

# When SCENARIOS is :all, auto-discover every *.rb under scenarios/ minus
# the known non-scenario files. Otherwise the constant is treated as an
# explicit whitelist (basename, no extension).
def resolve_scenarios(spec)
  return spec unless spec == :all

  Dir.glob(File.join(SCENARIOS_DIR, '*.rb'))
     .map { |f| File.basename(f, '.rb') }
     .reject { |name| NON_SCENARIO_FILES.include?(name) }
     .sort
end

Result = Struct.new(
  :scenario, :provider, :model, :status, :duration_s,
  :log_path, :summary, :steps, keyword_init: true
) do
  STATUS_STYLE = {
    ok:      ["\e[32m", 'OK'],
    fail:    ["\e[31m", 'FAIL'],
    skipped: ["\e[33m", 'SKIP'],
    error:   ["\e[35m", 'ERR']
  }.freeze

  def color; STATUS_STYLE.fetch(status).first; end
  def label; STATUS_STYLE.fetch(status).last;  end
  def reset; "\e[0m"; end

  def to_h
    {
      scenario: scenario, provider: provider, model: model,
      status: status.to_s, duration_s: duration_s, steps: steps,
      log_path: log_path, summary: summary
    }
  end
end

def run_one(scenario, provider, model)
  path = File.join(SCENARIOS_DIR, "#{scenario}.rb")
  unless File.exist?(path)
    return Result.new(scenario: scenario, provider: provider, model: model,
                      status: :error, duration_s: 0.0, log_path: nil,
                      summary: "scenario file not found: #{path}", steps: nil)
  end

  # Env vars take priority over ARGV in the harness AND over values loaded
  # from .env (dotenv does not overwrite pre-set variables). Pass both to
  # be unambiguous.
  env = { 'PROVIDER' => provider, 'MODEL' => model }
  cmd = ['bundle', 'exec', 'ruby', path, model, provider]

  started = Time.now
  stdout, stderr, status = Open3.capture3(env, *cmd, chdir: ROOT)
  duration = (Time.now - started).round(2)

  log_path = extract_log_path(stdout)
  interpretation = interpret(stdout, status, log_path)

  Result.new(
    scenario: scenario, provider: provider, model: model,
    status: interpretation[:status], duration_s: duration,
    log_path: log_path, summary: interpretation[:summary],
    steps: interpretation[:steps]
  ).tap do |res|
    # Stash stderr tail on hard errors so the user can see what blew up
    # without having to open the per-run log.
    if res.status == :error && !stderr.strip.empty?
      res.summary = "#{res.summary} | stderr: #{stderr.lines.last(3).join.strip[0..200]}"
    end
  end
end

def extract_log_path(stdout)
  m = stdout.match(/Log saved:\s+(\S+\.json)/)
  m && m[1]
end

# Returns a hash {status:, summary:, steps:}
def interpret(stdout, process_status, log_path)
  if stdout.include?('SKIPPED:')
    reason = stdout[/SKIPPED:\s*(.+)$/, 1].to_s.strip
    return { status: :skipped, summary: reason[0..140], steps: nil }
  end

  unless process_status.success?
    return {
      status: :error,
      summary: "exit=#{process_status.exitstatus || 'signal'}",
      steps: nil
    }
  end

  unless log_path && File.exist?(log_path)
    return { status: :error, summary: 'no log produced', steps: nil }
  end

  data = JSON.parse(File.read(log_path))
  steps = data['steps']

  if data['ok']
    result = data['result'].to_s.lines.first.to_s.strip
    { status: :ok, summary: result[0..120], steps: steps }
  else
    failure = data['failure'] || {}
    msg = "#{failure['type']}: #{failure['message']}".strip.gsub(/\s+/, ' ')
    { status: :fail, summary: msg[0..120], steps: steps }
  end
rescue StandardError => e
  { status: :error, summary: "interpret error: #{e.message}"[0..140], steps: nil }
end

def print_header(scenarios)
  puts
  puts "\e[1;36m#{'=' * 110}\e[0m"
  puts "\e[1;36m  Kernai scenario matrix\e[0m"
  puts "\e[36m  #{scenarios.size} scenarios × #{MATRIX.size} (provider, model) pairs = #{scenarios.size * MATRIX.size} runs\e[0m"
  puts "\e[36m  Scenarios: #{scenarios.join(', ')}\e[0m"
  puts "\e[1;36m#{'=' * 110}\e[0m"
end

def print_row_header(provider, model, index, total)
  puts
  puts "\e[1;34m── [#{index}/#{total}] provider=#{provider}  model=#{model} ──\e[0m"
end

def print_result(result)
  puts format(
    '  %s%-5s%s  %-38s  %6.1fs  steps=%-3s %s',
    result.color, result.label, result.reset,
    result.scenario, result.duration_s,
    (result.steps || '-').to_s,
    result.summary.to_s
  )
end

def print_matrix(results, scenarios)
  puts
  puts "\e[1;35m#{'=' * 110}\e[0m"
  puts "\e[1;35m  MATRIX SUMMARY\e[0m"
  puts "\e[1;35m#{'=' * 110}\e[0m"

  models = MATRIX.map { |row| "#{row[:provider]}:#{row[:model]}" }
  col_width = ([models.map(&:length).max || 0, 14].max) + 2
  scenario_col = scenarios.map(&:length).max + 2

  header = format("  %-#{scenario_col}s", 'Scenario')
  models.each { |m| header += format("%-#{col_width}s", m) }
  puts "\e[1m#{header}\e[0m"

  scenarios.each do |scenario|
    row = format("  %-#{scenario_col}s", scenario)
    MATRIX.each do |m|
      res = results.find { |r| r.scenario == scenario && r.provider == m[:provider] && r.model == m[:model] }
      cell = if res
               "#{res.label} #{res.duration_s}s"
             else
               '-'
             end
      color = res ? res.color : ''
      reset = res ? res.reset : ''
      row += format("%s%-#{col_width}s%s", color, cell, reset)
    end
    puts row
  end

  puts
  tally = results.group_by(&:status).transform_values(&:size)
  parts = Result::STATUS_STYLE.map do |status, (color, label)|
    count = tally[status] || 0
    "#{color}#{label}: #{count}\e[0m"
  end
  puts "  Totals: #{parts.join('   ')}"
end

def save_summary(results, scenarios)
  FileUtils.mkdir_p(LOGS_DIR)
  path = File.join(LOGS_DIR, "matrix_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
  File.write(path, JSON.pretty_generate(
    started_at: Time.now.iso8601,
    matrix: MATRIX,
    scenarios: scenarios,
    results: results.map(&:to_h)
  ))
  puts "\e[2m  Matrix summary saved: #{path}\e[0m"
  puts
end

def main
  scenarios = resolve_scenarios(SCENARIOS_SPEC)
  if scenarios.empty?
    warn 'No scenarios to run (check SCENARIOS_SPEC and NON_SCENARIO_FILES).'
    exit 2
  end

  print_header(scenarios)

  results = []
  MATRIX.each_with_index do |row, i|
    provider = row[:provider]
    model    = row[:model]
    print_row_header(provider, model, i + 1, MATRIX.size)

    scenarios.each do |scenario|
      result = run_one(scenario, provider, model)
      print_result(result)
      results << result
    end
  end

  print_matrix(results, scenarios)
  save_summary(results, scenarios)

  # Non-zero exit if any run did not succeed. Skipped runs are NOT a
  # failure (the harness skip is intentional — missing optional dep etc.).
  failed = results.any? { |r| %i[fail error].include?(r.status) }
  exit(failed ? 1 : 0)
end

main if $PROGRAM_NAME == __FILE__
