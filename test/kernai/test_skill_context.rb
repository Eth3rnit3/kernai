# frozen_string_literal: true

require 'test_helper'

class TestSkillContext < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai::Skill.reset!
  end

  def define_skill
    Kernai::Skill.define(:search) do
      input :query, String
      config :endpoint, String, default: 'https://default.test'
      config :limit, Integer, default: 10
      credential :api_key, required: true
      credential :optional_key

      execute { |p, _ctx| p[:query] }
    end
  end

  # --- credential lookup ---

  def test_credential_resolves_via_configured_resolver
    skill = define_skill
    Kernai.config.credential_resolver = Kernai::HashResolver.new(search: { api_key: 'abc' })
    ctx = Kernai::SkillContext.new(skill)
    assert_equal 'abc', ctx.credential(:api_key)
  end

  def test_credential_required_missing_raises
    skill = define_skill
    Kernai.config.credential_resolver = Kernai::HashResolver.new
    ctx = Kernai::SkillContext.new(skill)
    err = assert_raises(Kernai::CredentialMissingError) { ctx.credential(:api_key) }
    assert_match(/api_key/, err.message)
    assert_match(/search/, err.message)
  end

  def test_credential_optional_missing_returns_nil
    skill = define_skill
    Kernai.config.credential_resolver = Kernai::HashResolver.new
    ctx = Kernai::SkillContext.new(skill)
    assert_nil ctx.credential(:optional_key)
  end

  def test_credential_undeclared_raises_argument_error
    skill = define_skill
    ctx = Kernai::SkillContext.new(skill)
    assert_raises(ArgumentError) { ctx.credential(:never_declared) }
  end

  def test_credential_is_cached
    skill = define_skill
    call_count = 0
    resolver = Class.new do
      define_method(:resolve) do |_s, _k|
        call_count += 1
        'x'
      end
    end.new
    Kernai.config.credential_resolver = resolver
    ctx = Kernai::SkillContext.new(skill)
    3.times { ctx.credential(:api_key) }
    assert_equal 1, call_count
  end

  # --- config lookup ---

  def test_config_returns_default_when_resolver_empty
    skill = define_skill
    Kernai.config.config_resolver = Kernai::HashResolver.new
    ctx = Kernai::SkillContext.new(skill)
    assert_equal 'https://default.test', ctx.config(:endpoint)
  end

  def test_config_returns_resolver_value_when_present
    skill = define_skill
    Kernai.config.config_resolver = Kernai::HashResolver.new(search: { endpoint: 'https://override.test' })
    ctx = Kernai::SkillContext.new(skill)
    assert_equal 'https://override.test', ctx.config(:endpoint)
  end

  def test_config_coerces_integer
    skill = define_skill
    Kernai.config.config_resolver = Kernai::HashResolver.new(search: { limit: '25' })
    ctx = Kernai::SkillContext.new(skill)
    assert_equal 25, ctx.config(:limit)
  end

  def test_config_undeclared_raises
    skill = define_skill
    ctx = Kernai::SkillContext.new(skill)
    assert_raises(ArgumentError) { ctx.config(:never_declared) }
  end

  # --- injected resolvers override globals ---

  def test_injected_resolvers_override_global_config
    skill = define_skill
    Kernai.config.credential_resolver = Kernai::HashResolver.new(search: { api_key: 'global' })
    local = Kernai::HashResolver.new(search: { api_key: 'local' })
    ctx = Kernai::SkillContext.new(skill, credential_resolver: local)
    assert_equal 'local', ctx.credential(:api_key)
  end
end
