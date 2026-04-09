# frozen_string_literal: true

# Scenario: Real-world fraud investigation DAG (🔴 bonus)
#
# A cardholder is disputing a transaction. The agent must correlate evidence
# from FIVE independent sources to decide whether to refund, investigate,
# or reject the dispute. This is the flagship stress test: a mixed DAG with
# parallel fan-out on three data sources, a device-risk task that depends
# on two of them, and a final decision task depending on everything.
#
# Expected DAG:
#
#       +-----------------+     +----------------+     +---------------+
#       | t_tx_details    |     | t_cardholder   |     | t_geoip_trail |
#       | (parallel)      |     | (parallel)     |     | (parallel)    |
#       +--------+--------+     +--------+-------+     +-------+-------+
#                |                       |                     |
#                +------+----------------+---------------------+
#                       |                                      |
#                       v                                      v
#              +------------------+                   +-----------------+
#              |  t_device_risk   |                   | (still running) |
#              |  depends_on:     |                   +-----------------+
#              |  [t_cardholder,  |
#              |   t_geoip_trail] |
#              +---------+--------+
#                        |
#                        v
#              +--------------------+
#              |  t_decision        |
#              |  depends_on: all   |
#              |  four above        |
#              +--------------------+
#
# Expected behavior:
#   1. Root agent emits one plan with five tasks matching the DAG above.
#   2. Scheduler runs the three "leaf" tasks concurrently, then t_device_risk
#      (which fuses cardholder + geoip), then t_decision (which sees
#      everything).
#   3. Root agent's final answer contains: transaction id, verdict
#      (refund / investigate / reject), confidence, and a bulleted evidence
#      trail citing each sub-result.
#
# Expected verdict from the deterministic fixtures: REFUND the $2,350 charge.
#   - Transaction TX-99812 in Manila, PH on 2026-04-09T02:14Z
#   - Cardholder lives in Lyon, FR; travel status = "none"
#   - GeoIP login trail is 100% EU for the past 30 days
#   - Device fingerprint is NEW (first seen 2 minutes before the charge)
#   - Merchant category 5967 is on the carrier's high-risk list
#
# Failure modes:
#   - Agent skips one of the data sources (incomplete evidence).
#   - Agent ignores the plan mechanism and chains skill calls manually
#     (defeats the parallelism + DAG test).
#   - t_device_risk runs before t_cardholder + t_geoip_trail finish.
#   - Final verdict contradicts the evidence (e.g. "reject dispute" despite
#     the obvious geo mismatch).
#
#   ruby scenarios/fraud_investigation_dag.rb
#   ruby scenarios/fraud_investigation_dag.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'fraud_investigation_dag',
  description: 'Mixed DAG fraud investigation: parallel evidence gathering + layered aggregation'
) do
  instructions <<~PROMPT
    You are the fraud triage agent for a payment processor. A cardholder is
    disputing a recent charge. You must build an evidence-driven decision by
    delegating work through a structured workflow plan.

    You MUST emit exactly one <block type="plan"> with FIVE tasks arranged
    in the following DAG (use strategy "mixed"):

      t_tx_details    (parallel: true,  depends_on: [])
        -> call `transaction_lookup` with the disputed tx id
      t_cardholder    (parallel: true,  depends_on: [])
        -> call `cardholder_profile` with the customer id
      t_geoip_trail   (parallel: true,  depends_on: [])
        -> call `geoip_trail` with the customer id (last 30 days)
      t_device_risk   (parallel: false, depends_on: [t_cardholder, t_geoip_trail])
        -> call `device_risk` after correlating profile + login trail
      t_decision      (parallel: false, depends_on: [t_tx_details, t_cardholder, t_geoip_trail, t_device_risk])
        -> synthesize a verdict: "refund", "investigate" or "reject"

    Rules:
      - Do NOT call any skill from the root agent. Every skill call must
        happen inside a sub-agent through this plan.
      - Every task input should be precise enough that an isolated sub-agent
        with no outside context can execute it.
      - When task results come back, your final answer must contain:
          * disputed transaction id + amount + merchant
          * verdict + confidence (low / medium / high)
          * evidence trail with one bullet per sub-task
          * recommended next step
  PROMPT

  skill(:transaction_lookup) do
    description 'Fetch the full details of a disputed transaction by id.'
    input :tx_id, String

    execute do |_params|
      JSON.generate(
        tx_id: 'TX-99812',
        amount_usd: 2350.00,
        merchant: 'LuxeWatch Manila',
        merchant_category_code: '5967',
        mcc_label: 'Direct Marketing - High Risk',
        country: 'PH',
        city: 'Manila',
        authorized_at: '2026-04-09T02:14:31Z',
        channel: 'card-not-present',
        entry_mode: 'ecommerce',
        three_ds_status: 'not_attempted'
      )
    end
  end

  skill(:cardholder_profile) do
    description 'Fetch cardholder profile including residency and declared travel.'
    input :customer_id, String

    execute do |_params|
      JSON.generate(
        customer_id: 'CUST-44019',
        name: 'Camille Besson',
        residency: { city: 'Lyon', country: 'FR' },
        account_age_years: 6,
        lifetime_spend_usd: 48_120,
        declared_travel: [],
        travel_status: 'none',
        prior_disputes_12mo: 0,
        tier: 'gold'
      )
    end
  end

  skill(:geoip_trail) do
    description 'Return the login geoip trail for a customer over the past 30 days.'
    input :customer_id, String

    execute do |_params|
      JSON.generate(
        customer_id: 'CUST-44019',
        window: '2026-03-10..2026-04-09',
        logins: [
          { at: '2026-04-08T19:12:00Z', ip: '90.12.44.7',  city: 'Lyon',     country: 'FR' },
          { at: '2026-04-07T08:41:00Z', ip: '90.12.44.7',  city: 'Lyon',     country: 'FR' },
          { at: '2026-04-05T17:02:00Z', ip: '90.12.44.7',  city: 'Lyon',     country: 'FR' },
          { at: '2026-04-01T11:18:00Z', ip: '194.6.55.3',  city: 'Paris',    country: 'FR' },
          { at: '2026-03-27T20:05:00Z', ip: '194.6.55.3',  city: 'Paris',    country: 'FR' },
          { at: '2026-03-20T09:48:00Z', ip: '90.12.44.7',  city: 'Lyon',     country: 'FR' }
        ],
        countries_seen: ['FR'],
        impossible_travel_flag: false
      )
    end
  end

  skill(:device_risk) do
    description 'Score the device fingerprint used for the disputed transaction.'
    input :query, String

    execute do |_params|
      JSON.generate(
        device_fingerprint: 'DFP-UNKNOWN-7711',
        first_seen_at: '2026-04-09T02:12:47Z',
        first_seen_delta_sec: 104,
        prior_sessions: 0,
        os: 'Android 11 (rooted)',
        browser: 'Chrome 102 (outdated)',
        ip: '49.144.181.22',
        ip_country: 'PH',
        risk_score: 0.93,
        risk_band: 'high',
        tor_exit_node: false,
        datacenter_asn: true
      )
    end
  end

  input <<~TICKET
    Customer CUST-44019 is disputing transaction TX-99812 ($2,350 at LuxeWatch Manila,
    authorized 2026-04-09 02:14 UTC). They say "I was asleep at home in Lyon, I've
    never been to the Philippines, this is not me." Investigate and recommend a verdict.
  TICKET
  max_steps 10
end
