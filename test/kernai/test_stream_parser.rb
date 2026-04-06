require_relative "../test_helper"

class TestStreamParser < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @parser = Kernai::StreamParser.new
    @events = []
  end

  def register_all_callbacks
    %i[text_chunk block_start block_content block_complete].each do |event|
      @parser.on(event) { |data| @events << [event, data] }
    end
  end

  # -- Basic parsing --

  def test_plain_text_emits_text_chunk
    register_all_callbacks
    @parser.push("Hello world")
    @parser.flush

    text_events = @events.select { |e, _| e == :text_chunk }
    combined = text_events.map { |_, d| d }.join
    assert_equal "Hello world", combined
  end

  def test_single_block_in_one_chunk
    register_all_callbacks
    @parser.push('<block type="command">ls -la</block>')

    starts = @events.select { |e, _| e == :block_start }
    assert_equal 1, starts.length
    assert_equal :command, starts.first[1][:type]
    assert_nil starts.first[1][:name]

    contents = @events.select { |e, _| e == :block_content }
    combined_content = contents.map { |_, d| d }.join
    assert_equal "ls -la", combined_content

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 1, completes.length
    assert_instance_of Kernai::Block, completes.first[1]
    assert_equal :command, completes.first[1].type
    assert_equal "ls -la", completes.first[1].content
  end

  def test_block_with_name
    register_all_callbacks
    @parser.push('<block type="command" name="deploy">run it</block>')

    starts = @events.select { |e, _| e == :block_start }
    assert_equal "deploy", starts.first[1][:name]

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal "deploy", completes.first[1].name
  end

  # -- Chunk splitting --

  def test_tag_split_across_chunks
    register_all_callbacks

    @parser.push("<bl")
    @parser.push('ock type="command">')
    @parser.push("hello")
    @parser.push("</block>")

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 1, completes.length
    assert_equal :command, completes.first[1].type
    assert_equal "hello", completes.first[1].content
  end

  def test_close_tag_split_across_chunks
    register_all_callbacks

    @parser.push('<block type="command">data</bl')
    @parser.push("ock>")

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 1, completes.length
    assert_equal "data", completes.first[1].content
  end

  def test_content_split_across_chunks
    register_all_callbacks

    @parser.push('<block type="json">{"key":')
    @parser.push('"value"}</block>')

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 1, completes.length
    assert_equal '{"key":"value"}', completes.first[1].content
  end

  def test_text_before_and_after_block
    register_all_callbacks

    @parser.push('Hello <block type="result">42</block> world')
    @parser.flush

    text_events = @events.select { |e, _| e == :text_chunk }
    combined_text = text_events.map { |_, d| d }.join
    assert_equal "Hello  world", combined_text

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 1, completes.length
    assert_equal "42", completes.first[1].content
  end

  # -- Multiple blocks --

  def test_multiple_blocks_in_sequence
    register_all_callbacks

    @parser.push('<block type="plan">step 1</block><block type="command">go</block>')

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 2, completes.length
    assert_equal :plan, completes[0][1].type
    assert_equal "step 1", completes[0][1].content
    assert_equal :command, completes[1][1].type
    assert_equal "go", completes[1][1].content
  end

  # -- Event callbacks --

  def test_on_registers_callback
    called = false
    @parser.on(:block_complete) { |_data| called = true }
    @parser.push('<block type="command">test</block>')
    assert called, "block_complete callback should have been called"
  end

  def test_unregistered_events_are_ignored
    # Should not raise
    @parser.push('<block type="command">test</block>')
    @parser.flush
  end

  # -- State management --

  def test_initial_state_is_text
    assert_equal :text, @parser.state
  end

  def test_reset_clears_state
    register_all_callbacks
    @parser.push('<block type="command">partial')
    # State should be :block_content now
    assert_equal :block_content, @parser.state

    @parser.reset
    assert_equal :text, @parser.state

    # After reset, a new complete block should parse correctly
    @events.clear
    @parser.push('<block type="json">{"ok":true}</block>')

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 1, completes.length
    assert_equal :json, completes.first[1].type
  end

  def test_flush_emits_remaining_text
    register_all_callbacks
    @parser.push("some trailing text")
    # text_chunk may have been emitted already since there's no '<'
    @parser.flush

    text_events = @events.select { |e, _| e == :text_chunk }
    combined = text_events.map { |_, d| d }.join
    assert_equal "some trailing text", combined
  end

  def test_flush_resets_state_to_text
    @parser.push('<block type="command">incomplete')
    assert_equal :block_content, @parser.state

    @parser.flush
    assert_equal :text, @parser.state
  end

  # -- Edge cases --

  def test_angle_bracket_not_block_tag
    register_all_callbacks
    @parser.push("x < y and a > b")
    @parser.flush

    text_events = @events.select { |e, _| e == :text_chunk }
    combined = text_events.map { |_, d| d }.join
    assert_equal "x < y and a > b", combined

    completes = @events.select { |e, _| e == :block_complete }
    assert_empty completes
  end

  def test_empty_block_content
    register_all_callbacks
    @parser.push('<block type="command"></block>')

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 1, completes.length
    assert_equal "", completes.first[1].content
  end

  def test_single_char_chunks
    register_all_callbacks
    input = '<block type="command">hi</block>'
    input.each_char { |c| @parser.push(c) }

    completes = @events.select { |e, _| e == :block_complete }
    assert_equal 1, completes.length
    assert_equal :command, completes.first[1].type
    assert_equal "hi", completes.first[1].content
  end
end
