# frozen_string_literal: true

require_relative '../test_helper'

class TestParser < Minitest::Test
  include Kernai::TestHelpers

  # -- Single block --

  def test_parse_single_block
    text = '<block type="command">ls -la</block>'
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].length
    block = result[:blocks].first
    assert_equal :command, block.type
    assert_equal 'ls -la', block.content
    assert_nil block.name
  end

  def test_parse_single_block_with_name
    text = '<block type="command" name="deploy">run deploy</block>'
    result = Kernai::Parser.parse(text)

    block = result[:blocks].first
    assert_equal :command, block.type
    assert_equal 'deploy', block.name
    assert_equal 'run deploy', block.content
  end

  # -- Multiple blocks --

  def test_parse_multiple_blocks
    text = '<block type="command">ls</block><block type="json">{"a":1}</block>'
    result = Kernai::Parser.parse(text)

    assert_equal 2, result[:blocks].length
    assert_equal :command, result[:blocks][0].type
    assert_equal 'ls', result[:blocks][0].content
    assert_equal :json, result[:blocks][1].type
    assert_equal '{"a":1}', result[:blocks][1].content
  end

  # -- Text segments --

  def test_parse_text_before_block
    text = 'Here is the output: <block type="result">42</block>'
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].length
    assert_equal 1, result[:text_segments].length
    assert_equal 'Here is the output: ', result[:text_segments].first
  end

  def test_parse_text_after_block
    text = '<block type="result">42</block> That is the answer.'
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].length
    assert_equal 1, result[:text_segments].length
    assert_equal ' That is the answer.', result[:text_segments].first
  end

  def test_parse_text_between_blocks
    text = '<block type="plan">step 1</block> Then we do: <block type="command">go</block>'
    result = Kernai::Parser.parse(text)

    assert_equal 2, result[:blocks].length
    assert_equal 1, result[:text_segments].length
    assert_equal ' Then we do: ', result[:text_segments].first
  end

  def test_parse_text_before_between_and_after
    text = 'Intro <block type="plan">step 1</block> Middle <block type="result">done</block> End'
    result = Kernai::Parser.parse(text)

    assert_equal 2, result[:blocks].length
    assert_equal 3, result[:text_segments].length
    assert_equal 'Intro ', result[:text_segments][0]
    assert_equal ' Middle ', result[:text_segments][1]
    assert_equal ' End', result[:text_segments][2]
  end

  # -- Edge cases --

  def test_parse_no_blocks
    text = 'Just some plain text without any blocks.'
    result = Kernai::Parser.parse(text)

    assert_empty result[:blocks]
    assert_equal 1, result[:text_segments].length
    assert_equal text, result[:text_segments].first
  end

  def test_parse_empty_string
    result = Kernai::Parser.parse('')

    assert_empty result[:blocks]
    assert_empty result[:text_segments]
  end

  def test_parse_multiline_content
    text = "<block type=\"json\">\n{\n  \"key\": \"value\"\n}\n</block>"
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].length
    assert_equal :json, result[:blocks].first.type
    assert_includes result[:blocks].first.content, '"key": "value"'
  end

  def test_parse_whitespace_only_text_segments_are_excluded
    text = '   <block type="command">ls</block>   '
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].length
    assert_empty result[:text_segments]
  end

  def test_parse_all_block_types
    types = %w[command json final plan result error]
    text = types.map { |t| "<block type=\"#{t}\">content_#{t}</block>" }.join
    result = Kernai::Parser.parse(text)

    assert_equal 6, result[:blocks].length
    types.each_with_index do |t, i|
      assert_equal t.to_sym, result[:blocks][i].type
      assert_equal "content_#{t}", result[:blocks][i].content
    end
  end

  # -- Shorthand format --

  def test_parse_shorthand_final
    text = '<final>The answer is 42.</final>'
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].size
    assert_equal :final, result[:blocks][0].type
    assert_equal 'The answer is 42.', result[:blocks][0].content
  end

  def test_parse_shorthand_command_with_name
    text = '<command name="weather">London</command>'
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].size
    assert_equal :command, result[:blocks][0].type
    assert_equal 'weather', result[:blocks][0].name
    assert_equal 'London', result[:blocks][0].content
  end

  def test_parse_shorthand_multiple_types
    text = '<plan>Let me think</plan><command name="search">query</command><final>Done</final>'
    result = Kernai::Parser.parse(text)

    assert_equal 3, result[:blocks].size
    assert_equal :plan, result[:blocks][0].type
    assert_equal :command, result[:blocks][1].type
    assert_equal 'search', result[:blocks][1].name
    assert_equal :final, result[:blocks][2].type
  end

  def test_parse_shorthand_with_text_segments
    text = 'Before <final>answer</final> after'
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].size
    assert_equal 2, result[:text_segments].size
    assert_equal 'Before ', result[:text_segments][0]
    assert_equal ' after', result[:text_segments][1]
  end

  def test_parse_mixed_canonical_and_shorthand
    text = '<block type="plan">step 1</block><command name="db">query</command><final>done</final>'
    result = Kernai::Parser.parse(text)

    assert_equal 3, result[:blocks].size
    assert_equal :plan, result[:blocks][0].type
    assert_equal :command, result[:blocks][1].type
    assert_equal :final, result[:blocks][2].type
  end

  def test_parse_shorthand_multiline
    text = "<final>\nLine 1\nLine 2\n</final>"
    result = Kernai::Parser.parse(text)

    assert_equal 1, result[:blocks].size
    assert_includes result[:blocks][0].content, 'Line 1'
    assert_includes result[:blocks][0].content, 'Line 2'
  end
end
