# frozen_string_literal: true

require_relative '../test_helper'
require 'tempfile'

class TestMedia < Minitest::Test
  include Kernai::TestHelpers

  def test_from_bytes_builds_image_by_default
    m = Kernai::Media.from_bytes('fake_png', mime_type: 'image/png')
    assert_equal :image, m.kind
    assert_equal 'image/png', m.mime_type
    assert_equal :bytes, m.source
    assert m.bytes?
    refute m.url?
  end

  def test_from_url_builds_image
    m = Kernai::Media.from_url('https://example.com/cat.jpg')
    assert_equal :image, m.kind
    assert_equal 'image/jpeg', m.mime_type
    assert m.url?
  end

  def test_from_file_reads_bytes_lazily
    file = Tempfile.new(['kernai', '.png'])
    file.binmode
    file.write('PNGDATA')
    file.close

    m = Kernai::Media.from_file(file.path)
    assert_equal :image, m.kind
    assert_equal 'image/png', m.mime_type
    assert_equal :path, m.source
    assert_equal 'PNGDATA', m.read_bytes
    assert_equal Base64.strict_encode64('PNGDATA'), m.to_base64
  ensure
    file&.unlink
  end

  def test_id_is_deterministic_from_payload
    a = Kernai::Media.from_bytes('same', mime_type: 'image/png')
    b = Kernai::Media.from_bytes('same', mime_type: 'image/png')
    c = Kernai::Media.from_bytes('diff', mime_type: 'image/png')
    assert_equal a.id, b.id
    refute_equal a.id, c.id
  end

  def test_read_bytes_raises_for_url_backed
    m = Kernai::Media.from_url('https://example.com/x.png')
    assert_raises(Kernai::Error) { m.read_bytes }
  end

  def test_invalid_kind_raises
    assert_raises(ArgumentError) do
      Kernai::Media.new(kind: :hologram, mime_type: 'x/y', source: :bytes, data: 'z')
    end
  end

  def test_kind_inferred_from_mime
    assert_equal :image, Kernai::Media.from_bytes('x', mime_type: 'image/png').kind
    assert_equal :audio, Kernai::Media.from_bytes('x', mime_type: 'audio/mpeg').kind
    assert_equal :video, Kernai::Media.from_bytes('x', mime_type: 'video/mp4').kind
    assert_equal :document, Kernai::Media.from_bytes('x', mime_type: 'application/pdf').kind
  end
end
