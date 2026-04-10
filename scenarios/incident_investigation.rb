# frozen_string_literal: true

# Scenario: DevOps incident investigation
#
# The agent is an on-call SRE responding to a production alert.
# Must discover skills, chain 5+ lookups, cross-reference data from
# multiple sources to identify root cause.
#
# Expected investigation path:
#   /skills → alert_details → metrics → deployments → dependencies → logs
#   Then cross-reference: deploy at 14:28 changed auth-service port to TLS,
#   but auth-service doesn't support TLS yet → connection refused errors.
#
# Tests:
#   - /skills discovery
#   - 5+ skill calls in sequence
#   - Cross-referencing data across multiple skill results
#   - Identifying root cause from correlated evidence
#   - Structured incident summary
#
#   ruby scenarios/incident_investigation.rb
#   ruby scenarios/incident_investigation.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'incident_investigation',
  description: 'SRE investigates a production alert — must chain 5+ skills and cross-reference to find root cause'
) do
  instructions <<~PROMPT
    You are an on-call SRE investigating a production incident.
    Your job is to gather evidence from multiple sources, cross-reference
    the data, identify the root cause, and provide a structured incident summary.

    Your investigation should follow this approach:
    1. Get alert details to understand the scope
    2. Check metrics to see the impact timeline
    3. Check recent deployments for correlation
    4. Check service dependencies health
    5. Query logs for error patterns
    6. Cross-reference all findings to identify root cause

    Rules:
    - Use ALL available skills before concluding
    - Correlate timestamps across sources (deploys, metrics spikes, alerts)
    - Your final answer MUST include: severity, affected service, root cause,
      evidence trail, and recommended action
    - Be precise with timestamps and versions

    Example interaction flow:

    User: Alert firing on payments-service
    Assistant: <block type="command" name="/skills"></block>
    System: <block type="result" name="/skills">- alert_details: ...</block>
    Assistant: <block type="command" name="alert_details">payments-service</block>
    System: <block type="result" name="alert_details">{"service": "payments-service", ...}</block>
    Assistant: <block type="command" name="metrics">payments-service</block>
    ...
    Assistant: <block type="final">**Incident Summary** ...</block>
  PROMPT

  skill(:alert_details) do
    description 'Get details of a firing alert. Returns JSON with service, severity, message, and timestamps'
    input :alert_id, String

    execute do |_params|
      JSON.generate(
        alert_id: 'ALT-7842',
        service: 'api-gateway',
        severity: 'critical',
        message: 'Error rate exceeds 10% threshold on api-gateway',
        fired_at: '2025-04-06T14:32:00Z',
        region: 'eu-west-1',
        dashboard: 'https://grafana.internal/d/api-gateway-errors'
      )
    end
  end

  skill(:metrics) do
    description 'Query service metrics (error rate, latency, throughput). Returns JSON time series'
    input :service, String

    execute do |params|
      service = params[:service].to_s.strip
      if service.include?('api-gateway')
        JSON.generate(
          service: 'api-gateway',
          period: '14:00-15:00 UTC',
          data: [
            { time: '14:00', error_rate: 0.1, p99_latency_ms: 45, rps: 1200 },
            { time: '14:10', error_rate: 0.1, p99_latency_ms: 42, rps: 1180 },
            { time: '14:20', error_rate: 0.2, p99_latency_ms: 48, rps: 1210 },
            { time: '14:28', error_rate: 0.3, p99_latency_ms: 52, rps: 1195 },
            { time: '14:30', error_rate: 8.5, p99_latency_ms: 2800, rps: 1190 },
            { time: '14:32', error_rate: 12.1, p99_latency_ms: 5200, rps: 980 },
            { time: '14:35', error_rate: 11.8, p99_latency_ms: 4900, rps: 850 },
            { time: '14:40', error_rate: 12.3, p99_latency_ms: 5100, rps: 820 }
          ]
        )
      else
        JSON.generate(service: service, error: 'No metrics found for this service')
      end
    end
  end

  skill(:deployments) do
    description 'List recent deployments across all services. ' \
                'Returns JSON array with service, version, timestamp, and author'
    input :timeframe, String, default: '24h'

    execute do |_params|
      JSON.generate([
                      { service: 'api-gateway', version: 'v2.4.1', deployed_at: '2025-04-06T14:28:00Z',
                        author: 'thomas.m', status: 'completed',
                        changelog: 'Migrate auth-service calls to TLS (port 8443). Update connection pool settings.' },
                      { service: 'user-service', version: 'v3.1.0', deployed_at: '2025-04-06T10:15:00Z',
                        author: 'sarah.k', status: 'completed',
                        changelog: 'Add user preferences endpoint. Update rate limiter config.' },
                      { service: 'billing-service', version: 'v1.8.2', deployed_at: '2025-04-05T22:30:00Z',
                        author: 'alex.p', status: 'completed',
                        changelog: 'Fix invoice rounding bug. Add retry logic for payment gateway timeouts.' }
                    ])
    end
  end

  skill(:dependencies) do
    description 'Check health status of a service and its dependencies. Returns JSON with health checks'
    input :service, String

    execute do |params|
      service = params[:service].to_s.strip
      if service.include?('api-gateway')
        JSON.generate(
          service: 'api-gateway',
          status: 'degraded',
          checked_at: '2025-04-06T14:41:00Z',
          dependencies: [
            { name: 'auth-service', endpoint: 'auth-service:8443', status: 'unreachable',
              error: 'connection refused', last_success: '2025-04-06T14:27:55Z' },
            { name: 'user-service', endpoint: 'user-service:8080', status: 'healthy',
              latency_ms: 12 },
            { name: 'db-primary', endpoint: 'postgres-primary:5432', status: 'healthy',
              latency_ms: 3 },
            { name: 'redis-cache', endpoint: 'redis:6379', status: 'healthy',
              latency_ms: 1 }
          ]
        )
      else
        JSON.generate(service: service, status: 'healthy', dependencies: [])
      end
    end
  end

  skill(:logs) do
    description 'Search application logs by service and optional pattern. Returns recent log entries as JSON array'
    input :service, String

    execute do |params|
      service = params[:service].to_s.strip
      if service.include?('api-gateway')
        JSON.generate([
                        { timestamp: '2025-04-06T14:30:01Z', level: 'ERROR', service: 'api-gateway',
                          message: 'Failed to connect to auth-service:8443 — Connection refused' },
                        { timestamp: '2025-04-06T14:30:01Z', level: 'ERROR', service: 'api-gateway',
                          message: 'TLS handshake failed for auth-service:8443 — connection reset by peer' },
                        { timestamp: '2025-04-06T14:30:02Z', level: 'WARN', service: 'api-gateway',
                          message: 'Circuit breaker OPEN for auth-service after 10 consecutive failures' },
                        { timestamp: '2025-04-06T14:30:02Z', level: 'ERROR', service: 'api-gateway',
                          message: 'Auth validation fallback: returning 503 for request /api/v2/orders' },
                        { timestamp: '2025-04-06T14:30:05Z', level: 'ERROR', service: 'api-gateway',
                          message: 'Failed to connect to auth-service:8443 — Connection refused (retry 3/3)' },
                        { timestamp: '2025-04-06T14:31:00Z', level: 'WARN', service: 'api-gateway',
                          message: 'Health check failed: auth-service unreachable on port 8443' },
                        { timestamp: '2025-04-06T14:31:30Z', level: 'INFO', service: 'api-gateway',
                          message: 'Upstream auth-service still listening on port 8080 (legacy), ' \
                                   'but gateway configured for 8443 (TLS)' }
                      ])
      else
        JSON.generate([])
      end
    end
  end

  input 'Alert ALT-7842 is firing — critical error rate on api-gateway. Investigate and report.'
  max_steps 10
end
