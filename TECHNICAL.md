# Technical notes

The details behind the numbers. Read this when a figure looks wrong, or when you want to
know what the tools are actually measuring.

## What "swapped" means on macOS

macOS keeps a process's anonymous memory in one of three places:

1. **Resident** in RAM, directly usable.
2. **Compressed**, still in RAM but packed by the kernel's memory compressor. The
   process cannot use it until the kernel decompresses it, which is fast.
3. **On disk**, in `/private/var/vm/swapfile*`. The compressor writes whole compressed
   segments there when even compressed pages no longer fit. Reading them back is slow.

There is no per-process counter for case 3 alone. The only per-process figure the system
exposes is cases 2 and 3 combined. `footprint --swapped` reports it per memory category
and `vmmap --summary` as the `SWAPPED` column of its TOTAL row; the two agree to within a
few percent. `swapwho` and `tabreap` use footprint and fall back to vmmap. The system-wide split between
RAM and disk is available from `vm_stat` and `sysctl vm.swapusage`, and `swapwho` prints
it in its header so the two views can be compared.

## Units

footprint and vmmap count **uncompressed pages**: the size the memory would have if it
were resident.
The kernel's own figures are mixed:

| figure | source | unit |
| --- | --- | --- |
| Pages stored in compressor | `vm_stat` | uncompressed pages |
| Pages occupied by compressor | `vm_stat` | RAM actually used, after compression |
| swap used | `sysctl vm.swapusage` | bytes on disk, compressed |

`swapwho`'s `%system` column therefore divides by **Pages stored in compressor**, the
only kernel figure in the same unit. Dividing by compressor RAM or swap-file bytes would
overstate every process by the compression ratio, typically two to three times.

## Why grouped totals can exceed 100%

footprint and vmmap attribute a page to every process that maps it. Shared memory such as the dyld
shared cache and WebKit's shared regions is therefore counted once per process. Thirty
Safari helpers sharing the same 400 MB of libraries will report 30 times that between
them. Single-process rows are accurate; grouped rows are an upper bound. The `%sum`
column, which divides by the sum of what was found, is consistent within one run but
inherits the same double counting.

## Why not sudo by default

Without root, footprint and vmmap can inspect only processes owned by the invoking user. System
daemons, `WindowServer`, and other users' processes are skipped, so `%system` will not
add up to 100. `sudo swapwho` examines everything. The difference is usually small: on a
laptop the user's browser and editors dominate swap, not the daemons.

## Why footprint, and not something lower level

- `task_info(TASK_VM_INFO)` returns a per-task `compressed` byte count, but nothing for
  pages already written to disk, and `task_for_pid` on another process needs root or the
  `com.apple.system-task-ports` entitlement.
- `proc_pid_rusage` exposes physical footprint but not the swapped part.
- Activity Monitor's "Compressed Mem" column is the `task_info` figure above.

`footprint` and `vmmap` are Apple-signed tools that hold the debugging entitlement, so
they can read same-user processes without privileges and report the combined figure.
footprint is preferred because it accepts many pids per invocation and prints JSON
(`-j`), which makes a whole-system pass cheap; `footprint -a` (all processes in one
call) additionally needs root, so the scripts pass explicit pid lists instead.

## Cost of a run

Both tools walk every VM region of the target. footprint amortises that across many pids
per call: a full `swapwho` pass over about 400 processes takes two seconds on an M4 and
briefly uses every core, and `tabreap` about the same for the browser helpers. The vmmap
fallback is one process per call and takes 45 to 60 seconds for the same pass. Neither
tool is meant to run in a loop; `swapchurn` is the one to leave running, and it only
reads `vm_stat`.

## Why tabreport does not act on processes

Each Safari tab is a `com.apple.WebKit.WebContent` process, and its memory is easy to
measure. Mapping a process back to a tab is not: LaunchServices names every helper
"Safari Web Content", the process has no arguments or environment naming its site, its
open files are shared caches, and Safari's AppleScript dictionary exposes tab titles and
URLs but no process id. Activity Monitor shows a site name next to each helper through a
private interface. Without that mapping, killing "the largest idle helper" is killing an
unknown tab, and an idle tab can still be the one you kept open on purpose. `tabreport`
therefore reports totals for the helpers as a group and lists the tabs by name, and
leaves closing to the user.

## Reading swapchurn

| column | meaning |
| --- | --- |
| swapin/s | pages read back from the swap file; the expensive direction |
| swapout/s | pages written to the swap file |
| compr/s, decomp/s | pages entering and leaving the compressor; cheap, RAM to RAM |
| free | pages not in use; on macOS this is normally small and not a problem |
| compressor | RAM used by the compressor |
| swap | swap file in use |

The verdict looks only at swap-ins: under 5/s quiet, under 100/s light, above that heavy.
High compression rates with low swap-ins mean the compressor is absorbing the pressure,
which is the cheap case. A spike when switching applications is normal; watch for at
least half a minute before drawing a conclusion.

## Output tables

`lib/table.rb` draws the rounded box tables. Column widths come from the content, and
when the table is wider than the terminal it first drops the columns each script marks
as optional, in order, and only then shrinks its flex column with an ellipsis. Terminal
width comes from `IO.console.winsize`, falling back to `COLUMNS` and then to 80 when the
output is piped, minus one column so nothing wraps on terminals that scroll on the last
cell.

`swapchurn` uses `Table::Live`, which prints the header immediately and each row as it is
sampled, so a long run streams rather than waiting for the end. Nothing is ever written
across the columns: a spanning row has no separators of its own, so it visually cuts the
table in half. The verdict legend is printed above the table and the per-state advice
below it, once each, and Ctrl-C closes the frame before printing.

Dropped-column order per script:

| script | dropped first | last to go |
| --- | --- | --- |
| `swapwho` | `%sum`, then `resident`, then `%system` | `swapped`, `procs`/`pid`, `name` |
| `swapchurn` | `compr/s`, `decomp/s`, `free`, `swap` | `time`, `swapin/s`, `swapout/s`, `verdict` |
| `tabreport` | `site` | `#`, `title` |

## The full-screen views

`lib/tui.rb` runs each tool's live view using standard terminal controls:

- draw into the **alternate screen buffer** (`\e[?1049h`), so the shell scrollback is
  untouched and the terminal is exactly as it was on exit;
- put stdin in **raw mode** for single keypresses, which also disables newline translation,
  so every frame is written with explicit CRLFs;
- redraw by homing the cursor, writing the new frame over the old one, erasing each line
  to its end (`\e[K`) and the rest of the screen below (`\e[J`). A clear-then-write would
  flash blank on every refresh, and without the per-line erase a shorter line only
  overwrites its own length, so the right-hand tail of a wider frame survives a narrowing
  resize;
- wait for the next tick with a **deadline loop around `IO.select`**, capped at 250 ms, so
  a keypress is acted on immediately and a window resize is noticed between ticks.

`q` and Ctrl-C always quit, `r` and space refresh, and `+` and `-` step the refresh
interval along a fixed ladder from 0.25 s to 5 minutes; an interval given with `-i` that
is not on the ladder snaps to the neighbouring rung. Each tool adds its own bindings (`p`
in swapchurn, `g` in swapwho, `d` and `u` in tabreport). The block passed to `TUI.run` is
re-entered after a bound key, so the handler can flip state and have the next frame
reflect it.

Every tool refuses the full-screen path when stdin or stdout is not a terminal and prints
a plain report instead, so `swapwho --once | less` and cron-style use keep working.

## Keeping the keys instant

A pass over every process takes a second or two, and asking Safari for its tabs about one,
so neither can run on a key press. `swapwho` and `tabreport` keep the last measurement and
render from it: toggling the grouping, or titles against URLs, only re-renders what is
already in hand and lands in one or two milliseconds. New data is collected on a tick or
on `r`.

That needs `TUI.run` to yield for every action rather than only for bound keys, so a view
can tell a tick apart from a key. The screen is also live before the block first runs, so
a slow view draws a progress line, collects, and draws again, rather than showing a blank
alternate screen while it works. A refresh over existing data marks the title instead, so
the table stays readable while the next measurement runs.

## The plot

`swapchurn` plots with the `ascii_chart` gem and degrades to the rest of the view with a
one-line hint when the gem is missing. Three details matter.

The gem draws the y-axis label inside the canvas, so the usable sample count is the
terminal width minus the label and the offset. A series whose values are all equal makes
it raise, so a flat run is drawn as a single rule instead. And the plot is padded to a
**constant number of rows** whatever it contains: an early version let a flat series
collapse to one line, so the frame grew by ten lines the moment the series moved, overflowed
the window, scrolled, and left the previous footer stranded above the new one.

Each view therefore lays its sections out from their real sizes rather than a guessed
overhead, giving the table whatever rows are left. On a window too short for both, the
table shrinks first and the plot is dropped only when even one table row will not fit.
`Screen#draw` is the backstop: it truncates each line to the width, the frame to the
height, and pads so the footer always owns the bottom row.

Rates come from the real elapsed time between samples rather than the nominal interval,
because pressing a key redraws early and dividing by the interval would understate every
rate in that shorter tick.
