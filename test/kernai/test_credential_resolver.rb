# frozen_string_literal: true

require 'test_helper'

class TestCredentialResolver < Minitest::Test
  include Kernai::TestHelpers

  # --- EnvResolver ---

  def test_env_resolver_reads_scoped_env_key
    ENV['KERNAI_SKILL_SEARCH_API_KEY'] = 'secret-123'
    resolver = Kernai::EnvResolver.new
    assert_equal 'secret-123', resolver.resolve(:search, :api_key)
  ensure
    ENV.delete('KERNAI_SKILL_SEARCH_API_KEY')
  end

  def test_env_resolver_returns_nil_when_missing
    resolver = Kernai::EnvResolver.new
    assert_nil resolver.resolve(:search, :api_key)
  end

  def test_env_resolver_does_not_fall_back_to_bare_env
    # Safety: a bare ENV[API_KEY] would let unrelated process state
    # leak into skill credentials. We require the scoped prefix.
    ENV['API_KEY'] = 'unrelated'
    resolver = Kernai::EnvResolver.new
    assert_nil resolver.resolve(:search, :api_key)
  ensure
    ENV.delete('API_KEY')
  end

  def test_env_config_resolver_reads_scoped_env_key
    ENV['KERNAI_SKILL_SEARCH_ENDPOINT'] = 'https://example.test'
    resolver = Kernai::EnvConfigResolver.new
    assert_equal 'https://example.test', resolver.resolve(:search, :endpoint)
  ensure
    ENV.delete('KERNAI_SKILL_SEARCH_ENDPOINT')
  end

  # --- HashResolver ---

  def test_hash_resolver_nested_per_skill
    resolver = Kernai::HashResolver.new(search: { api_key: 'k1' }, summarize: { api_key: 'k2' })
    assert_equal 'k1', resolver.resolve(:search, :api_key)
    assert_equal 'k2', resolver.resolve(:summarize, :api_key)
  end

  def test_hash_resolver_flat_global
    resolver = Kernai::HashResolver.new(api_key: 'global')
    assert_equal 'global', resolver.resolve(:search, :api_key)
  end

  def test_hash_resolver_returns_nil_when_missing
    resolver = Kernai::HashResolver.new
    assert_nil resolver.resolve(:search, :api_key)
  end

  def test_hash_resolver_coerces_values_to_string
    resolver = Kernai::HashResolver.new(count: 42)
    assert_equal '42', resolver.resolve(:any, :count)
  end
end
