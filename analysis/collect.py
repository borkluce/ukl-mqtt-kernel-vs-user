#!/usr/bin/env python3
"""Collect one session's run directories into a CSV, one row per run.

usage: python3 analysis/collect.py results/<session> > results/<session>/runs.csv

Reads, per run directory: runner.txt, serial.log (publisher report), serial.log.cpu (launcher
CPU, perf and process accounting) and summary.txt (broker $SYS counters seen by the subscriber).
Only parses and derives; no statistics. Missing values are left empty, never guessed.
"""
import csv
import os
import re
import sys

BENCH = "UKL-MQTT-BENCH: "


def kv(tokens):
    out = {}
    for t in tokens:
        if "=" in t:
            k, v = t.split("=", 1)
            out[k] = v.rstrip("%")
    return out


def lines(path):
    try:
        with open(path, errors="replace") as f:
            return [l.replace("\r", "").rstrip("\n") for l in f]
    except FileNotFoundError:
        return []


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def parse_run(d):
    r = {"run_dir": os.path.basename(d)}
    for l in lines(os.path.join(d, "runner.txt")):
        r.update(kv(l.split()))

    for l in lines(os.path.join(d, "serial.log")):
        if l.startswith("RUN_START "):
            r["guest_kernel"] = kv(l.split()).get("kernel", "")
        elif l.startswith("LAUNCHER_STATUS="):
            r["launcher_status"] = l.split()[0].split("=", 1)[1]
        elif l.startswith(BENCH):
            body = l[len(BENCH):].split()
            if not body:
                continue
            tag, f = body[0], kv(body[1:])
            if tag == "PACING":
                for k in ("requested", "achieved_per_s", "backlog_at_end", "ticks", "late_ticks",
                          "lateness_mean_us", "lateness_max_us", "recovery_events"):
                    r[k] = f.get(k, "")
            elif tag == "WINDOW":
                for k in ("accepted", "attempts", "buffer_full_returns", "window_ns", "payload_bytes",
                          "stopped_on_error", "stop_code"):
                    r[k] = f.get(k, "")
            elif tag == "BUFFULL_SUMMARY":
                r["buffull_periods"] = f.get("periods", "")
                r["buffull_total_us"] = f.get("total_us", "")
            elif tag == "DRAIN":
                r["unsent_after_drain"] = f.get("unsent_after_drain", "")
                r["drain_errors"] = f.get("errors", "")
            elif tag == "RECORDS":
                r["sync_errors"] = f.get("sync_errors", "")
            elif tag.startswith("broker") and "connect_us" in l:
                m = re.search(r"connect_us=(\d+)", l)
                r["connect_us"] = m.group(1) if m else ""

    for l in lines(os.path.join(d, "serial.log.cpu")):
        t = l.split()
        if not t:
            continue
        if t[0] == "CPU_SUMMARY":
            f = kv(t[1:])
            for k in ("wall_s", "vcpu_s", "qemu_total_s", "qemu_other_s", "vhost_threads"):
                r[k] = f.get(k, "")
        elif t[0] == "CPU_BUSY":
            for k, v in kv(t[1:]).items():
                r["busy_" + k] = v
        elif t[0] == "PERF_SUMMARY":
            r.update({k: v for k, v in kv(t[1:]).items()})
        elif t[0] == "PROC_SUMMARY":
            r.update({k: v for k, v in kv(t[1:]).items()})
        elif t[0] == "HOST":
            f = kv(t[1:])
            r["halt_poll_ns"] = f.get("halt_poll_ns", "")
            r["host_cur_khz"] = f.get("cur_khz", "")

    s = kv(lines(os.path.join(d, "summary.txt")))
    b0, b1 = num(s.get("broker_received_start")), num(s.get("broker_received_end"))
    r["broker_received"] = "" if b0 is None or b1 is None else int(b1 - b0)
    d0, d1 = num(s.get("broker_dropped_start")), num(s.get("broker_dropped_end"))
    r["broker_dropped"] = "" if d0 is None or d1 is None else int(d1 - d0)

    # derived
    acc, uns, brk = num(r.get("accepted")), num(r.get("unsent_after_drain")), num(r.get("broker_received"))
    r["accounting_ok"] = "" if None in (acc, uns, brk) else int(acc - uns == brk)
    for k in ("vcpu_s", "qemu_total_s"):
        v = num(r.get(k))
        r[k.replace("_s", "_us_per_msg")] = f"{v * 1e6 / brk:.3f}" if v is not None and brk else ""
    gi = num(r.get("guest_instr"))
    r["guest_instr_per_msg"] = f"{gi / brk:.1f}" if gi is not None and brk else ""
    return r


def main():
    root = sys.argv[1]
    runs = sorted(os.path.join(root, x) for x in os.listdir(root)
                  if os.path.isfile(os.path.join(root, x, "runner.txt")))
    rows = [parse_run(d) for d in runs]
    rows.sort(key=lambda r: int(r.get("n", 0) or 0))
    lead = ["n", "block", "config", "mode", "rate", "run_dir", "launcher_status", "launcher_rc"]
    cols = lead + sorted({k for r in rows for k in r} - set(lead))
    w = csv.DictWriter(sys.stdout, fieldnames=cols, extrasaction="ignore")
    w.writeheader()
    for r in rows:
        w.writerow(r)


if __name__ == "__main__":
    main()
