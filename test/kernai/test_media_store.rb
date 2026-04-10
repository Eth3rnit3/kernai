# frozen_string_literal: true

require_relative '../test_helper'

class TestMediaStore < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @store = Kernai::MediaStore.new
    @img = Kernai::Media.from_bytes('bytes', mime_type: 'image/png')
  end

  def test_put_and_fetch_roundtrip
    @store.put(@img)
    assert_same @img, @store.fetch(@img.id)
    assert_equal 1, @store.size
    refute @store.empty?
  end

  def test_fetch_unknown_returns_nil
    assert_nil @store.fetch('media_does_not_exist')
  end

  def test_put_rejects_non_media
    assert_raises(ArgumentError) { @store.put('not a media') }
  end

  def test_sub_context_shares_store
    parent = Kernai::Context.new
    parent.media_store.put(@img)

    child = parent.spawn_child
    assert_same parent.media_store, child.media_store
    assert_same @img, child.media_store.fetch(@img.id)
  end

  def test_fresh_context_has_empty_store
    assert Kernai::Context.new.media_store.empty?
  end
end
