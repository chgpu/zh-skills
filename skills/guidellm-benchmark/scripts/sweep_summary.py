#!/usr/bin/env python3
"""sweep_summary.py — curated aggregate markdown for a sweep run directory.

Usage:
    python3 sweep_summary.py <guidellm_sweep_YYYYMMDD_HHMMSS>

Reads profiles/*/benchmarks.json (source of truth) and prints:
  * the aggregate table (medians, groups of 3 stream steps,
    8k_1k final-row peak tok/s bold; latency cells are med/p99 —
    percentiles over the successful subset),
  * headline bullets (single-stream baseline, saturation check, per-workload peaks).
Append the output to the run's REPORT.md instead of hand-transcribing
numbers — hand-typed tables have drifted from the JSON before.

Note: completion is computed from the explicit successful/errored/incomplete
counters. request_totals also carries a 'total' key (and more), so never
sum the dict's values.
"""
import glob
import json
import os
import sys

SATURATION_TTFT_MS = 10_000.0  # median TTFT beyond this = saturated
LABELS = {
    "quick_256_128": "quick 256→128",
    "chat_2k_512": "chat 2048→512",
    "reasoning_4k_2k": "reasoning 4096→2048",
    "8k_1k": "8k 8192→1024",
}


def completion(rt):
    tot = rt["successful"] + rt["errored"] + rt["incomplete"]
    return 100.0 * rt["successful"] / tot if tot else 0.0


def p99_of(m, key):
    s = m[key]["successful"]
    return s.get("percentiles", {}).get("p99", s["median"])


def itl_of(m, kind):
    s = m.get("inter_token_latency_ms", {}).get("successful")
    if not s:
        return None
    if kind == "p99":
        return s.get("percentiles", {}).get("p99", s.get("median"))
    return s.get("median")


def lat_cell(v):
    return "n/a" if v is None else f"{v:.0f}"


def table_row(wl, steps, data, peak_row=False):
    label = LABELS.get(wl, wl)
    sl = " / ".join(str(s) for s in steps)
    if len(steps) == 1:
        rt, o, tt, tp, tt99, tp99, im, i99 = data[wl][steps[0]]
        cnt = f"{rt['successful']}/{rt['errored']}/{rt['incomplete']} · {completion(rt):.1f}%"
        tos = f"**{o:.0f}**" if peak_row else f"{o:.0f}"
        tfs, tps = f"{tt:.0f}/{tt99:.0f}", f"{tp:.2f}/{tp99:.2f}"
        il = f"{lat_cell(im)}/{lat_cell(i99)}"
    else:
        cnt = " · ".join(
            f"{data[wl][s][0]['successful']}/{data[wl][s][0]['errored']}"
            f"/{data[wl][s][0]['incomplete']} · {completion(data[wl][s][0]):.1f}%"
            for s in steps)
        tos = "/".join(
            (f"**{data[wl][s][1]:.0f}**" if peak_row and s == steps[-1]
             else f"{data[wl][s][1]:.0f}") for s in steps)
        tfs = "/".join(f"{data[wl][s][2]:.0f}/{data[wl][s][4]:.0f}" for s in steps)
        tps = "/".join(f"{data[wl][s][3]:.2f}/{data[wl][s][5]:.2f}" for s in steps)
        il = "/".join(f"{lat_cell(data[wl][s][6])}/{lat_cell(data[wl][s][7])}"
                      for s in steps)
    return f"| {label} | {sl} | {cnt} | {tos} | {tfs} | {tps} | {il} |"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run_dir = sys.argv[1]
    data = {}
    for f in sorted(glob.glob(os.path.join(run_dir, "profiles", "*", "benchmarks.json"))):
        name = os.path.basename(os.path.dirname(f))
        m = json.load(open(f))["benchmarks"][0]["metrics"]
        wl, st = name.rsplit("_stream_", 1)
        data.setdefault(wl, {})[int(st)] = (
            m["request_totals"],
            m["output_tokens_per_second"]["successful"]["median"],
            m["time_to_first_token_ms"]["successful"]["median"],
            m["time_per_output_token_ms"]["successful"]["median"],
            p99_of(m, "time_to_first_token_ms"),
            p99_of(m, "time_per_output_token_ms"),
            itl_of(m, "median"),
            itl_of(m, "p99"),
        )
    if not data:
        sys.exit(f"no profiles/*/benchmarks.json under {run_dir}")

    streams = sorted({s for d in data.values() for s in d})
    groups = [streams[i:i + 3] for i in range(0, len(streams), 3)]

    print("## Aggregate summary (curated, medians from `benchmarks.json`)")
    print()
    print("Latency cells are `median/p99` over the successful subset.")
    print()
    print("| Workload | streams | ok / err / incomp · completion "
          "| output tok/s (med) | TTFT med/p99 (ms) | TPOT med/p99 (ms) "
          "| ITL med/p99 (ms) |")
    print("|---|---|---|---|---|---|---|")
    for wl in sorted(data):
        for i, g in enumerate(groups):
            g = [s for s in g if s in data[wl]]
            if g:
                print(table_row(wl, g, data,
                                 peak_row=(wl == "8k_1k" and i == len(groups) - 1)))

    base = {wl: data[wl][1] for wl in data if 1 in data[wl]}
    peaks = {wl: max(((s, m[1]) for s, m in data[wl].items()),
                     key=lambda t: t[1]) for wl in data}
    max_ttft = max((m[2] for d in data.values() for m in d.values()), default=0.0)
    total_err = sum(m[0]["errored"] for d in data.values() for m in d.values())
    climbing = []
    for wl in data:
        ss = sorted(data[wl])
        if len(ss) >= 2:
            lo, hi = ss[-2], ss[-1]
            if data[wl][hi][1] > data[wl][lo][1]:
                climbing.append(f"{LABELS.get(wl, wl)} "
                                f"({data[wl][lo][1]:.0f}@{lo} → {data[wl][hi][1]:.0f}@{hi})")

    print()
    print("Headlines:")
    print()
    if base:
        lo = min(m[1] for m in base.values())
        hi = max(m[1] for m in base.values())
        tps = [m[3] for m in base.values()]
        tt = [m[2] for m in base.values()]
        il = [m[6] for m in base.values() if m[6] is not None]
        itl_part = (f", ITL ~{min(il):.0f}–{max(il):.0f} ms" if il else "")
        print(f"- **Single-stream baseline**: ~{lo:.0f}–{hi:.0f} tok/s per stream, "
              f"TPOT ~{min(tps):.1f}–{max(tps):.1f} ms (per-request decode)"
              f"{itl_part}, TTFT {min(tt):.0f}–{max(tt):.0f} ms depending on "
              f"prompt length.")
    sat = ("not saturated" if max_ttft < SATURATION_TTFT_MS
           else "SATURATED (median TTFT ≥ 10 s)")
    print(f"- **Saturation inside the grid**: {sat} (max median TTFT "
          f"{max_ttft / 1000.0:.1f} s, threshold ~10 s); `errored` total = {total_err}. "
          "Falling completion at high streams = in-flight requests at the "
          "window cutoff, not failure.")
    for wl in sorted(peaks, key=lambda w: -peaks[w][1]):
        s, v = peaks[wl]
        print(f"- **Peak (median aggregate output tok/s)** "
              f"{LABELS.get(wl, wl)}: **{v:.0f}** @{s} streams.")
    if climbing:
        print(f"- Still climbing at the top of the grid: {', '.join(climbing)} "
              "→ the server is not at its knee; extend the stream grid "
              "(e.g. 192/256) to pin it.")


if __name__ == "__main__":
    main()
