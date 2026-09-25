#!/usr/bin/env ruby
# frozen_string_literal: true

# swapwho: which processes hold memory that is out of RAM, and what share of it.
#
# macOS does not expose per-process "bytes on the swap file". What it does expose,
# through footprint(1) and vmmap(1), is each process's anonymous memory that is not
# resident: pages sitting in the compressor or written to /private/var/vm. This
# script sums that per process (or per app name) and reports each one's share of
# the total, next to the system-wide compressor and swap-file figures from the
# kernel so the two views can be compared.
#
#   swapwho              live view, refreshing every 10 s
#   swapwho -g           start grouped by executable name (Safari's helpers add up)
#   swapwho --once       print one report and exit, for scripts and pipes
#   swapwho -j 12        more parallel workers (default 8)
#   sudo swapwho         include other users' and system processes
#
# In the live view: q quits, r measures again, g toggles grouping.
# Only processes owned by the invoking user can be examined without root.

require "json"
require "optparse"
require "tempfile"
require_relative "lib/table"
require_relative "lib/tui"

opts = { rows: 20, group: false, jobs: 8, min_kb: 1024, interval: 10, once: false }
OptionParser.new do |o|
  o.banner = "usage: swapwho [-g] [-n ROWS] [-j JOBS] [-m MIN_MB] [-i SECONDS] [--once]"
  o.on("-g", "--group", "group by executable name") { opts[:group] = true }
  o.on("-n", "--rows ROWS", Integer, "rows to show when printing once (default 20)") { |v| opts[:rows] = v }
  o.on("-j", "--jobs JOBS", Integer, "parallel workers (default 8)") { |v| opts[:jobs] = v }
  o.on("-m", "--min MIN_MB", Float, "hide entries below this many MB (default 1)") { |v| opts[:min_kb] = (v * 1024).to_i }
  o.on("-i", "--interval SECONDS", Float, "live refresh interval (default 10)") { |v| opts[:interval] = v }
  o.on("--once", "print one report and exit") { opts[:once] = true }
end.parse!

PAGE = `sysctl -n hw.pagesize`.to_i
ME = Process.uid

def human(kb)
  return format("%.1f GB", kb / 1024.0 / 1024.0) if kb >= 1024 * 1024

  format("%.0f MB", kb / 1024.0)
end

# vmmap prints sizes like 395.8M, 1.2G, 5936K, 0K.
def to_kb(token)
  num = token.to_f
  case token[-1]
  when "G" then (num * 1024 * 1024).round
  when "M" then (num * 1024).round
  when "K" then num.round
  else (num / 1024).round
  end
end

def kernel_view
  swap = `sysctl -n vm.swapusage`
  vm = `vm_stat`
  page_kb = ->(label) { vm[/#{Regexp.escape(label)}:\s+(\d+)/, 1].to_i * PAGE / 1024 }
  {
    swap_total_kb: swap[/total = ([\d.]+)M/, 1].to_f * 1024,
    swap_used_kb: swap[/used = ([\d.]+)M/, 1].to_f * 1024,
    compressor_kb: page_kb["Pages occupied by compressor"],
    # Per-process SWAPPED counts uncompressed pages, so the comparable system
    # figure is what the compressor holds, not the RAM or disk it occupies.
    out_of_ram_kb: page_kb["Pages stored in compressor"]
  }
end

# --- measurement ------------------------------------------------------------
# footprint(1) reports the same per-process swapped/compressed figure as vmmap but
# takes many pids per call and returns JSON, so a full pass is about thirty times
# faster. vmmap remains as a fallback for systems where footprint is unavailable.
HAVE_FOOTPRINT = system("which footprint", out: File::NULL, err: File::NULL)

def footprint_batch(batch)
  Tempfile.create(["swapwho", ".json"]) do |f|
    args = batch.flat_map { |pr| ["-p", pr[:pid].to_s] }
    system("footprint", *args, "--swapped", "-j", f.path, out: File::NULL, err: File::NULL)
    data = File.size?(f.path) ? JSON.parse(File.read(f.path)) : { "processes" => [] }
    by_pid = batch.to_h { |pr| [pr[:pid], pr] }
    data.fetch("processes", []).filter_map do |proc_data|
      pr = by_pid[proc_data["pid"]] or next

      cats = proc_data.fetch("categories", {}).values
      pr.merge(swapped_kb: cats.sum { |c| c.fetch("swapped", 0) } / 1024,
               resident_kb: pr[:rss_kb])
    end
  end
end

def vmmap_one(pr)
  total = `vmmap --summary #{pr[:pid]} 2>/dev/null`.lines.find { |l| l.start_with?("TOTAL ") }
  return unless total

  cols = total.split
  return if cols.size < 5

  pr.merge(resident_kb: to_kb(cols[2]), swapped_kb: to_kb(cols[4]))
end

def processes
  `ps -axo pid=,uid=,rss=,comm=`.lines.filter_map do |l|
    pid, uid, rss, comm = l.strip.split(/\s+/, 4)
    next if pid.to_i == Process.pid
    next if ME != 0 && uid.to_i != ME

    { pid: pid.to_i, rss_kb: rss.to_i, name: File.basename(comm.to_s) }
  end
end

def measure(jobs:)
  procs = processes
  units = HAVE_FOOTPRINT ? procs.each_slice(100).to_a : procs.map { |pr| [pr] }
  queue = Queue.new
  units.each { |u| queue << u }
  results = Queue.new
  Array.new(jobs) do
    Thread.new do
      loop do
        unit = begin
          queue.pop(true)
        rescue ThreadError
          nil
        end
        break unless unit

        if HAVE_FOOTPRINT
          footprint_batch(unit).each { |r| results << r }
        else
          r = vmmap_one(unit.first)
          results << r if r
        end
      end
    end
  end.each(&:join)

  rows = []
  rows << results.pop until results.empty?
  rows
end

def grouped(rows)
  rows.group_by { |r| r[:name] }.map do |name, rs|
    { name: name, pid: rs.size,
      resident_kb: rs.sum { |r| r[:resident_kb] }, swapped_kb: rs.sum { |r| r[:swapped_kb] } }
  end
end

FOOTNOTE = [
  "%sum     share of the swapped memory found across examined processes.",
  "%system  share of the kernel's out-of-RAM page total. Shared pages (dyld cache,",
  "         WebKit shared memory) are counted once per process that maps them, so",
  "         groups of helpers can exceed 100%; single processes are accurate."
].freeze

def report(measured, kernel, group:, limit:, min_kb:, width:, footnote: true)
  rows = group ? grouped(measured) : measured
  sum_kb = rows.sum { |r| r[:swapped_kb] }
  shown = rows.select { |r| r[:swapped_kb] >= min_kb }.sort_by { |r| -r[:swapped_kb] }.first(limit)

  table = Table.render(
    ["swapped", "resident", "%sum", "%system", group ? "procs" : "pid", "name"],
    shown.map do |r|
      [human(r[:swapped_kb]), human(r[:resident_kb]),
       format("%.1f%%", sum_kb.zero? ? 0 : 100.0 * r[:swapped_kb] / sum_kb),
       format("%.1f%%", kernel[:out_of_ram_kb].zero? ? 0 : 100.0 * r[:swapped_kb] / kernel[:out_of_ram_kb]),
       r[:pid].to_s, r[:name]]
    end,
    # Narrow terminals lose %sum first, then resident, then %system: the name
    # and the swapped size are what the report is for.
    flex: 5, optional: [2, 1, 3], width: width
  )

  head = [
    "  swap file   #{human(kernel[:swap_used_kb])} of #{human(kernel[:swap_total_kb])} used",
    "  compressor  #{human(kernel[:compressor_kb])} of RAM holding #{human(kernel[:out_of_ram_kb])} of pages",
    "  examined    #{measured.size} processes#{ME.zero? ? '' : ' (yours only; sudo for all)'}, " \
    "holding #{human(sum_kb)} of out-of-RAM pages"
  ].map { |l| TUI.fit(l, width) }

  ([*head, "", table] + (footnote ? ["", *FOOTNOTE] : [])).join("\n")
end

# --- one-shot ---------------------------------------------------------------
if opts[:once] || !TUI.interactive?
  kernel = kernel_view
  puts report(measure(jobs: opts[:jobs]), kernel,
              group: opts[:group], limit: opts[:rows], min_kb: opts[:min_kb], width: Table.width)
  exit
end

# --- live view --------------------------------------------------------------
# A pass over every process takes a second or two, so it runs only on a tick or
# on r. Toggling the grouping re-renders the measurement already in hand, which
# is what makes the key feel instant.
group = opts[:group]
snapshot = nil
measuring = false

TUI.run(interval: opts[:interval]) do |screen, action|
  group = !group if action == :group
  screen.keys("g" => :group)
  screen.footer("  [q] Quit  [r] Measure now  [g] #{group ? 'Per process' : 'Group by app'}" \
                "  [+/-] every #{screen.interval_label}")
  screen.frame do |body_rows, width|
    title = if snapshot
      "swapwho   #{snapshot[:at].strftime('%H:%M:%S')}   #{measuring ? 'measuring...' : format('measured in %.1fs', snapshot[:took])}"
    else
      "swapwho   measuring..."
    end
    body = if snapshot
      # title, blank, three header lines, blank, four table borders.
      report(snapshot[:measured], snapshot[:kernel], group: group, limit: [body_rows - 10, 1].max,
             min_kb: opts[:min_kb], width: width, footnote: false)
    else
      "  reading #{HAVE_FOOTPRINT ? 'footprint' : 'vmmap'} for every process..."
    end
    [TUI.fit(title, width), "", body].join("\n")
  end

  next unless snapshot.nil? || action.nil? || action == :refresh

  measuring = true
  screen.draw
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  kernel = kernel_view
  measured = measure(jobs: opts[:jobs])
  snapshot = { at: Time.now, kernel: kernel, measured: measured,
               took: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
  measuring = false
end
