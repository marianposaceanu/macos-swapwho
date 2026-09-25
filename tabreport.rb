#!/usr/bin/env ruby
# frozen_string_literal: true

# tabreport: what Safari's open tabs cost, and which ones you might close.
#
# Safari runs each tab in its own helper process. macOS does not say which helper
# belongs to which tab, so this tool does not try to act on individual processes.
# It measures the helpers as a group, lists every open tab, and points out the
# usual suspects: duplicates, piles of tabs from one site, and windows you may
# have forgotten. Nothing is closed; that decision stays with you.
#
#   tabreport            live view, refreshing every 10 s
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

opts = { by_domain: false, urls: false, interval: 10, once: false }
OptionParser.new do |o|
  o.banner = "usage: tabreport [-d] [-u] [-i SECONDS] [--once]"
  o.on("-d", "--by-domain", "group tabs by site") { opts[:by_domain] = true }
  o.on("-u", "--urls", "show URLs instead of titles") { opts[:urls] = true }
  o.on("-i", "--interval SECONDS", Float, "live refresh interval (default 10)") { |v| opts[:interval] = v }
  o.on("--once", "print one report and exit") { opts[:once] = true }
end.parse!

def mb(bytes) = format("%.0f MB", bytes / 1024.0 / 1024.0)
def gb_or_mb(bytes) = bytes >= 1024**3 ? format("%.1f GB", bytes / 1024.0**3) : mb(bytes)

# --- memory held by Safari's helpers ---------------------------------------
def helper_memory
  pids = `pgrep -f com.apple.WebKit.WebContent`.split.map(&:to_i)
  totals = { count: pids.size, swapped: 0, footprint: 0 }
  return totals if pids.empty? || !system("which footprint", out: File::NULL, err: File::NULL)

  Tempfile.create(["tabreport", ".json"]) do |f|
    system("footprint", *pids.flat_map { |p| ["-p", p.to_s] }, "--swapped", "-j", f.path,
           out: File::NULL, err: File::NULL)
    next totals unless File.size?(f.path)

    JSON.parse(File.read(f.path)).fetch("processes", []).each do |pr|
      totals[:footprint] += pr.fetch("footprint", 0)
      totals[:swapped] += pr.fetch("categories", {}).values.sum { |c| c.fetch("swapped", 0) }
    end
    totals
  end
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

def suggestions(list)
  notes = []
  list.group_by { |t| t[:url] }.select { |_, ts| ts.size > 1 }.each do |_, ts|
    notes << format("open %d times: %s  (%s)", ts.size, ts.first[:title],
                    ts.map { |t| "w#{t[:win]}.#{t[:idx]}" }.join(", "))
  end
  list.group_by { |t| t[:host] }.select { |_, ts| ts.size >= 4 }.sort_by { |_, ts| -ts.size }.each do |host, ts|
    notes << format("%d tabs on %s; worth a pass to see which are still needed", ts.size, host)
  end
  list.group_by { |t| t[:win] }.select { |_, ts| ts.size == 1 }.each do |win, ts|
    notes << format("window %d holds a single tab: %s", win, ts.first[:title])
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

def report(list, helpers, by_domain:, urls:, width:, limit:, notes: true)
  if list.empty?
    out = ["Safari has no open tabs (or is not running)."]
    out << format("%d helper processes still hold %s swapped.", helpers[:count], gb_or_mb(helpers[:swapped])) if helpers[:count].positive?
    return out.join("\n")
  end

  windows = list.map { |t| t[:win] }.uniq.size
  head = [
    format("Safari: %d tabs in %d windows, %d helper processes.", list.size, windows, helpers[:count]),
    format("Helpers hold %s in memory, of which %s is compressed or on the swap file.",
           gb_or_mb(helpers[:footprint]), gb_or_mb(helpers[:swapped])),
    format("That is about %s per tab. Every tab you close gives roughly that back.",
           mb(helpers[:footprint] / [list.size, 1].max))
  ].map { |l| TUI.fit(l, width) }

  body = tab_tables(list, by_domain: by_domain, urls: urls, width: width, limit: limit)
  tail = []
  if notes
    ns = suggestions(list)
    unless ns.empty?
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
  puts report(tabs, helper_memory, by_domain: opts[:by_domain], urls: opts[:urls],
              width: Table.width, limit: 1000)
  exit
end

# --- live view --------------------------------------------------------------
# Asking Safari for its tabs and measuring the helpers takes about a second, so
# it runs only on a tick or on r; the grouping and title/URL keys re-render what
# was already read, which is what makes them feel instant.
by_domain = opts[:by_domain]
urls = opts[:urls]
snapshot = nil
reading = false

TUI.run(interval: opts[:interval]) do |screen, action|
  by_domain = !by_domain if action == :domain
  urls = !urls if action == :urls
  screen.keys("d" => :domain, "u" => :urls)
  screen.footer("  [q] Quit  [r] Refresh  [d] #{by_domain ? 'By window' : 'By site'}  " \
                "[u] #{urls ? 'Titles' : 'URLs'}  [+/-] every #{screen.interval_label}")
  screen.frame do |body_rows, width|
    unless snapshot
      next [TUI.fit("tabreport   reading...", width), "", "  asking Safari for its open tabs..."].join("\n")
    end

    list = snapshot[:tabs]
    notes = suggestions(list)
    # title, blank, three header lines, blank, the suggestions block, and four
    # border lines for each table (one per window unless grouped by site).
    frames = by_domain ? 1 : [list.map { |t| t[:win] }.uniq.size, 1].max
    limit = [body_rows - 7 - (notes.empty? ? 0 : notes.size + 2) - frames * 5, 1].max

    [
      TUI.fit("tabreport   #{snapshot[:at].strftime('%H:%M:%S')}#{reading ? '   reading...' : ''}", width),
      "",
      report(list, snapshot[:helpers], by_domain: by_domain, urls: urls,
             width: width, limit: limit, notes: false),
      notes.empty? ? nil : "",
      notes.empty? ? nil : "Suggestions",
      *notes.map { |n| TUI.fit("  - #{n}", width) }
    ].compact.join("\n")
  end

  next unless snapshot.nil? || action.nil? || action == :refresh

  reading = true
  screen.draw
  snapshot = { at: Time.now, tabs: tabs, helpers: helper_memory }
  reading = false
end
