# frozen_string_literal: true

module Kernai
  class StreamParser
    OPEN_TAG_START = '<block'
    CLOSE_TAG = '</block>'
    SHORTHAND_TYPES = Block::TYPES.map(&:to_s).freeze

    # Used by locate_matching_close to count nested opens. We match any
    # `<block` token followed by whitespace or `>` — even ones embedded in
    # escaped JSON strings (`<block type=\"...\">`) — because the LLM often
    # pastes literal examples of blocks inside plan JSON payloads.
    NESTED_OPEN_LITERAL = '<block'
    NESTED_OPEN_PATTERN = /<block(?:\s|>)/.freeze

    attr_reader :state

    def initialize
      @callbacks = {}
      reset
    end

    def on(event, &block)
      @callbacks[event] = block
    end

    def push(chunk)
      @buffer << chunk
      consume
    end

    def flush
      case @state
      when :text
        # nothing to flush
      when :tag_open
        emit(:text_chunk, @tag_buffer) unless @tag_buffer.empty?
        @tag_buffer = +''
      when :block_content
        emit(:text_chunk, @content_buffer) unless @content_buffer.empty?
        @content_buffer = +''
        @full_block_content = +''
        @tag_buffer = +''
      end
      @buffer = +''
      @state = :text
    end

    def reset
      @state = :text
      @buffer = +''
      @tag_buffer = +''
      @content_buffer = +''
      @full_block_content = +''
      @current_type = nil
      @current_name = nil
      @close_tag = nil
    end

    private

    def consume
      while @buffer.length.positive?
        case @state
        when :text
          consume_text
        when :tag_open
          consume_tag_open
        when :block_content
          consume_block_content
        end
      end
    end

    def consume_text
      idx = @buffer.index('<')
      if idx.nil?
        emit(:text_chunk, @buffer) unless @buffer.empty?
        @buffer = +''
      elsif idx.positive?
        emit(:text_chunk, @buffer[0...idx])
        @buffer = @buffer[idx..]
        try_enter_tag_open
      else
        try_enter_tag_open
      end
    end

    def try_enter_tag_open
      # Check if this could be a block tag or a shorthand tag
      if could_be_block_tag? || could_be_shorthand_tag?
        @tag_buffer = +''
        @state = :tag_open
      elsif @buffer.length >= 2
        # Not a recognized tag start — emit the '<' as text
        emit(:text_chunk, @buffer[0])
        @buffer = @buffer[1..]
      else
        # Need more data to decide
        @tag_buffer = +@buffer
        @buffer = +''
        @state = :tag_open
      end
    end

    def could_be_block_tag?
      @buffer.start_with?(OPEN_TAG_START) ||
        (OPEN_TAG_START.start_with?(@buffer) && @buffer.length < OPEN_TAG_START.length)
    end

    def could_be_shorthand_tag?
      SHORTHAND_TYPES.any? do |type|
        tag = "<#{type}"
        @buffer.start_with?(tag) || (tag.start_with?(@buffer) && @buffer.length < tag.length)
      end
    end

    def consume_tag_open
      @tag_buffer << @buffer
      @buffer = +''

      close_idx = @tag_buffer.index('>')
      return unless close_idx

      opening_tag = @tag_buffer[0..close_idx]
      remainder = @tag_buffer[(close_idx + 1)..]

      # Try canonical: <block type="TYPE" name="NAME">
      if opening_tag =~ /\A<block\s+type="([^"]+)"(?:\s+name="([^"]*)")?\s*>\z/
        @current_type = Regexp.last_match(1).to_sym
        @current_name = Regexp.last_match(2)
        @close_tag = CLOSE_TAG

        emit(:block_start, { type: @current_type, name: @current_name })

        @content_buffer = +''
        @full_block_content = +''
        @tag_buffer = +''
        @state = :block_content
        @buffer = remainder
        return
      end

      # Try shorthand: <final>, <command name="skill">, etc.
      shorthand_re = /\A<(#{SHORTHAND_TYPES.join('|')})(?:\s+name="([^"]*)")?\s*>\z/
      if opening_tag =~ shorthand_re
        @current_type = Regexp.last_match(1).to_sym
        @current_name = Regexp.last_match(2)
        @close_tag = "</#{@current_type}>"

        emit(:block_start, { type: @current_type, name: @current_name })

        @content_buffer = +''
        @full_block_content = +''
        @tag_buffer = +''
        @state = :block_content
        @buffer = remainder
        return
      end

      # Not a recognized tag — emit as text
      emit(:text_chunk, @tag_buffer)
      @tag_buffer = +''
      @state = :text
    end

    def consume_block_content
      @content_buffer << @buffer
      @buffer = +''

      close_idx = locate_matching_close(@content_buffer)

      if close_idx
        finalize_block_content(close_idx)
      else
        emit_safe_prefix
      end
    end

    def finalize_block_content(close_idx)
      content = @content_buffer[0...close_idx]
      remainder = @content_buffer[(close_idx + @close_tag.length)..]

      emit(:block_content, content) unless content.empty?

      full_content = @full_block_content + content
      block = Block.new(type: @current_type, content: full_content, name: @current_name)
      emit(:block_complete, block)

      @content_buffer = +''
      @full_block_content = +''
      @current_type = nil
      @current_name = nil
      @close_tag = nil
      @state = :text
      @buffer = remainder
    end

    def emit_safe_prefix
      # Keep a tail of (close_tag.length - 1) chars so we never emit a
      # partial closing tag as content.
      safe_length = @content_buffer.length - (@close_tag.length - 1)

      # For full-form </block> closes, never advance past the first
      # unresolved nested <block ...> — its own </block> might follow and
      # we'd split in the middle of it.
      if @close_tag == CLOSE_TAG
        first_nested = @content_buffer.index(NESTED_OPEN_PATTERN)
        safe_length = [safe_length, first_nested].min if first_nested
      end

      return unless safe_length.positive?

      safe_content = @content_buffer[0...safe_length]
      @full_block_content << safe_content
      @content_buffer = @content_buffer[safe_length..]
      emit(:block_content, safe_content)
    end

    # Scans the current content buffer for the close tag that actually
    # matches the currently-open block, accounting for nested <block ...>
    # occurrences that the model may have emitted inside the content (for
    # example a plan JSON containing a literal example block as a string).
    # Returns the index of the matching close tag or nil if it has not
    # been seen yet.
    def locate_matching_close(str)
      return str.index(@close_tag) unless @close_tag == CLOSE_TAG

      depth = 1
      i = 0
      while i < str.length
        open_idx = str.index(NESTED_OPEN_PATTERN, i)
        close_idx = str.index(CLOSE_TAG, i)

        return nil unless close_idx

        if open_idx && open_idx < close_idx
          depth += 1
          i = open_idx + NESTED_OPEN_LITERAL.length
        else
          depth -= 1
          return close_idx if depth.zero?

          i = close_idx + CLOSE_TAG.length
        end
      end

      nil
    end

    def emit(event, data)
      @callbacks[event]&.call(data)
    end
  end
end
