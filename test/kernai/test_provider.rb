require_relative "../test_helper"

class TestProvider < Minitest::Test
  include Kernai::TestHelpers

  def test_base_provider_call_raises_not_implemented_error
    provider = Kernai::Provider.new
    error = assert_raises(NotImplementedError) do
      provider.call(messages: [], model: "test")
    end
    assert_match(/Kernai::Provider#call must be implemented/, error.message)
  end

  def test_custom_subclass_can_implement_call
    custom_class = Class.new(Kernai::Provider) do
      def call(messages:, model:, &block)
        "custom response"
      end
    end

    provider = custom_class.new
    result = provider.call(messages: [{ role: "user", content: "hello" }], model: "test-model")
    assert_equal "custom response", result
  end

  def test_not_implemented_error_includes_subclass_name
    custom_class = Class.new(Kernai::Provider)

    provider = custom_class.new
    error = assert_raises(NotImplementedError) do
      provider.call(messages: [], model: "test")
    end
    assert_includes error.message, "#call must be implemented"
  end
end
