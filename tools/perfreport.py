#!/usr/bin/env python3
"""Summarise SlayPerf CSVs side by side so one-knob-at-a-time runs are easy to compare.

    tools/perfreport.py device-logs/mods/slayperf/logs/*.csv
    tools/perfreport.py --last 4            # newest 4 CSVs in device-logs/
"""
import argparse
import csv
import glob
import os
import re
import statistics
import sys


def num(row, key):
    try:
        return float(row[key])
    except (KeyError, ValueError):
        return None


def summarise(path):
    with open(path, newline="") as f:
        header = f.readline().lstrip("# ").strip()
        rows = list(csv.DictReader(f))
    if not rows:
        return None
    live = [r for r in rows if (num(r, "frames") or 0) > 0]
    col = lambda k, rs=rows: [v for v in (num(r, k) for r in rs) if v is not None and v >= 0]

    def med(k, rs=live):
        v = col(k, rs)
        return statistics.median(v) if v else float("nan")

    preloads = {}
    for r in rows:
        for m in re.finditer(r"Preloading '([^']+)' Complete: assets=\d+ time_elapsed=([\d,]+)ms", r.get("event", "")):
            preloads.setdefault(m.group(1), []).append(int(m.group(2).replace(",", "")))
    menu = re.search(r"Time to main menu: ([\d,]+)ms", " ".join(r.get("event", "") for r in rows))

    label = re.search(r"label=(\S*)", header)
    return {
        "file": os.path.basename(path),
        "label": (label.group(1) if label else "") or "-",
        "config": header,
        "duration_s": num(rows[-1], "t_s"),
        "fps_median": med("fps"),
        "frame_ms_median": med("frame_ms_avg"),
        "hitches": sum(col("hitches")),
        "worst_stall_s": max(col("stall_ms") or [0]) / 1000,
        "draw_calls_median": med("draw_calls"),
        "tex_mem_mb_peak": max(col("tex_mem_mb") or [0]),
        "rss_mb_peak": max(col("rss_mb") or [0]),
        "mem_avail_mb_min": min(col("mem_avail_mb") or [0]),
        "swap_used_mb_peak": max(col("swap_used_mb") or [0]),
        "swap_in_pages": sum(col("swapin_pages")),
        "swap_out_pages": sum(col("swapout_pages")),
        "major_faults": sum(col("major_faults")),
        "gc_pause_ms": sum(col("gc_pause_ms")),
        "proc_cpu_pct_median": med("proc_cpu_pct", rows),
        "iowait_pct_median": med("iowait_pct", rows),
        "cpu_mhz_min": min(col("cpu_mhz") or [0]),
        "temp_c_max": max(col("temp_c") or [0]),
        "main_menu_s": int(menu.group(1).replace(",", "")) / 1000 if menu else float("nan"),
        **{f"preload[{k}]_s": sum(v) / 1000 for k, v in preloads.items()},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="*")
    ap.add_argument("--last", type=int, default=0, help="use the newest N CSVs under device-logs/")
    a = ap.parse_args()
    files = a.csv
    if a.last:
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "device-logs")
        files = sorted(glob.glob(os.path.join(root, "**", "*.csv"), recursive=True), key=os.path.getmtime)[-a.last:]
    runs = [s for s in map(summarise, files) if s]
    if not runs:
        sys.exit("no CSVs with data")

    keys = []
    for r in runs:
        keys += [k for k in r if k not in keys and k not in ("file", "config")]
    w = max(len(k) for k in keys)
    cw = max(12, *(len(r["label"]) for r in runs))
    for r in runs:
        print(f"{r['file']}: {r['config']}")
    print()
    for k in keys:
        cells = []
        for r in runs:
            v = r.get(k, "")
            cells.append(f"{v:>{cw}.1f}" if isinstance(v, float) else f"{v!s:>{cw}}")
        print(f"{k:<{w}}  " + "  ".join(cells))


if __name__ == "__main__":
    main()
