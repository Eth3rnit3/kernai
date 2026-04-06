require_relative "../test_helper"

class TestLogger < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @output = StringIO.new
    @logger = Kernai::Logger.new(@output)
    Kernai.config.logger = @logger
  end

  def test_default_output_is_stdout
    logger = Kernai::Logger.new
    assert_equal $stdout, logger.output
  end

  def test_info_logs_message
    @logger.info("something happened")
    assert_includes logged_output, "[Kernai] INFO"
    assert_includes logged_output, "message=something happened"
  end

  def test_warn_logs_message
    @logger.warn("watch out")
    assert_includes logged_output, "[Kernai] WARN"
    assert_includes logged_output, "message=watch out"
  end

  def test_error_logs_message
    @logger.error("it broke")
    assert_includes logged_output, "[Kernai] ERROR"
    assert_includes logged_output, "message=it broke"
  end

  def test_debug_suppressed_when_debug_mode_off
    Kernai.config.debug = false
    @logger.debug("hidden")
    assert_equal "", logged_output
  end

  def test_debug_shown_when_debug_mode_on
    Kernai.config.debug = true
    @logger.debug("visible")
    assert_includes logged_output, "[Kernai] DEBUG"
    assert_includes logged_output, "message=visible"
  end

  def test_info_shown_even_when_debug_off
    Kernai.config.debug = false
    @logger.info("always visible")
    assert_includes logged_output, "[Kernai] INFO"
  end

  def test_log_with_event_data
    @logger.info("request sent", event: "llm.request", model: "gpt-4")
    output = logged_output
    assert_includes output, "message=request sent"
    assert_includes output, "event=llm.request"
    assert_includes output, "model=gpt-4"
  end

  def test_log_with_only_data_no_message
    @logger.info(event: "stream.chunk", index: 3)
    output = logged_output
    assert_includes output, "[Kernai] INFO"
    assert_includes output, "event=stream.chunk"
    assert_includes output, "index=3"
    refute_includes output, "message="
  end

  def test_event_types
    events = [
      "llm.request", "llm.response",
      "stream.chunk",
      "block.detected", "block.complete",
      "skill.execute", "skill.result",
      "agent.complete"
    ]

    events.each do |event|
      @output.truncate(0)
      @output.rewind
      @logger.info(event: event)
      assert_includes logged_output, "event=#{event}", "Expected event #{event} to be logged"
    end
  end

  def test_output_can_be_changed
    new_output = StringIO.new
    @logger.output = new_output
    @logger.info("redirected")
    assert_includes new_output.string, "redirected"
    assert_equal "", @output.string
  end

  private

  def logged_output
    @output.rewind
    @output.read
  end
end
