# frozen_string_literal: true

require "io/console"

# A full-screen, self-refreshing terminal view.
#
#   TUI.run(interval: 5) do |screen|
#     screen.frame { |height, width| build_the_text(height, width) }
#     screen.keys("r" => :refresh, "g" => :toggle)
#   end
#
# The screen is drawn into the alternate buffer, so the shell scrollback is
# untouched and the terminal is restored exactly as it was on exit. Each redraw
# homes the cursor, writes the new frame over the old one and erases whatever is
# left below, which avoids the blank flash a clear-then-write produces.
module TUI
  # Refresh intervals the + and - keys step through. A ladder rather than a
  # multiplier so the rungs stay predictable and round.
  INTERVALS = [0.25, 0.5, 1, 2, 3, 5, 10, 15, 30, 60, 120, 300].freeze

  ENTER_ALTERNATE_SCREEN = "\e[?1049h"
  LEAVE_ALTERNATE_SCREEN = "\e[?1049l"
  HIDE_CURSOR = "\e[?25l"
  SHOW_CURSOR = "\e[?25h"
  HOME = "\e[H"
  ERASE_LINE_END = "\e[K"
  ERASE_BELOW = "\e[J"

  def self.interactive?(stdin: $stdin, stdout: $stdout)
    stdin.tty? && stdout.tty?
  end

  def self.size(stdout: $stdout)
    height, width = stdout.winsize
    [height.positive? ? height : 24, width.positive? ? width : 80]
  rescue StandardError
    [24, 80]
  end

  # Truncate to the terminal width, counting characters rather than bytes so
  # box-drawing rows are not cut mid-glyph.
  def self.interval_label(seconds)
    seconds < 1 ? "#{seconds}s" : "#{seconds.round}s"
  end

  def self.fit(line, width)
    return line unless width&.positive? && line.length > width
    return line[0, width] if width < 2

    "#{line[0, width - 1]}…"
  end

  class Screen
    attr_reader :width, :height, :interval

    def initialize(interval:, stdin: $stdin, stdout: $stdout)
      @interval = interval
      @stdin = stdin
      @stdout = stdout
      @bindings = {}
      @height, @width = TUI.size(stdout: @stdout)
    end

    # The block is called with (body_rows, width) for every redraw, where
    # body_rows is exactly how many lines it may return; the footer owns the
    # bottom row and is not part of that budget.
    def frame(&block)
      @builder = block
    end

    # {"r" => :refresh, "g" => :toggle}; q, Ctrl-C, r and +/- are always bound.
    def keys(map)
      @bindings = map
    end

    # + and - step along the ladder; an interval set with -i that is not on it
    # snaps to the neighbouring rung.
    def step_interval(direction)
      index = INTERVALS.index { |v| v >= @interval - 1e-9 } || INTERVALS.size - 1
      @interval = INTERVALS[(index + direction).clamp(0, INTERVALS.size - 1)]
    end

    def interval_label = TUI.interval_label(@interval)

    def footer(text)
      @footer = text
    end

    def draw
      @height, @width = TUI.size(stdout: @stdout)
      # A frame taller than the window, or a line wider than it, makes the
      # terminal scroll; the next home-and-redraw then leaves the tail of the
      # old frame stranded above. Clamp both rather than trusting the builder,
      # then pad so the footer keeps the bottom row and nothing below the
      # growing part of a view shifts between frames.
      body = @builder.call(@height - 1, @width).split("\n", -1).first(@height - 1)
      body += [""] * (@height - 1 - body.size)
      lines = (body + [@footer.to_s]).map { |l| TUI.fit(l, @width) }
      # Each line is erased to the end before the next one starts: writing a
      # shorter line over a longer one only overwrites its own length, so
      # without this the tail of a wider frame survives a narrowing resize.
      # Raw mode turns off newline translation, so write explicit CRLFs.
      @stdout.print(HOME, lines.join("#{ERASE_LINE_END}\r\n"), ERASE_LINE_END, ERASE_BELOW)
      @stdout.flush
    end

    # Blocks until the interval elapses, a bound key is pressed, or the window
    # is resized. Returns :refresh, :quit, or the symbol bound to the key.
    def wait
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @interval
      loop do
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return :refresh unless left.positive?

        unless IO.select([@stdin], nil, nil, [left, 0.25].min)
          return :resize if TUI.size(stdout: @stdout) != [@height, @width]

          next
        end

        case key = @stdin.getc
        when "q", "Q", "" then return :quit
        when "r", "R", " " then return :refresh
        when "+", "="
          step_interval(1)
          return :interval
        when "-", "_"
          step_interval(-1)
          return :interval
        else
          action = @bindings[key.to_s.downcase]
          return action if action
        end
      end
    end
  end

  # Runs the loop until the user quits. The block receives the Screen and the
  # action that triggered it (nil the first time, then :refresh, :resize or a
  # bound key), and should set a frame builder, a footer and any key bindings.
  #
  # It is called for every action, including :refresh and :resize, so a view
  # can tell a key press apart from a tick and skip expensive work that a mere
  # redraw does not need. The screen is already live when the block first runs,
  # so a slow view can call screen.draw itself to show progress before
  # collecting anything.
  def self.run(interval:, stdin: $stdin, stdout: $stdout)
    screen = Screen.new(interval: interval, stdin: stdin, stdout: stdout)
    stdout.print(ENTER_ALTERNATE_SCREEN, HIDE_CURSOR, HOME, "\e[2J")
    stdout.flush
    begin
      stdin.raw do
        yield screen, nil
        loop do
          screen.draw
          action = screen.wait
          break if action == :quit

          yield screen, action
        end
      end
    ensure
      stdout.print(SHOW_CURSOR, LEAVE_ALTERNATE_SCREEN)
      stdout.flush
    end
  end
end
