#!/usr/bin/env ruby
# frozen_string_literal: true

# swapchurn: is swap actually hurting right now?
#
# Samples vm_stat and shows swap-ins, swap-outs, compressions and decompressions
# per second against the current swap-file and compressor sizes. Swapped pages
# that nobody touches cost nothing; sustained swap-ins are what make a machine
# feel slow, so the swap-in rate is plotted and drives the verdict.
#
#   swapchurn                  live view, sampling twice a second
#   swapchurn -i 2             sample every 2 s
#   swapchurn -P compressor    start the plot on another metric
#   swapchurn -c 6             print six samples and exit, no full-screen view
#   swapchurn --once           one sample, for scripts and pipes
#
# In the live view: q quits, r samples immediately, p cycles the plotted series.

require "optparse"
require_relative "lib/table"
require_relative "lib/tui"

begin
  require "ascii_chart"
  CHART = true
rescue LoadError
  CHART = false
end

opts = { interval: 0.5, count: nil, plot: nil }
parser = OptionParser.new do |o|
  o.banner = "usage: swapchurn [-i SECONDS] [-P METRIC] [-c COUNT] [--once]"
  o.on("-i", "--interval SECONDS", Float) { |v| opts[:interval] = v }
  o.on("-P", "--plot METRIC", "metric to plot first (see --list-metrics)") { |v| opts[:plot] = v }
  o.on("-c", "--count COUNT", Integer, "print COUNT samples and exit") { |v| opts[:count] = v }
  o.on("--once", "print a single sample and exit") { opts[:count] = 1 }
  o.on("--list-metrics", "print the metric names -P accepts") { opts[:list] = true }
end

parser.parse!
PAGE = `sysctl -n hw.pagesize`.to_i
HISTORY = 240
# The plot keeps a constant height so the table below it never moves, whether
# the series is flat, empty, or swinging. On a window too short for both, the
# table shrinks first and the plot is dropped only when even that is not enough.
PLOT_ROWS = 11
MIN_PLOT_ROWS = 4
TABLE_BORDERS = 4
COLUMNS = %w[time swapin/s swapout/s compr/s decompr/s free compressor swap verdict].freeze
SAMPLE_ROW = ["23:59:59", "99999", "99999", "999999", "999999", "9999 MB", "99999 MB", "9999 MB", "heavy"].freeze
OPTIONAL = [3, 4, 5, 7].freeze

LEGEND = "verdict, from the swap-in rate: quiet under 5/s, light under 100/s, heavy above."

# The verdict follows swap-ins, but on a quiet machine that line is flat, so the
# plot can be switched to whichever series is actually moving, with -P or with p.
SERIES = [
  { name: "swapin", key: :ins, label: "swap-ins per second" },
  { name: "swapout", key: :outs, label: "swap-outs per second" },
  { name: "compr", key: :compr, label: "compressions per second" },
  { name: "decompr", key: :decompr, label: "decompressions per second" },
  { name: "compressor", key: :compressor_mb, label: "compressor, MB of RAM" },
  { name: "swap", key: :swap_used_mb, label: "swap file in use, MB" },
  { name: "free", key: :free_mb, label: "free memory, MB" }
].freeze
SERIES_NAMES = SERIES.map { |s| s[:name] }.freeze
ADVICE = {
  quiet: "Swap is parked. Nothing is paging in, so it is costing you nothing.",
  light: "Some paging, probably not what you feel.",
  heavy: "The working set does not fit. Find the owner with: swapwho -g"
}.freeze

if opts[:list]
  SERIES.each { |s| puts format("  %-11s %s", s[:name], s[:label]) }
  exit
end

start_series = 0
if opts[:plot]
  start_series = SERIES_NAMES.index(opts[:plot])
  unless start_series
    warn "swapchurn: unknown metric #{opts[:plot].inspect}; expected one of #{SERIES_NAMES.join(', ')}"
    exit 1
  end
end

def counters
  vm = `vm_stat`
  grab = ->(label) { vm[/#{Regexp.escape(label)}:\s+(\d+)/, 1].to_i }
  {
    swapins: grab["Swapins"],
    swapouts: grab["Swapouts"],
    compressions: grab["Compressions"],
    decompressions: grab["Decompressions"],
    compressor_mb: grab["Pages occupied by compressor"] * PAGE / 1024 / 1024,
    stored_mb: grab["Pages stored in compressor"] * PAGE / 1024 / 1024,
    free_mb: grab["Pages free"] * PAGE / 1024 / 1024
  }
end

def swap_usage
  s = `sysctl -n vm.swapusage`
  { used_mb: s[/used = ([\d.]+)M/, 1].to_f.round, total_mb: s[/total = ([\d.]+)M/, 1].to_f.round }
end

def verdict(ins, outs)
  return :quiet if ins < 5 && outs < 5
  return :light if ins < 100

  :heavy
end

def gb(mb) = mb >= 1024 ? format("%.1f GB", mb / 1024.0) : "#{mb} MB"

# A sample is the difference between two readings, so the caller holds the
# previous counters and the time they were taken, and gets both back. Rates use
# the real elapsed time: pressing a key redraws early, and dividing by the
# nominal interval would understate every rate in that shorter tick.
def take(prev, prev_at)
  cur = counters
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  seconds = [now - prev_at, 0.05].max
  rate = ->(key) { (cur[key] - prev[key]) / seconds }
  sample = {
    at: Time.now,
    ins: rate[:swapins], outs: rate[:swapouts],
    compr: rate[:compressions], decompr: rate[:decompressions],
    free_mb: cur[:free_mb], compressor_mb: cur[:compressor_mb], stored_mb: cur[:stored_mb],
    swap: swap_usage
  }
  [sample.merge(state: verdict(sample[:ins], sample[:outs])), cur, now]
end

def row_for(s)
  [s[:at].strftime("%H:%M:%S"), s[:ins].round.to_s, s[:outs].round.to_s,
   s[:compr].round.to_s, s[:decompr].round.to_s,
   "#{s[:free_mb]} MB", "#{s[:compressor_mb]} MB", "#{s[:swap][:used_mb]} MB", s[:state].to_s]
end

def series_values(history, key)
  return history.map { |s| s[:swap][:used_mb] } if key == :swap_used_mb

  history.map { |s| s[key] }
end

# Always exactly `rows` lines, so the layout below the plot never shifts.
def chart(values, width:, rows:)
  lines =
    if !CHART
      ["  no plot: gem install ascii_chart"]
    elsif values.empty?
      ["  collecting samples..."]
    else
      # ascii_chart draws the y-axis label inside the canvas, so the visible
      # width is the sample count plus the label and the offset.
      values = values.last([width - 18, 8].max)
      plot = if values.uniq.one?
        # A flat series makes the gem raise, and it belongs on the floor of the
        # plot area rather than wherever a one-line render would put it.
        "#{format('%8.0f ', values.first)}┼#{'─' * [values.size - 1, 0].max}"
      else
        AsciiChart.plot(values.map(&:to_f), height: rows - 2, offset: 2, format: "%8.0f ")
      end
      plot.lines(chomp: true).map { |l| "  #{l}" }
    end
  lines = lines.first(rows)
  Array.new(rows - lines.size, "") + lines
end

def headline(sample, width)
  sw = sample[:swap]
  [
    format("swap file   %s of %s used", gb(sw[:used_mb]), gb(sw[:total_mb])),
    format("compressor  %s of RAM holding %s of pages", gb(sample[:compressor_mb]), gb(sample[:stored_mb])),
    format("verdict     %s, %s", sample[:state], ADVICE[sample[:state]])
  ].map { |l| "  #{TUI.fit(l, width - 2)}" }.join("\n")
end

# --- plain output, for pipes, --once and -c ---------------------------------
unless TUI.interactive? && opts[:count].nil?
  puts LEGEND
  table = Table::Live.new(COLUMNS, sample: SAMPLE_ROW, flex: 8, optional: OPTIONAL)
  seen = []
  finish = lambda do
    table.close
    next if seen.empty?

    puts
    seen.each { |st| puts format("%-6s %s", st, ADVICE[st]) }
  end
  %w[INT TERM].each do |sig|
    trap(sig) do
      finish.call
      exit
    end
  end

  prev = counters
  prev_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  n = 0
  loop do
    sleep opts[:interval]
    sample, prev, prev_at = take(prev, prev_at)
    seen << sample[:state] unless seen.include?(sample[:state])
    table << row_for(sample)
    n += 1
    break if opts[:count] && n >= opts[:count]
  end
  finish.call
  exit
end

# --- live view --------------------------------------------------------------
history = []
prev = counters
prev_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

series = start_series

TUI.run(interval: opts[:interval]) do |screen, action|
  series = (series + 1) % SERIES.size if action == :plot
  screen.keys("p" => :plot)
  screen.footer("  [q] Quit  [r] Sample now  [p] Plot: #{SERIES[series][:label]}" \
                "  [+/-] every #{screen.interval_label}")
  screen.frame do |body_rows, width|
    sample, prev, prev_at = take(prev, prev_at)
    history << sample
    history.shift while history.size > HISTORY

    head = [
      TUI.fit("swapchurn   #{sample[:at].strftime('%H:%M:%S')}", width),
      "",
      *headline(sample, width).lines(chomp: true),
      ""
    ]
    # Lay the sections out from what is actually left rather than from a
    # guessed overhead, so a short window trims a row instead of cutting the
    # table's bottom border off.
    plot_rows = PLOT_ROWS
    plot_rows = body_rows - head.size - TABLE_BORDERS - 2 - 2 if body_rows - head.size - TABLE_BORDERS - 2 - 2 < plot_rows
    plot = if plot_rows >= MIN_PLOT_ROWS
      ["  #{TUI.fit("#{SERIES[series][:label]}, newest at right", width - 2)}",
       *chart(series_values(history, SERIES[series][:key]), width: width, rows: plot_rows),
       ""]
    else
      []
    end
    table_rows = [body_rows - head.size - plot.size - TABLE_BORDERS, 1].max

    [*head, *plot,
     Table.render(COLUMNS, history.last(table_rows).map { |s| row_for(s) },
                  flex: 8, optional: OPTIONAL, stretch: false, width: width)].join("\n")
  end
end
