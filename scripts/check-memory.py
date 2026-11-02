#!/usr/bin/env python3
"""Measure only this run's app and attributed WebKit services; never touch existing app windows."""
import argparse
import ctypes
import json
from pathlib import Path
import re
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--profile", choices=["standard", "deep", "image"], default="standard")
args = parser.parse_args()
directory = args.output.resolve()
directory.mkdir(parents=True, exist_ok=False)
if args.profile in ("deep", "image"):
    import struct
    import zlib
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    width, height = 6000, 4000
    compressor = zlib.compressobj()
    parts = []
    for y in range(height):
        row = bytes([20 + y % 180, 100, 190, 255]) * width
        parts.append(compressor.compress(b'\0' + row))
    parts.append(compressor.flush())
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', b''.join(parts)) + chunk(b'IEND', b'')
    (directory / 'large-fixture.png').write_bytes(png)
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
responsible = lib.responsibility_get_pid_responsible_for_pid
responsible.argtypes = [ctypes.c_int]
responsible.restype = ctypes.c_int
# A raw subprocess inherits the caller's responsibility identity. Launch Services
# isolates the app so its WebKit helpers can be attributed without counting others.
subprocess.run(["open", "-n", "-a", str(args.app.resolve()), "--env", "EASYMARKDOWN_MEMORY_CHECK=" + str(directory),
                "--env", "EASYMARKDOWN_MEMORY_PROFILE=" + ("deep" if args.profile == "image" else args.profile),
                "--env", "EASYMARKDOWN_MEMORY_IMAGE_ONLY=" + ("1" if args.profile == "image" else "0"),
                "--stdout", str(directory / "app.log"), "--stderr", str(directory / "app.log")], check=True)
pid = None

def sample():
    rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    pids = [pid]
    for row in rows.splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) == 2 and "WebKit." in parts[1]:
            helper = int(parts[0])
            if responsible(helper) == pid:
                pids.append(helper)
    output = subprocess.check_output(["footprint", "--noCategories", "-f", "bytes", *map(str, pids)], text=True, stderr=subprocess.STDOUT)
    blocks = re.findall(r"(?m)^([^\n]+) \[(\d+)\]:[^\n]*\n=+\n\nAuxiliary data:\n\s+phys_footprint:\s+(\d+)", output)
    values = {int(process_id): int(size) for _, process_id, size in blocks}
    if pid not in values:
        raise RuntimeError(output)
    # footprint sorts processes by footprint, not by requested PID order.
    peaks = [int(v) for v in re.findall(r"phys_footprint_peak:\s+(\d+)", output)]
    return {"totalMiB": sum(values.values()) / 1048576, "mainMiB": values[pid] / 1048576,
            "processPeakSumMiB": sum(peaks) / 1048576, "pids": pids, "raw": output}

report = {}
try:
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        if (directory / "error").exists():
            raise RuntimeError((directory / "error").read_text())
        if pid is not None:
            import os
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                if not (directory / "done").exists():
                    raise RuntimeError("Profiling app exited early; see app.log")
        for ready in directory.glob("*.ready"):
            name = ready.stem
            if name in report:
                continue
            pid = json.loads(ready.read_text())["pid"]
            if responsible(pid) != pid:
                raise RuntimeError("App responsibility identity is not isolated; cannot attribute helpers")
            samples = []
            for _ in range(3):
                samples.append(sample())
                time.sleep(0.4)
            report[name] = {"totalMiB": round(statistics.median(s["totalMiB"] for s in samples), 2),
                            "mainMiB": round(statistics.median(s["mainMiB"] for s in samples), 2),
                            "checkpoint": json.loads(ready.read_text()), "samples": samples}
            (directory / "report.json").write_text(json.dumps(report, indent=2))
            print(name, report[name]["totalMiB"], "MiB total;", report[name]["mainMiB"], "MiB main", flush=True)
            (directory / (name + ".ack")).touch()
        if (directory / "done").exists():
            break
        time.sleep(0.2)
    else:
        raise TimeoutError("Memory check exceeded 240 seconds")
finally:
    if pid is not None and not (directory / "done").exists():
        import os
        import signal
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
