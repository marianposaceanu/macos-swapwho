# macos-swapwho

Three small tools for one question: **why is my Mac swapping, and what do I do about it?**

| tool | answers |
| --- | --- |
| `swapchurn` | is swap actually slowing me down right now |
| `swapwho` | which apps own the memory that is out of RAM |
| `tabreport` | what my Safari tabs cost, and which ones to close |

Each one opens a full-screen view that refreshes itself and resizes with the window, or
prints a plain report with `--once` so you can pipe it.

| key | does |
| --- | --- |
| **q** | quit, in any of the three |
| **r** | refresh now, rather than waiting for the next tick |
| **+** **-** | slow down or speed up the refresh, from 0.25 s to 5 min |
| **p** | `swapchurn`: cycle the plotted metric |
| **g** | `swapwho`: group by app, or one row per process |
| **d**, **u** | `tabreport`: group by site; show titles or URLs |

## Install

```sh
git clone https://github.com/marianposaceanu/macos-swapwho
cd macos-swapwho
for t in swapwho swapchurn tabreport; do ln -s "$PWD/$t.rb" ~/bin/$t; done
```

Plain Ruby otherwise. `swapchurn`'s plot uses the `ascii_chart` gem; without it the rest
of the view still works:

```sh
gem install ascii_chart      # or: bundle install
```

## The three-step loop

```
  swapchurn ---> "quiet" ------> stop, swap is parked and costs nothing
      |
      +--------> "heavy" ------> swapwho -----> who owns it?
                                     |
                                     v
                       browser tabs?  ---> tabreport, close what you no longer need
                       agents/editors ---> quit the idle sessions
                       everything else ---> quit and relaunch it
                                     |
                                     v
                                 swapchurn again
```

1. **`swapchurn`** for half a minute. Swapped memory that nobody touches is free; it only
   hurts when pages keep moving between RAM and disk. The verdict column says which.
2. **`swapwho`** if the verdict is heavy. The top row is the owner. On a laptop with a
   browser open it is almost always the browser's tab helpers.
3. **`tabreport`** to see every open tab and what the lot costs, then close the ones you
   are done with, or quit the app that owns the memory. Watch `swapchurn` settle.

## What the tools look at

```
                one process's memory                      the kernel's totals
  +-----------------------------------------+
  |  resident        | compressed | on disk |     vm_stat, sysctl vm.swapusage
  |  (in RAM, usable)|  (in RAM)  | (swap)  |
  +-----------------------------------------+
                     |<------ SWAPPED ----->|     <-- swapwho, tabreport read this
                                                     per process, via footprint
                     |<-- compressor ->|<-swap->|   <-- swapchurn watches these
                                                     move, via vm_stat
```

macOS does not say how much of one process is on disk versus compressed; it only reports
the two together. That combined figure is what `swapwho` and `tabreport` show. It is in
uncompressed pages, so the numbers are larger than the swap file. Shared libraries are
counted once per process that uses them, which is why a group of 30 browser helpers can
show more than 100%. Details in [TECHNICAL.md](TECHNICAL.md).

## swapchurn

```sh
swapchurn                  # live, sampling twice a second
swapchurn -i 2             # every 2 s
swapchurn -P compressor    # start the plot on another metric
swapchurn --list-metrics   # swapin swapout compr decompr compressor swap free
swapchurn -c 10            # print ten samples and exit
swapchurn --once           # one sample, for scripts and pipes
```

```
swapchurn   01:33:09

  swap file   974 MB of 2.0 GB used
  compressor  2.5 GB of RAM holding 5.8 GB of pages
  verdict     quiet, Swap is parked. Nothing is paging in, so it is costing you nothing.

  decompressions per second, newest at right

     29075 ┼  ╭╮  ╭╮
     22614 ┤  ||  ||
     16153 ┤  ||  || ╭╮
      9692 ┤|||| |    |
      3231 ┤|  ╰╮|    | |╰╮╭-╮ ╭╮
         0 ┼╯   ╰╯    ╰-╯ ╰╯ ╰-╯╰

╭──────────┬──────────┬───────────┬─────────┬───────────┬────────┬────────────┬────────┬─────────╮
│ time     │ swapin/s │ swapout/s │ compr/s │ decompr/s │ free   │ compressor │ swap   │ verdict │
├──────────┼──────────┼───────────┼─────────┼───────────┼────────┼────────────┼────────┼─────────┤
│ 01:33:08 │        0 │         0 │   10681 │       284 │  77 MB │    2558 MB │ 974 MB │ quiet   │
│ 01:33:09 │        0 │         0 │    4021 │       356 │  90 MB │    2544 MB │ 974 MB │ quiet   │
╰──────────┴──────────┴───────────┴─────────┴───────────┴────────┴────────────┴────────┴─────────╯

  [q] Quit  [r] Sample now  [p] Plot: decompressions per second  [+/-] every 0.5s
```

The verdict is the swap-in rate: under 5/s quiet, under 100/s light, above that heavy.
**p** cycles what is plotted and `-P` picks it at launch, because on a quiet machine the
swap-in line is flat and the compressor is where the movement is:

| metric | what it shows |
| --- | --- |
| `swapin` | pages read back from disk; the expensive direction, and the verdict |
| `swapout` | pages written to disk |
| `compr`, `decompr` | pages entering and leaving the compressor; cheap, RAM to RAM |
| `compressor` | RAM the compressor holds |
| `swap` | swap file in use |
| `free` | free memory |

The plot keeps a constant height and the footer keeps the bottom row, so nothing shifts as
samples arrive. One spike when you switch apps is normal; half a minute of heavy is the
real signal.

## swapwho

```sh
swapwho              # live, measuring every 10 s
swapwho -g           # start grouped by app name
swapwho -i 30        # measure every 30 s instead of 10
swapwho --once -n 40 # print one report with 40 rows
sudo swapwho         # include system processes
```

```
swapwho   01:35:00   measured in 1.4s

  swap file   974 MB of 2.0 GB used
  compressor  2.1 GB of RAM holding 4.8 GB of pages
  examined    391 processes (yours only; sudo for all), holding 5.8 GB of out-of-RAM pages

╭─────────┬──────────┬───────┬─────────┬───────┬─────────────────────────────╮
│ swapped │ resident │ %sum  │ %system │ procs │ name                        │
├─────────┼──────────┼───────┼─────────┼───────┼─────────────────────────────┤
│  1.6 GB │   1.9 GB │ 27.2% │   32.9% │     9 │ com.apple.WebKit.WebContent │
│  342 MB │   300 MB │  5.8% │    7.0% │     1 │ Safari                      │
│  166 MB │   647 MB │  2.8% │    3.4% │     2 │ claude                      │
╰─────────┴──────────┴───────┴─────────┴───────┴─────────────────────────────╯

  [q] Quit  [r] Measure now  [g] Per process  [+/-] every 10s
```

Read `%system` as "share of everything the kernel has pushed out of RAM". **g** switches
between one row per process and one row per app, re-rendering the measurement already in
hand rather than taking a new one, so it is instant. A fresh pass runs on the timer or on
**r**, and the title says so while it works.

## tabreport

```sh
tabreport            # live, refreshing every 10 s
tabreport -d         # group by site
tabreport -u         # show URLs instead of titles
tabreport --once     # print one report
```

```
tabreport   01:35:14

Safari: 19 tabs in 1 windows, 10 helper processes.
Helpers hold 2.5 GB in memory, of which 1.6 GB is compressed or on the swap file.
That is about 133 MB per tab. Every tab you close gives roughly that back.

╭──────────────────┬───────┬────────────────────────────╮
│ site             │ tab   │ title                      │
├──────────────────┼───────┼────────────────────────────┤
│ example.com      │ w1.1  │ Example documentation      │
│                  │ w1.2  │ Example reference guide    │
│ example.org      │ w1.3  │ Example project            │
╰──────────────────┴───────┴────────────────────────────╯

Suggestions
  - open 2 times: Example reference guide  (w1.2, w1.11)
  - 18 tabs on example.com; worth a pass to see which are still needed
```

**d** and **u** re-render what was already read, so they are instant; Safari is asked
again on the timer or on **r**.

Each Safari tab runs in its own helper process, and macOS does not say which helper is
which tab, so `tabreport` deliberately does not touch processes. It measures them as a
group, shows you the tabs, and points at duplicates, piles from one site, and windows
holding a single tab. You decide what to close. Quitting and reopening Safari is the
other safe move: tabs are restored and each one loads only when you click it.

## What does not help

- `sudo purge` and "memory cleaner" apps: they drop disk cache, not swap, and macOS
  refills the cache within minutes.
- Shrinking the swap file: the kernel frees it on its own once the pages are gone.
- Disabling swap or compression: trades a slow Mac for one that kills apps under load.
- Blaming the compressor: several GB of RAM holding two to three times that in
  compressed pages is the system working as designed.

If, after trimming, the browser is still on top and `swapchurn` is still heavy, the honest
answer is fewer tabs or more RAM.
