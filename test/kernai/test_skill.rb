# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class TestSkill < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai::Skill.reset!
  end

  # --- Skill.define with DSL ---

  def test_define_skill_with_dsl
    skill = Kernai::Skill.define(:search) do
      description 'Search the database'
      input :query, String
      input :limit, Integer, default: 10

      execute do |params|
        "results for #{params[:query]}"
      end
    end

    assert_equal :search, skill.name
    assert_equal 'Search the database', skill.description_text
    assert_equal 2, skill.inputs.size
    assert_equal({ type: String, default: :__no_default__ }, skill.inputs[:query])
    assert_equal({ type: Integer, default: 10 }, skill.inputs[:limit])
    assert_instance_of Proc, skill.execute_block
  end

  # --- Skill.find / Skill.all ---

  def test_find_registered_skill
    Kernai::Skill.define(:search) do
      description 'Search'
      execute do |params|
        params
      end
    end

    found = Kernai::Skill.find(:search)
    assert_equal :search, found.name
    assert_equal 'Search', found.description_text
  end

  def test_find_with_string_name
    Kernai::Skill.define(:search) do
      description 'Search'
      execute do |params|
        params
      end
    end

    found = Kernai::Skill.find('search')
    assert_equal :search, found.name
  end

  def test_find_returns_nil_for_unknown_skill
    assert_nil Kernai::Skill.find(:nonexistent)
  end

  def test_all_returns_all_registered_skills
    Kernai::Skill.define(:alpha) do
      description 'Alpha'
      execute { |params| params }
    end
    Kernai::Skill.define(:beta) do
      description 'Beta'
      execute { |params| params }
    end

    all = Kernai::Skill.all
    assert_equal 2, all.size
    names = all.map(&:name)
    assert_includes names, :alpha
    assert_includes names, :beta
  end

  # --- Skill.unregister ---

  def test_unregister_removes_skill
    Kernai::Skill.define(:search) do
      description 'Search'
      execute { |params| params }
    end

    assert Kernai::Skill.find(:search)
    Kernai::Skill.unregister(:search)
    assert_nil Kernai::Skill.find(:search)
  end

  def test_unregister_with_string_name
    Kernai::Skill.define(:search) do
      description 'Search'
      execute { |params| params }
    end

    Kernai::Skill.unregister('search')
    assert_nil Kernai::Skill.find(:search)
  end

  # --- Skill.reset! ---

  def test_reset_clears_all_skills
    Kernai::Skill.define(:one) do
      description 'One'
      execute { |params| params }
    end
    Kernai::Skill.define(:two) do
      description 'Two'
      execute { |params| params }
    end

    assert_equal 2, Kernai::Skill.all.size
    Kernai::Skill.reset!
    assert_equal 0, Kernai::Skill.all.size
  end

  # --- Skill#call with valid params ---

  def test_call_with_valid_params
    skill = Kernai::Skill.define(:greet) do
      description 'Greet someone'
      input :name, String

      execute do |params|
        "Hello, #{params[:name]}!"
      end
    end

    result = skill.call(name: 'World')
    assert_equal 'Hello, World!', result
  end

  def test_call_with_multiple_params
    skill = Kernai::Skill.define(:search) do
      description 'Search'
      input :query, String
      input :limit, Integer, default: 10

      execute do |params|
        { query: params[:query], limit: params[:limit] }
      end
    end

    result = skill.call(query: 'ruby', limit: 5)
    assert_equal({ query: 'ruby', limit: 5 }, result)
  end

  # --- Skill#call with missing required params ---

  def test_call_raises_on_missing_required_param
    skill = Kernai::Skill.define(:search) do
      description 'Search'
      input :query, String

      execute do |params|
        params
      end
    end

    error = assert_raises(ArgumentError) { skill.call({}) }
    assert_match(/Missing required input: query/, error.message)
  end

  # --- Skill#call with wrong type ---

  def test_call_raises_on_wrong_type
    skill = Kernai::Skill.define(:search) do
      description 'Search'
      input :query, String

      execute do |params|
        params
      end
    end

    error = assert_raises(ArgumentError) { skill.call(query: 123) }
    assert_match(/Expected query to be String, got Integer/, error.message)
  end

  # --- Skill#call with default values ---

  def test_call_uses_default_when_param_omitted
    skill = Kernai::Skill.define(:search) do
      description 'Search'
      input :query, String
      input :limit, Integer, default: 10

      execute do |params|
        params[:limit]
      end
    end

    result = skill.call(query: 'ruby')
    assert_equal 10, result
  end

  def test_call_overrides_default_when_param_provided
    skill = Kernai::Skill.define(:search) do
      description 'Search'
      input :query, String
      input :limit, Integer, default: 10

      execute do |params|
        params[:limit]
      end
    end

    result = skill.call(query: 'ruby', limit: 25)
    assert_equal 25, result
  end

  def test_call_with_nil_default
    skill = Kernai::Skill.define(:optional) do
      description 'Optional param'
      input :tag, String, default: nil

      execute do |params|
        params[:tag]
      end
    end

    result = skill.call({})
    assert_nil result
  end

  # --- Thread-safety ---

  def test_thread_safe_concurrent_define
    threads = 20.times.map do |i|
      Thread.new do
        Kernai::Skill.define(:"skill_#{i}") do
          description "Skill #{i}"
          execute do |_params|
            i
          end
        end
      end
    end

    threads.each(&:join)

    assert_equal 20, Kernai::Skill.all.size
    20.times do |i|
      skill = Kernai::Skill.find(:"skill_#{i}")
      refute_nil skill, "Expected skill_#{i} to be registered"
      assert_equal :"skill_#{i}", skill.name
    end
  end

  # --- Hot reload: load_from with temp files ---

  def test_load_from_loads_skill_files
    Dir.mktmpdir do |dir|
      skill_file = File.join(dir, 'echo_skill.rb')
      File.write(skill_file, <<~RUBY)
        Kernai::Skill.define(:echo) do
          description "Echo input"
          input :text, String

          execute do |params|
            params[:text]
          end
        end
      RUBY

      Kernai::Skill.load_from(File.join(dir, '*.rb'))

      skill = Kernai::Skill.find(:echo)
      refute_nil skill
      assert_equal :echo, skill.name
      assert_equal 'Echo input', skill.description_text
      assert_equal 'hello', skill.call(text: 'hello')
    end
  end

  def test_reload_reloads_all_load_paths
    Dir.mktmpdir do |dir|
      skill_file = File.join(dir, 'counter_skill.rb')
      File.write(skill_file, <<~RUBY)
        Kernai::Skill.define(:counter) do
          description "Version 1"
          execute do |params|
            1
          end
        end
      RUBY

      Kernai::Skill.load_from(File.join(dir, '*.rb'))
      skill = Kernai::Skill.find(:counter)
      assert_equal 'Version 1', skill.description_text

      # Update the file
      File.write(skill_file, <<~RUBY)
        Kernai::Skill.define(:counter) do
          description "Version 2"
          execute do |params|
            2
          end
        end
      RUBY

      Kernai::Skill.reload!
      skill = Kernai::Skill.find(:counter)
      refute_nil skill
      assert_equal 'Version 2', skill.description_text
    end
  end

  def test_load_from_does_not_duplicate_paths
    Dir.mktmpdir do |dir|
      skill_file = File.join(dir, 'simple_skill.rb')
      File.write(skill_file, <<~RUBY)
        Kernai::Skill.define(:simple) do
          description "Simple"
          execute do |params|
            params
          end
        end
      RUBY

      pattern = File.join(dir, '*.rb')
      Kernai::Skill.load_from(pattern)
      Kernai::Skill.load_from(pattern)

      # The skill should still exist (loaded twice is fine, but the path
      # should only appear once in load_paths for reload purposes)
      skill = Kernai::Skill.find(:simple)
      refute_nil skill
    end
  end

  # --- to_description ---

  def test_to_description_with_single_input
    skill = Kernai::Skill.define(:search) do
      description 'Search documents'
      input :query, String
      execute { |p| p[:query] }
    end

    desc = skill.to_description
    assert_includes desc, '- search: Search documents'
    assert_includes desc, 'Inputs: query (String)'
    assert_includes desc, 'name="search"'
  end

  def test_to_description_with_multiple_inputs
    skill = Kernai::Skill.define(:api_call) do
      description 'Call an API'
      input :url, String
      input :method, String, default: 'GET'
      execute { |_| 'ok' }
    end

    desc = skill.to_description
    assert_includes desc, '- api_call: Call an API'
    assert_includes desc, 'url (String)'
    assert_includes desc, 'method (String) default: GET'
    assert_includes desc, '"url"'
    assert_includes desc, '"method"'
  end

  def test_to_description_without_description_text
    skill = Kernai::Skill.define(:bare) do
      execute { |_| 'ok' }
    end

    desc = skill.to_description
    assert_equal '- bare', desc
  end

  # --- Skill.listing ---

  def test_listing_all
    Kernai::Skill.define(:alpha) do
      description 'Alpha skill'
      input :x, String
      execute { |_| 'a' }
    end
    Kernai::Skill.define(:beta) do
      description 'Beta skill'
      input :y, Integer
      execute { |_| 'b' }
    end

    listing = Kernai::Skill.listing(:all)
    assert_includes listing, '- alpha: Alpha skill'
    assert_includes listing, '- beta: Beta skill'
  end

  def test_listing_scoped_to_names
    Kernai::Skill.define(:alpha) do
      description 'Alpha'
      execute { |_| 'a' }
    end
    Kernai::Skill.define(:beta) do
      description 'Beta'
      execute { |_| 'b' }
    end

    listing = Kernai::Skill.listing([:alpha])
    assert_includes listing, '- alpha'
    refute_includes listing, '- beta'
  end

  def test_listing_with_nil_returns_no_skills
    assert_equal 'No skills available.', Kernai::Skill.listing(nil)
  end

  def test_listing_respects_allowed_skills
    Kernai::Skill.define(:allowed) do
      description 'Allowed'
      execute { |_| 'ok' }
    end
    Kernai::Skill.define(:forbidden) do
      description 'Forbidden'
      execute { |_| 'no' }
    end
    Kernai.config.allowed_skills = [:allowed]

    listing = Kernai::Skill.listing(:all)
    assert_includes listing, '- allowed'
    refute_includes listing, '- forbidden'
  end

  def test_listing_empty_registry
    assert_equal 'No skills available.', Kernai::Skill.listing(:all)
  end
end
