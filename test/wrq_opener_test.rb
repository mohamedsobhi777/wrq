# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/wrq/opener'

class WrqOpenerTest < Minitest::Test
  def test_test_hook_records_an_absolute_path
    Dir.mktmpdir('wrq-opener') do |dir|
      paper = File.join(dir, 'paper.pdf')
      log = File.join(dir, 'opened.log')
      File.binwrite(paper, "%PDF-1.4\n")

      opener = Wrq::Opener.new(env: { 'WRQ_TEST_OPEN_LOG' => log })
      assert opener.open(paper)
      assert_equal "#{File.expand_path(paper)}\n", File.read(log)
    end
  end

  def test_missing_paper_is_rejected_before_process_creation
    error = assert_raises(ArgumentError) do
      Wrq::Opener.new(env: {}).open('/definitely/missing/wrq-paper.pdf')
    end
    assert_match(/does not exist/, error.message)
  end

  def test_configured_opener_is_one_executable_not_a_shell_fragment
    opener = Wrq::Opener.new(env: { 'WRQ_OPENER' => '/usr/bin/false; echo unsafe' })
    assert_equal ['/usr/bin/false; echo unsafe'], opener.send(:command_for_platform)
  end
end
