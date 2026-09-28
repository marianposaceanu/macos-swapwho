# frozen_string_literal: true

module Chart
  begin
    require "ascii_chart"
    AVAILABLE = true
  rescue LoadError
    AVAILABLE = false
  end

  # Always exactly `rows` lines, so the layout below the plot never shifts.
  def self.render(values, width:, rows:)
    lines =
      if !AVAILABLE
        ["  no plot: gem install ascii_chart"]
      elsif values.empty?
        ["  collecting samples..."]
      else
        # Leave room for the y-axis label and offset inside the canvas.
        values = values.last([width - 18, 8].max)
        plot = if values.uniq.one?
          # The gem raises on flat series; keep these on the plot floor.
          "#{format('%8.0f ', values.first)}┼#{'─' * [values.size - 1, 0].max}"
        else
          AsciiChart.plot(values.map(&:to_f), height: rows - 2, offset: 2, format: "%8.0f ")
        end
        plot.lines(chomp: true).map { |l| "  #{l}" }
      end
    lines = lines.first(rows)
    Array.new(rows - lines.size, "") + lines
  end
end
