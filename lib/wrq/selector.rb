# frozen_string_literal: true

require_relative "../tui"
require_relative "search"

module Wrq
  # Interactive, read-only paper selector. It renders to stderr by default and
  # returns an action Hash; opening files and mutating the library belong to the
  # command layer.
  class Selector
    include Tui::Helpers

    attr_reader :query, :cursor_position

    def initialize(
      records,
      query: "",
      io: $stderr,
      input: $stdin,
      test_keys: nil,
      render_once: false,
      test_render_once: nil,
      width: nil,
      height: nil,
      no_alt_screen: false,
      test_no_cls: nil,
      now: Time.now
    )
      @records = records ? records.to_a : []
      @io = io
      @input = input
      @query_input = Tui::InputField.new(placeholder: "title, author, venue, tag, or arXiv ID", text: query.to_s)
      @query = @query_input.text
      @cursor_position = 0
      @scroll_offset = 0
      @search = Search.new(@records, now: now)
      @test_keys = test_keys ? test_keys.dup : nil
      @had_test_keys = @test_keys && !@test_keys.empty?
      @render_once = test_render_once.nil? ? render_once : test_render_once
      @fixed_width = positive_integer(width)
      @fixed_height = positive_integer(height)
      @no_alt_screen = test_no_cls.nil? ? no_alt_screen : test_no_cls
      @needs_redraw = false
      @old_winch_handler = nil
      @terminal_setup = false
    end

    def run
      setup_terminal

      if @render_once && (!@test_keys || @test_keys.empty?)
        current = results
        render(current)
        return { action: :render, query: @query_input.text, results: current }
      end

      unless interactive? || @had_test_keys
        message = "wrq requires an interactive terminal"
        @io.puts("Error: #{message}")
        return { action: :error, message: message }
      end

      if interactive?
        with_raw_tty { main_loop }
      else
        main_loop
      end
    ensure
      restore_terminal
    end

    def results
      @query = @query_input.text
      @search.call(@query)
    end

    def render(current_results = results)
      height, width = terminal_size
      screen = Tui::Screen.new(io: @io, width: width, height: height)

      line = screen.header.add_line
      line.write.write(Tui::Text.accent("wrq")).write("  Research papers")

      line = screen.header.add_line
      line.write.write_dim(fill("─"))

      line = screen.header.add_line
      prefix = "Search: "
      line.write.write_dim(prefix)
      display_input = screen.input(
        "title, author, venue, tag, or arXiv ID",
        value: @query_input.text,
        cursor: @query_input.cursor
      )
      line.write.write(display_input.to_s)
      line.mark_has_input(Tui::Metrics.visible_width(prefix))

      line = screen.header.add_line
      line.write.write_dim(fill("─"))

      line = screen.footer.add_line
      line.write.write_dim(fill("─"))
      line = screen.footer.add_line
      line.center.write_dim("↑/↓ or ^P/^N: Navigate  Enter: Select  Esc: Cancel")

      visible_rows = [height - screen.header.lines.length - screen.footer.lines.length, 1].max
      keep_cursor_in_bounds(current_results.length)
      adjust_scroll(current_results.length, visible_rows)

      if current_results.empty?
        line = screen.body.add_line
        line.center.write_dim(@query_input.text.empty? ? "No papers in the library" : "No matching papers")
      else
        last = [@scroll_offset + visible_rows, current_results.length].min
        index = @scroll_offset
        while index < last
          render_result(screen, current_results[index], index == @cursor_position)
          index += 1
        end
      end

      screen.flush
      current_results
    end

    private

    def main_loop
      loop do
        current = results
        keep_cursor_in_bounds(current.length)
        render(current)

        key = read_key
        next if key.nil?

        before = @query_input.text
        if @query_input.handle_key(key)
          if @query_input.text != before
            @cursor_position = 0
            @scroll_offset = 0
          end
          next
        end

        case key
        when "\e[A", "\eOA", "\x10"
          @cursor_position -= 1 if @cursor_position > 0
        when "\e[B", "\eOB", "\x0e"
          @cursor_position += 1 if @cursor_position + 1 < current.length
        when "\r", "\n"
          if current[@cursor_position]
            selected = current[@cursor_position]
            return { action: :select, record: selected.record, result: selected }
          end
        when "\e", "\x03"
          return { action: :cancel }
        end
      end
    end

    def render_result(screen, result, selected)
      background = selected ? Tui::Palette::SELECTED_BG + Tui::Palette::SELECTED_FG : nil
      line = screen.body.add_line(background)
      line.write.write(selected ? Tui::Text.highlight("→ ") + selected_foreground : "  ")
      title = Search.title(result.record)
      title = Search.canonical_id(result.record) if title.empty?
      title = "Untitled paper" if title.empty?
      line.write.write(highlight_title(title, result.highlight_positions, selected))

      metadata = row_metadata(result.record)
      line.right.write(selected ? metadata : Tui::Text.dim(metadata)) unless metadata.empty?
    end

    def highlight_title(title, positions, selected)
      return title if positions.nil? || positions.empty?

      result = String.new
      index = 0
      while index < title.length
        if positions.include?(index)
          start = index
          index += 1
          index += 1 while index < title.length && positions.include?(index)
          result << Tui::Text.highlight(title[start...index])
          result << selected_foreground if selected
        else
          result << title[index]
          index += 1
        end
      end
      result
    end

    def row_metadata(record)
      parts = []
      authors = Search.author_names(record)
      parts << compact_authors(authors) unless authors.empty?

      venue = Search.text_value(Search.value(record, :venue, :conference, :journal_ref)).strip
      year = Search.value(record, :year, :venue_year, :publication_year)
      year = year_from(Search.value(record, :published_at, :published, :publication_date)) if year.nil? || year.to_s.empty?

      year_text = year.to_s
      year_text = "" if !year_text.empty? && venue.include?(year_text)
      venue_and_year = [venue, year_text].reject { |part| part.empty? }.join(" ")
      parts << venue_and_year unless venue_and_year.empty?

      status = Search.value(record, :status, :reading_status)
      status = "unread" if status.nil? || status.to_s.empty?
      parts << status.to_s
      parts.join(" · ")
    end

    def compact_authors(authors)
      return authors[0] if authors.length == 1
      return authors.join(", ") if authors.length == 2

      "#{authors[0]} et al."
    end

    def year_from(value)
      match = /\A(\d{4})/.match(value.to_s)
      match ? match[1] : ""
    end

    def selected_foreground
      Tui.colors_enabled? ? Tui::Palette::SELECTED_FG : ""
    end

    def keep_cursor_in_bounds(length)
      if length <= 0
        @cursor_position = 0
      elsif @cursor_position >= length
        @cursor_position = length - 1
      elsif @cursor_position < 0
        @cursor_position = 0
      end
    end

    def adjust_scroll(length, visible_rows)
      if length <= visible_rows
        @scroll_offset = 0
      elsif @cursor_position < @scroll_offset
        @scroll_offset = @cursor_position
      elsif @cursor_position >= @scroll_offset + visible_rows
        @scroll_offset = @cursor_position - visible_rows + 1
      end
    end

    def terminal_size
      rows = @fixed_height || positive_integer(ENV["WRQ_HEIGHT"])
      columns = @fixed_width || positive_integer(ENV["WRQ_WIDTH"])

      [@io, @input, $stdout].compact.uniq.each do |stream|
        break if rows && columns
        next unless stream.respond_to?(:winsize)

        begin
          found_rows, found_columns = stream.winsize
          rows ||= positive_integer(found_rows)
          columns ||= positive_integer(found_columns)
        rescue IOError, Errno::ENOTTY, Errno::EOPNOTSUPP, Errno::ENODEV
        end
      end

      [rows || 24, columns || 80]
    end

    def positive_integer(value)
      number = value.to_i
      number > 0 ? number : nil
    rescue NoMethodError
      nil
    end

    def interactive?
      if defined?(RubyVM)
        @input.respond_to?(:tty?) && @input.tty? &&
          @io.respond_to?(:tty?) && @io.tty?
      else
        @input.is_a?(IO) && @input.tty? && @io.is_a?(IO) && @io.tty?
      end
    end

    def setup_terminal
      return if @terminal_setup

      @terminal_setup = true
      install_resize_handler if interactive?
      return if @no_alt_screen || !interactive?

      @io.print(Tui::ANSI::ALT_SCREEN_ON)
      @io.print(Tui::ANSI.set_title("wrq"))
      @io.print(Tui::ANSI::CURSOR_BLINK)
      @io.flush
      @alternate_screen = true
    rescue IOError
    end

    def restore_terminal
      return unless @terminal_setup

      if @alternate_screen
        begin
          @io.print(Tui::ANSI::RESET)
          @io.print(Tui::ANSI::CURSOR_DEFAULT)
          @io.print(Tui::ANSI::SHOW)
          @io.print(Tui::ANSI::ALT_SCREEN_OFF)
          @io.flush
        rescue IOError
        end
      end

      restore_resize_handler
      @terminal_setup = false
    end

    def install_resize_handler
      return if defined?(RUBY_ENGINE) && RUBY_ENGINE == "spinel"
      return unless Signal.list.key?("WINCH")

      @old_winch_handler = Signal.trap("WINCH") { @needs_redraw = true }
    rescue ArgumentError
      @old_winch_handler = nil
    end

    def restore_resize_handler
      return unless @old_winch_handler

      Signal.trap("WINCH", @old_winch_handler)
      @old_winch_handler = nil
    rescue ArgumentError
      @old_winch_handler = nil
    end

    def with_raw_tty
      raw = interactive? && system("stty", "raw", "-echo")
      yield
    ensure
      system("stty", "sane") if raw
    end

    def read_key
      if @test_keys && !@test_keys.empty?
        return normalize_test_key(@test_keys.shift)
      end
      return "\e" if @had_test_keys && @test_keys && @test_keys.empty?

      loop do
        if @needs_redraw
          @needs_redraw = false
          return nil
        end

        ready = IO.select([@input], nil, nil, 0.1)
        return read_keypress if ready
      end
    end

    def normalize_test_key(key)
      case key
      when :up then "\e[A"
      when :down then "\e[B"
      when :ctrl_p then "\x10"
      when :ctrl_n then "\x0e"
      when :enter then "\r"
      when :escape, :esc, :cancel then "\e"
      when :backspace then "\x7f"
      else key.to_s
      end
    end

    def read_keypress
      key = @input.getc
      return nil if key.nil?
      return key unless key == "\e"

      begin
        following = @input.read_nonblock(1)
        key << following
        if following == "["
          loop do
            character = @input.read_nonblock(1)
            key << character
            code = character.ord
            break if code >= 0x40 && code <= 0x7e
          end
        elsif following == "O"
          key << @input.read_nonblock(1)
        end
      rescue IO::WaitReadable, EOFError, Errno::EAGAIN, Errno::EWOULDBLOCK
      end
      key
    end
  end
end
