# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/wrq/selector"

class WrqSelectorTest < Minitest::Test
  def setup
    @colors_were_enabled = Tui.colors_enabled?
    Tui.disable_colors!
    @records = [
      {
        canonical_id: "1706.03762",
        title: "Attention Is All You Need",
        authors: ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar"],
        venue: "NeurIPS",
        year: 2017,
        status: "read"
      },
      {
        canonical_id: "1810.04805",
        title: "BERT",
        authors: ["Jacob Devlin"],
        venue: "NAACL",
        year: 2019,
        status: "reading"
      }
    ]
  end

  def teardown
    Tui.colors_enabled = @colors_were_enabled
  end

  def selector(keys: nil, records: @records, query: "", render_once: false, width: 120, height: 10)
    output = StringIO.new
    instance = Wrq::Selector.new(
      records,
      query: query,
      io: output,
      input: StringIO.new,
      test_keys: keys,
      render_once: render_once,
      no_alt_screen: true,
      width: width,
      height: height
    )
    [instance, output]
  end

  def test_render_once_shows_title_author_venue_year_and_status
    instance, output = selector(render_once: true)

    action = instance.run
    rendered = output.string

    assert_equal :render, action[:action]
    assert_includes rendered, "Attention Is All You Need"
    assert_includes rendered, "Ashish Vaswani et al."
    assert_includes rendered, "NeurIPS 2017"
    assert_includes rendered, "read"
  end

  def test_down_and_enter_select_without_opening_or_mutating
    original = Marshal.dump(@records)
    instance, = selector(keys: [:down, :enter])

    action = instance.run

    assert_equal :select, action[:action]
    assert_same @records[1], action[:record]
    assert_equal original, Marshal.dump(@records)
  end

  def test_ctrl_navigation_keys
    instance, = selector(keys: [:ctrl_n, :ctrl_p, :enter])

    assert_same @records[0], instance.run[:record]
  end

  def test_input_editing_preserves_spaces_and_filters
    instance, = selector(keys: ["i", "s", " ", "a", "l", "l", :enter])

    action = instance.run

    assert_equal :select, action[:action]
    assert_same @records[0], action[:record]
    assert_equal "is all", instance.query
  end

  def test_escape_returns_cancel_action
    instance, = selector(keys: [:escape])

    assert_equal({ action: :cancel }, instance.run)
  end

  def test_zero_records_renders_gracefully
    instance, output = selector(records: [], render_once: true)

    action = instance.run

    assert_equal :render, action[:action]
    assert_empty action[:results]
    assert_includes output.string, "No papers in the library"
  end

  def test_environment_size_is_used_by_selector_not_try_variables
    old_wrq_width = ENV["WRQ_WIDTH"]
    old_wrq_height = ENV["WRQ_HEIGHT"]
    old_try_width = ENV["TRY_WIDTH"]
    ENV["WRQ_WIDTH"] = "96"
    ENV["WRQ_HEIGHT"] = "9"
    ENV["TRY_WIDTH"] = "20"
    output = StringIO.new
    instance = Wrq::Selector.new(
      @records,
      io: output,
      input: StringIO.new,
      render_once: true,
      no_alt_screen: true
    )

    instance.run

    lines = output.string.split("\n")
    assert lines.any? { |line| Tui::Metrics.visible_width(line) >= 90 }
  ensure
    ENV["WRQ_WIDTH"] = old_wrq_width
    ENV["WRQ_HEIGHT"] = old_wrq_height
    ENV["TRY_WIDTH"] = old_try_width
  end

  def test_query_with_no_match_can_cancel
    instance, output = selector(query: "missing", keys: [:escape])

    assert_equal :cancel, instance.run[:action]
    assert_includes output.string, "No matching papers"
  end
end
