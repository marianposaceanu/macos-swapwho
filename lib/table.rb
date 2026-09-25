# frozen_string_literal: true

require "io/console"

# Rounded box-drawing tables that fit the terminal.
#
#   Table.width                       -> usable terminal columns
#   Table.render(headers, rows, ...)  -> String, a complete table
#   Table::Live.new(headers, ...)     -> header now, rows as they arrive, close at the end
#
# Columns are sized from their content. When the table is wider than the terminal the
# indices listed in `optional:` are dropped in order, and only then is the `flex:`
# column (default: the last) shrunk, its cells ending in an ellipsis. `align:` takes
# one :left / :right per column; numeric-looking columns default to right.
module Table
  CORNERS = { tl: "╭", tr: "╮", bl: "╰", br: "╯" }.freeze
  H = "─"
  V = "│"
  ELLIPSIS = "…"

  def self.width
    cols = begin
      IO.console&.winsize&.last
    rescue StandardError
      nil
    end
    cols ||= ENV.fetch("COLUMNS", "80").to_i
    cols = 80 if cols < 40
    cols - 1 # never write into the last column; some terminals wrap on it
  end

  def self.fit(str, n)
    str = str.to_s
    return str if str.size <= n
    return ELLIPSIS[0, n] if n <= 1
    "#{str[0, n - 1]}#{ELLIPSIS}"
  end

  def self.natural_widths(headers, rows)
    headers.each_index.map do |i|
      ([headers[i]] + rows.map { |r| r[i] }).map { |c| c.to_s.size }.max
    end
  end

  # Which columns survive at `total`, and how wide each is. Optional columns are
  # dropped in the order given until the rest fit; the flex column absorbs the rest.
  def self.layout(headers, rows, flex:, total:, optional: [], stretch: true)
    natural = natural_widths(headers, rows)
    keep = headers.each_index.to_a
    droppable = optional.dup
    loop do
      frame = 3 * keep.size + 1 # "│ " per column plus the closing "│"
      fixed = keep.sum { |i| i == flex ? 0 : natural[i] }
      room = total - frame - fixed
      break [keep, room] if room >= natural[flex] || droppable.empty?

      # Dropping helps only while the flex column is still below a readable width.
      break [keep, room] if room >= [natural[flex], headers[flex].size + 8].min

      keep -= [droppable.shift]
    end => [keep, room]
    flex_width = [room, headers[flex].size].max
    flex_width = [flex_width, natural[flex]].min unless stretch
    widths = keep.to_h { |i| [i, i == flex ? flex_width : natural[i]] }
    [keep, widths]
  end

  def self.default_align(headers, rows)
    headers.each_index.map do |i|
      sample = rows.map { |r| r[i] }.reject { |c| c.to_s.strip.empty? }.first
      sample.to_s.match?(/\A\s*[-+]?[\d.,]+\s*(%|[KMGT]?B)?\s*\z/) ? :right : :left
    end
  end

  def self.cell(value, w, align)
    s = fit(value, w)
    align == :right ? s.rjust(w) : s.ljust(w)
  end

  def self.line(left, mid, right, widths)
    left + widths.map { |w| H * (w + 2) }.join(mid) + right
  end

  def self.row(cells, widths, aligns)
    V + cells.each_with_index.map { |c, i| " #{cell(c, widths[i], aligns[i])} " }.join(V) + V
  end

  def self.render(headers, rows, flex: nil, align: nil, optional: [], stretch: true, width: Table.width)
    flex ||= headers.size - 1
    keep, widths = layout(headers, rows, flex: flex, total: width, optional: optional, stretch: stretch)
    aligns = align || default_align(headers, rows)
    ws = keep.map { |i| widths[i] }
    out = []
    out << line(CORNERS[:tl], "┬", CORNERS[:tr], ws)
    out << row(keep.map { |i| headers[i] }, ws, keep.map { :left })
    out << line("├", "┼", "┤", ws)
    rows.each { |r| out << row(keep.map { |i| r[i] }, ws, keep.map { |i| aligns[i] }) }
    out << line(CORNERS[:bl], "┴", CORNERS[:br], ws)
    out.join("\n")
  end

  # A table whose rows arrive over time. Column widths come from `sample`, a row
  # of the widest values expected, so the header can be drawn before any data.
  class Live
    def initialize(headers, sample:, flex: nil, align: nil, optional: [], stretch: true, width: Table.width)
      flex ||= headers.size - 1
      @keep, widths = Table.layout(headers, [sample], flex: flex, total: width, optional: optional, stretch: stretch)
      @headers = headers
      @widths = @keep.map { |i| widths[i] }
      aligns = align || Table.default_align(headers, [sample])
      @aligns = @keep.map { |i| aligns[i] }
      @open = false
    end

    def open
      puts Table.line(CORNERS[:tl], "┬", CORNERS[:tr], @widths)
      puts Table.row(@keep.map { |i| @headers[i] }, @widths, @keep.map { :left })
      puts Table.line("├", "┼", "┤", @widths)
      @open = true
      $stdout.flush
    end

    def <<(cells)
      open unless @open
      puts Table.row(@keep.map { |i| cells[i] }, @widths, @aligns)
      $stdout.flush
      self
    end

    def close
      return unless @open
      puts Table.line(CORNERS[:bl], "┴", CORNERS[:br], @widths)
      @open = false
    end
  end
end
