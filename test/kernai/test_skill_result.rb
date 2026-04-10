# frozen_string_literal: true

require_relative '../test_helper'

class TestSkillResult < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @store = Kernai::MediaStore.new
    @img = Kernai::Media.from_bytes('png', mime_type: 'image/png')
  end

  def test_wrap_string
    assert_equal ['hello'], Kernai::SkillResult.wrap('hello', @store)
  end

  def test_wrap_media_registers_in_store
    parts = Kernai::SkillResult.wrap(@img, @store)
    assert_equal [@img], parts
    assert_same @img, @store.fetch(@img.id)
  end

  def test_wrap_mixed_array
    parts = Kernai::SkillResult.wrap(['look:', @img], @store)
    assert_equal ['look:', @img], parts
    assert_same @img, @store.fetch(@img.id)
  end

  def test_wrap_nil_yields_empty_string
    assert_equal [''], Kernai::SkillResult.wrap(nil, @store)
  end

  def test_wrap_non_string_coerces_to_string
    assert_equal ['42'], Kernai::SkillResult.wrap(42, @store)
  end
end
