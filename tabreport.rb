#!/usr/bin/env ruby
# frozen_string_literal: true

# tabreport: what Safari's open tabs cost, and which ones you might close.
#
# Safari runs each tab in its own helper process. By default this tool measures
# the helpers as a group, lists every open tab, and points out the usual
# suspects: duplicates, piles of tabs from one site, and windows you may have
# forgotten. With -p it also works out which helper hosts which tab and ranks
# the tabs by what each one holds. Nothing is closed; that decision stays with you.
#
#   tabreport            live view, refreshing every 10 s
#   tabreport -p         match each tab to its helper and rank tabs by memory
#   tabreport -d         start grouped by site rather than by window
#   tabreport -u         show URLs instead of titles
#   tabreport --once     print one report and exit, for scripts and pipes
#
# In the live view: q quits, r reads the tabs again, d groups by site, u shows URLs.

require "json"
require "optparse"
require "tempfile"
require "uri"
require_relative "lib/table"
require_relative "lib/tui"

opts = { by_domain: false, urls: false, interval: nil, once: false, per_tab: false }
OptionParser.new do |o|
  o.banner = "usage: tabreport [-p] [-d] [-u] [-i SECONDS] [--once]"
  o.on("-p", "--per-tab", "match each tab to its helper and rank tabs by memory") { opts[:per_tab] = true }
  o.on("-d", "--by-domain", "group tabs by site") { opts[:by_domain] = true }
  o.on("-u", "--urls", "show URLs instead of titles") { opts[:urls] = true }
  o.on("-i", "--interval SECONDS", Float, "live refresh interval (default 10, or 60 with -p)") { |v| opts[:interval] = v }
  o.on("--once", "print one report and exit") { opts[:once] = true }
end.parse!
opts[:interval] ||= opts[:per_tab] ? 60 : 10

def mb(bytes) = format("%.0f MB", bytes / 1024.0 / 1024.0)
def gb_or_mb(bytes) = bytes >= 1024**3 ? format("%.1f GB", bytes / 1024.0**3) : mb(bytes)

# --- memory held by Safari's helpers ---------------------------------------
def helper_memory
  pids = `pgrep -f com.apple.WebKit.WebContent`.split.map(&:to_i)
  totals = { count: pids.size, swapped: 0, footprint: 0, per_pid: {} }
  return totals if pids.empty? || !system("which footprint", out: File::NULL, err: File::NULL)

  Tempfile.create(["tabreport", ".json"]) do |f|
    system("footprint", *pids.flat_map { |p| ["-p", p.to_s] }, "--swapped", "-j", f.path,
           out: File::NULL, err: File::NULL)
    next totals unless File.size?(f.path)

    JSON.parse(File.read(f.path)).fetch("processes", []).each do |pr|
      footprint = pr.fetch("footprint", 0)
      swapped = pr.fetch("categories", {}).values.sum { |c| c.fetch("swapped", 0) }
      totals[:per_pid][pr["pid"]] = { footprint: footprint, swapped: swapped }
      totals[:footprint] += footprint
      totals[:swapped] += swapped
    end
    totals
  end
end

# --- which helper hosts which tab ------------------------------------------
# macOS names every helper "Safari Web Content" and Safari's dictionary gives a
# tab no process id, so the mapping is measured rather than looked up. Each tab
# runs a short JavaScript busy loop, and the helper whose CPU time jumps by
# about that much is the one hosting it. Safari must allow it: Develop > Allow
# JavaScript from Apple Events. A tab that cannot run script, such as the start
# page, a PDF, or a tab Safari has not loaded since launch, maps to no helper.
PROBE_SECONDS = 1.2
PROBE_SCRIPT = <<~APPLESCRIPT
  tell application "Safari"
    do JavaScript "var s = Date.now(); while (Date.now() - s < %<ms>d) {}; 'ok'" in tab %<idx>d of window %<win>d
  end tell
APPLESCRIPT

def helper_cpu_seconds
  `ps -axo pid=,cputime=,comm=`.lines.filter_map do |l|
    pid, cputime, comm = l.split(" ", 3)
    next unless comm.to_s.include?("com.apple.WebKit.WebContent")

    seconds = cputime.split(":").reduce(0.0) { |total, part| total * 60 + part.to_f }
    [pid.to_i, seconds]
  end.to_h
end

def run_probe(tab)
  script = format(PROBE_SCRIPT, ms: (PROBE_SECONDS * 1000).to_i, idx: tab[:idx], win: tab[:win])
  IO.popen(["osascript", "-"], "r+", err: File::NULL) do |io|
    io.write(script)
    io.close_write
    io.read
  end
  Process.last_status.success?
end

# The helper that gained the most CPU during the probe, if it gained at least
# half the loop's length. A page already busy on its own gains some too, which
# is why the largest jump wins rather than the first over a threshold. A helper
# first seen after the loop counts from zero: Safari starts one for a tab it
# restored but has not loaded, and the loop is all that helper has ever done.
def helper_for(tab)
  before = helper_cpu_seconds
  return nil unless run_probe(tab)

  gains = helper_cpu_seconds.map { |pid, seconds| [pid, seconds - before.fetch(pid, 0.0)] }
  pid, gained = gains.max_by(&:last)
  gained.to_f >= PROBE_SECONDS / 2 ? pid : nil
end

# Tabs are probed one at a time; two loops at once would be told apart by
# nothing. The block, if given, is called with the index before each probe.
def probe(list)
  list.each_with_index do |tab, i|
    yield i if block_given?
    tab[:pid] = helper_for(tab)
  end
  list
end

# --- the tabs themselves ---------------------------------------------------
# Inside the Safari tell block the word "tab" is Safari's tab class, so the
# separator is bound to the tab character before entering it.
TAB_SCRIPT = <<~APPLESCRIPT
  set sep to tab
  set out to ""
  tell application "Safari"
    set wi to 0
    repeat with w in windows
      set wi to wi + 1
      set ti to 0
      repeat with t in tabs of w
        set ti to ti + 1
        set out to out & wi & sep & ti & sep & (URL of t) & sep & (name of t) & linefeed
      end repeat
    end repeat
  end tell
  return out
APPLESCRIPT

def tabs
  raw = IO.popen(["osascript", "-"], "r+", err: File::NULL) do |io|
    io.write(TAB_SCRIPT)
    io.close_write
    io.read
  end
  raw.to_s.lines.filter_map do |l|
    win, idx, url, title = l.chomp.split("\t", 4)
    next unless url

    host = begin
      URI(url).host.to_s.sub(/\Awww\./, "")
    rescue URI::Error
      url[%r{\A\w+:/*([^/]+)}, 1].to_s
    end
    { win: win.to_i, idx: idx.to_i, url: url, title: title.to_s.strip, host: host.empty? ? url : host }
  end
end

def tab_ref(t) = "w#{t[:win]}.#{t[:idx]}"

def suggestions(list, helpers = nil)
  notes = []
  notes.concat(helper_notes(list, helpers)) if helpers
  list.group_by { |t| t[:url] }.select { |_, ts| ts.size > 1 }.each do |_, ts|
    notes << format("open %d times: %s  (%s)", ts.size, ts.first[:title], ts.map { |t| tab_ref(t) }.join(", "))
  end
  list.group_by { |t| t[:host] }.select { |_, ts| ts.size >= 4 }.sort_by { |_, ts| -ts.size }.each do |host, ts|
    notes << format("%d tabs on %s; worth a pass to see which are still needed", ts.size, host)
  end
  list.group_by { |t| t[:win] }.select { |_, ts| ts.size == 1 }.each do |win, ts|
    notes << format("window %d holds a single tab: %s", win, ts.first[:title])
  end
  notes
end

# Notes that need the tab-to-helper mapping: the one tab that owns most of the
# swapped memory, and tabs that share a helper and so share its figures.
def helper_notes(list, helpers)
  notes = []
  matched = list.select { |t| helpers[:per_pid][t[:pid]] }
  return notes if matched.empty?

  top = matched.max_by { |t| helpers[:per_pid][t[:pid]][:swapped] }
  share = helpers[:swapped].zero? ? 0 : helpers[:per_pid][top[:pid]][:swapped] * 100 / helpers[:swapped]
  if share >= 25
    notes << format("one tab holds %d%% of what the helpers have swapped: %s  (%s)", share, top[:title], tab_ref(top))
  end
  matched.group_by { |t| t[:pid] }.select { |_, ts| ts.size > 1 }.each_value do |ts|
    notes << format("%s share one helper; its memory is listed once", ts.map { |t| tab_ref(t) }.join(", "))
  end
  notes
end

def tab_tables(list, by_domain:, urls:, width:, limit:)
  label = ->(t) { urls || t[:title].empty? ? t[:url] : t[:title] }
  if by_domain
    grouped = list.group_by { |t| t[:host] }.sort_by { |_, ts| -ts.size }
    rows = grouped.flat_map do |host, ts|
      ts.each_with_index.map { |t, i| [i.zero? ? Table.fit(host, 32) : "", "w#{t[:win]}.#{t[:idx]}", label[t]] }
    end
    [Table.render(["site", "tab", urls ? "url" : "title"], rows.first(limit),
                  flex: 2, align: %i[left left left], width: width)]
  else
    list.group_by { |t| t[:win] }.map do |win, ts|
      rows = ts.map { |t| [t[:idx].to_s, label[t], Table.fit(t[:host], 32)] }
      ["Window #{win} (#{ts.size} tabs)",
       Table.render(["#", urls ? "url" : "title", "site"], rows,
                    flex: 1, optional: [2], align: %i[right left left], width: width)].join("\n")
    end
  end
end

# One row per tab, heaviest helper first. Tabs on one helper sit together and
# its figures appear on the first of them only, so a column total stays honest.
# Tabs that could not be matched come last with a dash.
def per_tab_table(list, helpers, urls:, width:, limit:)
  label = ->(t) { urls || t[:title].empty? ? t[:url] : t[:title] }
  memory = ->(t) { helpers[:per_pid][t[:pid]] }
  rank = ->(t) { memory[t] ? -memory[t][:swapped] : 1 }
  ranked = list.sort_by { |t| [rank[t], t[:pid].to_i, t[:win], t[:idx]] }
  shown = {}
  rows = ranked.first(limit).map do |t|
    m = memory[t]
    cells = if m.nil? then ["–", "–"]
            elsif shown[t[:pid]] then ["", ""]
            else [gb_or_mb(m[:swapped]), gb_or_mb(m[:footprint])]
            end
    shown[t[:pid]] = true
    [*cells, tab_ref(t), Table.fit(t[:host], 32), label[t]]
  end
  Table.render(["swapped", "resident", "tab", "site", urls ? "url" : "title"], rows,
               flex: 4, optional: [3, 1], align: %i[right right left left left], width: width)
end

def report(list, helpers, by_domain:, urls:, width:, limit:, notes: true, per_tab: false)
  if list.empty?
    out = ["Safari has no open tabs (or is not running)."]
    out << format("%d helper processes still hold %s swapped.", helpers[:count], gb_or_mb(helpers[:swapped])) if helpers[:count].positive?
    return out.join("\n")
  end

  windows = list.map { |t| t[:win] }.uniq.size
  matched = list.count { |t| helpers[:per_pid][t[:pid]] }
  head = [
    format("Safari: %d tabs in %d windows, %d helper processes.", list.size, windows, helpers[:count]),
    format("Helpers hold %s in memory, of which %s is compressed or on the swap file.",
           gb_or_mb(helpers[:footprint]), gb_or_mb(helpers[:swapped])),
    if per_tab && matched == list.size
      format("All %d tabs matched to a helper.", matched)
    elsif per_tab
      format("%d of %d tabs matched to a helper; the rest could not run the probe.", matched, list.size)
    else
      format("That is about %s per tab. Every tab you close gives roughly that back.",
             mb(helpers[:footprint] / [list.size, 1].max))
    end
  ].map { |l| TUI.fit(l, width) }

  body = if per_tab
           [per_tab_table(list, helpers, urls: urls, width: width, limit: limit)]
         else
           tab_tables(list, by_domain: by_domain, urls: urls, width: width, limit: limit)
         end
  tail = []
  if per_tab && matched.zero?
    tail << "No tab answered the probe. Turn on Develop > Allow JavaScript from Apple Events in"
    tail << "Safari (the Develop menu is enabled in Settings > Advanced), then run again."
  end
  if notes
    ns = suggestions(list, per_tab ? helpers : nil)
    unless ns.empty?
      tail << "" unless tail.empty?
      tail << "Suggestions"
      ns.each { |n| tail << TUI.fit("  - #{n}", width) }
    end
    tail << ""
    tail << "Nothing was closed. Close tabs in Safari, or quit and reopen it: Safari restores the"
    tail << "tabs and loads each one only when you click it, which frees the helpers' memory."
  end
  [*head, "", *body, *(tail.empty? ? [] : ["", *tail])].join("\n")
end

# --- one-shot ---------------------------------------------------------------
if opts[:once] || !TUI.interactive?
  list = tabs
  if opts[:per_tab]
    progress = $stderr.tty?
    probe(list) { |i| $stderr.print("\rprobing tab #{i + 1} of #{list.size}...") if progress }
    $stderr.print("\r\e[K") if progress
  end
  puts report(list, helper_memory, by_domain: opts[:by_domain], urls: opts[:urls],
              width: Table.width, limit: 1000, per_tab: opts[:per_tab])
  exit
end

# --- live view --------------------------------------------------------------
# Asking Safari for its tabs and measuring the helpers takes about a second, and
# probing every tab with -p about 1.3 s per tab, so both run only on a tick or
# on r; the grouping and title/URL keys re-render what was already read, which
# is what makes them feel instant.
by_domain = opts[:by_domain]
urls = opts[:urls]
per_tab = opts[:per_tab]
snapshot = nil
status = nil

TUI.run(interval: opts[:interval]) do |screen, action|
  by_domain = !by_domain if action == :domain
  urls = !urls if action == :urls
  screen.keys("d" => :domain, "u" => :urls)
  grouping = per_tab ? "" : "[d] #{by_domain ? 'By window' : 'By site'}  "
  screen.footer("  [q] Quit  [r] Refresh  #{grouping}" \
                "[u] #{urls ? 'Titles' : 'URLs'}  [+/-] every #{screen.interval_label}")
  screen.frame do |body_rows, width|
    unless snapshot
      next [TUI.fit("tabreport   #{status}", width), "", "  asking Safari for its open tabs..."].join("\n")
    end

    list = snapshot[:tabs]
    notes = suggestions(list, per_tab ? snapshot[:helpers] : nil)
    # title, blank, three header lines, blank, the suggestions block, and four
    # border lines for each table (one per window unless grouped or per tab).
    frames = by_domain || per_tab ? 1 : [list.map { |t| t[:win] }.uniq.size, 1].max
    limit = [body_rows - 7 - (notes.empty? ? 0 : notes.size + 2) - frames * 5, 1].max

    [
      TUI.fit("tabreport   #{snapshot[:at].strftime('%H:%M:%S')}#{status ? "   #{status}" : ''}", width),
      "",
      report(list, snapshot[:helpers], by_domain: by_domain, urls: urls,
             width: width, limit: limit, notes: false, per_tab: per_tab),
      notes.empty? ? nil : "",
      notes.empty? ? nil : "Suggestions",
      *notes.map { |n| TUI.fit("  - #{n}", width) }
    ].compact.join("\n")
  end

  next unless snapshot.nil? || action.nil? || action == :refresh

  status = "reading..."
  screen.draw
  list = tabs
  if per_tab
    probe(list) do |i|
      status = "probing tab #{i + 1} of #{list.size}..."
      screen.draw
    end
  end
  snapshot = { at: Time.now, tabs: list, helpers: helper_memory }
  status = nil
end
