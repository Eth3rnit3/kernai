# frozen_string_literal: true

require_relative '../test_helper'

# Typed input validation beyond a single Class: union types, homogeneous
# arrays, and object schemas (including nested array-of-hash). These are
# required to express non-trivial tool payloads (e.g. a plan with a list
# of typed tickets) without forcing each skill to hand-roll its own
# JSON validation.
class TestSkillTypedInputs < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai::Skill.reset!
  end

  # --- Union types: [Class, Class, ...] ---

  def test_union_type_accepts_any_listed_class
    skill = Kernai::Skill.define(:toggle) do
      input :flag, [TrueClass, FalseClass]
      execute { |p| p[:flag] }
    end

    assert_equal true, skill.call(flag: true)
    assert_equal false, skill.call(flag: false)
  end

  def test_union_type_rejects_value_outside_the_union
    skill = Kernai::Skill.define(:toggle) do
      input :flag, [TrueClass, FalseClass]
      execute { |p| p[:flag] }
    end

    err = assert_raises(ArgumentError) { skill.call(flag: 'yes') }
    assert_match(/Expected flag to be TrueClass or FalseClass, got String/, err.message)
  end

  def test_union_type_rendered_in_description
    skill = Kernai::Skill.define(:toggle) do
      description 'Toggle a flag'
      input :flag, [TrueClass, FalseClass]
      execute { |p| p[:flag] }
    end

    assert_includes skill.to_description, 'flag (TrueClass|FalseClass)'
  end

  # --- Array of scalars ---

  def test_array_of_scalar_validates_each_element
    skill = Kernai::Skill.define(:tag) do
      input :labels, Array, of: String
      execute { |p| p[:labels] }
    end

    assert_equal %w[a b c], skill.call(labels: %w[a b c])
  end

  def test_array_of_scalar_raises_on_element_type_mismatch
    skill = Kernai::Skill.define(:tag) do
      input :labels, Array, of: String
      execute { |p| p[:labels] }
    end

    err = assert_raises(ArgumentError) { skill.call(labels: ['a', 42]) }
    assert_match(/labels\[1\] to be String, got Integer/, err.message)
  end

  def test_array_of_requires_array_type_at_top_level
    skill = Kernai::Skill.define(:tag) do
      input :labels, Array, of: String
      execute { |p| p[:labels] }
    end

    err = assert_raises(ArgumentError) { skill.call(labels: 'oops') }
    assert_match(/Expected labels to be Array, got String/, err.message)
  end

  def test_array_with_default_empty
    skill = Kernai::Skill.define(:tag) do
      input :labels, Array, of: String, default: []
      execute { |p| p[:labels] }
    end

    assert_equal [], skill.call({})
  end

  def test_array_of_rendered_in_description
    skill = Kernai::Skill.define(:tag) do
      description 'Tag items'
      input :labels, Array, of: String
      execute { |p| p[:labels] }
    end

    assert_includes skill.to_description, 'labels (Array<String>)'
  end

  # --- Hash with schema (single object) ---

  def test_hash_schema_validates_keys
    skill = Kernai::Skill.define(:configure) do
      input :options, Hash, schema: { retries: Integer, strict: [TrueClass, FalseClass] }
      execute { |p| p[:options] }
    end

    result = skill.call(options: { retries: 3, strict: true })
    assert_equal({ retries: 3, strict: true }, result)
  end

  def test_hash_schema_missing_required_key_uses_dotted_path
    skill = Kernai::Skill.define(:configure) do
      input :options, Hash, schema: { retries: Integer }
      execute { |p| p[:options] }
    end

    err = assert_raises(ArgumentError) { skill.call(options: {}) }
    assert_match(/Missing required input: options\.retries/, err.message)
  end

  def test_hash_schema_accepts_string_keys_and_returns_symbol_keys
    skill = Kernai::Skill.define(:configure) do
      input :options, Hash, schema: { retries: Integer }
      execute { |p| p[:options] }
    end

    result = skill.call(options: { 'retries' => 5 })
    assert_equal({ retries: 5 }, result)
  end

  def test_hash_schema_applies_nested_defaults
    skill = Kernai::Skill.define(:configure) do
      input :options, Hash, schema: { retries: { type: Integer, default: 3 } }
      execute { |p| p[:options] }
    end

    assert_equal({ retries: 3 }, skill.call(options: {}))
  end

  def test_hash_schema_type_mismatch_uses_dotted_path
    skill = Kernai::Skill.define(:configure) do
      input :options, Hash, schema: { retries: Integer }
      execute { |p| p[:options] }
    end

    err = assert_raises(ArgumentError) { skill.call(options: { retries: 'three' }) }
    assert_match(/options\.retries to be Integer, got String/, err.message)
  end

  # --- Array of object (shorthand :of => schema hash) ---

  def test_array_of_hash_shorthand_applies_defaults
    skill = Kernai::Skill.define(:plan) do
      input :tickets, Array, of: {
        title: String,
        description: String,
        priority: { type: String, default: 'medium' }
      }
      execute { |p| p[:tickets] }
    end

    result = skill.call(tickets: [
                          { title: 'A', description: 'First' },
                          { title: 'B', description: 'Second', priority: 'high' }
                        ])

    assert_equal 2, result.size
    assert_equal 'medium', result[0][:priority]
    assert_equal 'high', result[1][:priority]
  end

  def test_array_of_hash_reports_path_on_nested_type_error
    skill = Kernai::Skill.define(:plan) do
      input :tickets, Array, of: {
        title: String,
        priority: String
      }
      execute { |p| p[:tickets] }
    end

    err = assert_raises(ArgumentError) do
      skill.call(tickets: [
                   { title: 'OK', priority: 'low' },
                   { title: 'Fail', priority: 42 }
                 ])
    end
    assert_match(/tickets\[1\]\.priority to be String, got Integer/, err.message)
  end

  def test_array_of_hash_reports_path_on_missing_nested_key
    skill = Kernai::Skill.define(:plan) do
      input :tickets, Array, of: { title: String, priority: String }
      execute { |p| p[:tickets] }
    end

    err = assert_raises(ArgumentError) do
      skill.call(tickets: [{ title: 'OK', priority: 'low' }, { title: 'Fail' }])
    end
    assert_match(/Missing required input: tickets\[1\]\.priority/, err.message)
  end

  # --- Deeply nested (array of hash with inner array) ---

  def test_deeply_nested_schema_with_inner_array
    skill = Kernai::Skill.define(:complex) do
      input :items, Array, of: {
        name: String,
        tags: { type: Array, of: String, default: [] }
      }
      execute { |p| p[:items] }
    end

    result = skill.call(items: [{ name: 'x', tags: %w[a b] }, { name: 'y' }])
    assert_equal %w[a b], result[0][:tags]
    assert_equal [], result[1][:tags]
  end

  def test_deeply_nested_schema_reports_inner_array_path
    skill = Kernai::Skill.define(:complex) do
      input :items, Array, of: {
        name: String,
        tags: { type: Array, of: String }
      }
      execute { |p| p[:items] }
    end

    err = assert_raises(ArgumentError) do
      skill.call(items: [{ name: 'x', tags: ['ok', 42] }])
    end
    assert_match(/items\[0\]\.tags\[1\] to be String, got Integer/, err.message)
  end

  # --- JSON payload (string-keyed at every depth) ---

  def test_nested_string_keyed_payload_is_normalised
    skill = Kernai::Skill.define(:plan) do
      input :tickets, Array, of: {
        title: String,
        priority: { type: String, default: 'medium' }
      }
      execute { |p| p[:tickets] }
    end

    payload = JSON.parse('[{"title":"A","priority":"high"},{"title":"B"}]')
    result = skill.call(tickets: payload)
    assert_equal 'high', result[0][:priority]
    assert_equal 'medium', result[1][:priority]
  end

  # --- Description rendering ---

  def test_to_description_renders_nested_schema
    skill = Kernai::Skill.define(:plan) do
      description 'Plan a project'
      input :tickets, Array, of: {
        title: String,
        priority: { type: String, default: 'medium' }
      }
      execute { |p| p[:tickets] }
    end

    desc = skill.to_description
    assert_includes desc, 'tickets (Array<Hash{'
    assert_includes desc, 'title: String'
    assert_includes desc, 'priority: String'
  end

  def test_to_description_renders_single_hash_schema
    skill = Kernai::Skill.define(:configure) do
      description 'Configure'
      input :options, Hash, schema: { retries: Integer, strict: [TrueClass, FalseClass] }
      execute { |p| p[:options] }
    end

    desc = skill.to_description
    assert_includes desc, 'options (Hash{retries: Integer'
    assert_includes desc, 'strict: TrueClass|FalseClass'
  end

  # --- Invalid element spec ---

  def test_invalid_element_spec_raises_clear_error_at_definition_time
    err = assert_raises(ArgumentError) do
      Kernai::Skill.define(:bad) do
        input :items, Array, of: 42
        execute { |p| p[:items] }
      end.call(items: [])
    end
    assert_match(/Invalid.*spec/i, err.message)
  end

  # --- Simple single-class case still works (regression) ---

  def test_simple_class_input_unchanged
    skill = Kernai::Skill.define(:greet) do
      input :name, String
      execute { |p| "hi #{p[:name]}" }
    end

    assert_equal 'hi alice', skill.call(name: 'alice')

    err = assert_raises(ArgumentError) { skill.call(name: 42) }
    assert_match(/Expected name to be String, got Integer/, err.message)
  end

  def test_simple_class_with_default_unchanged
    skill = Kernai::Skill.define(:greet) do
      input :name, String, default: 'world'
      execute { |p| "hi #{p[:name]}" }
    end

    assert_equal 'hi world', skill.call({})
  end
end
