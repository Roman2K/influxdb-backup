require 'minitest/autorun'
require_relative 'main'

class CmdsTest < Minitest::Test
  def test_retry_err
    log = Utils::Log.new["retry_err_test"]
    runs = []

    runs.clear
    Cmds.retry_err /some_err/, log do |attempt|
      runs << attempt
    end
    assert_equal [1], runs

    runs.clear
    assert_raises RuntimeError do
      Cmds.retry_err /some_err/, log do |attempt|
        runs << attempt
        raise "xx some_err xx"
      end
    end
    assert_equal [1], runs

    runs.clear
    assert_raises Cmds::ExecError do
      Cmds.retry_err /some_err/, log do |attempt|
        runs << attempt
        raise Cmds::ExecError.new("foo", err: "xx some_err xx")
      end
    end
    assert_equal [1,2], runs

    runs.clear
    Cmds.retry_err /some_err/, log do |attempt|
      runs << attempt
      raise Cmds::ExecError.new("foo", err: "xx some_err xx") if attempt == 1
    end
    assert_equal [1,2], runs
  end
end
