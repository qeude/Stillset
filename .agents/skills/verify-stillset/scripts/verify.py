#!/usr/bin/env python3
"""Own a verification run and retain its evidence without driving native UI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone


PROJECT = Path(__file__).resolve().parents[4]


def process(pid):
    result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "lstart=", "-o", "comm="], text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else None


def metadata(run):
    return json.loads((run / "run.json").read_text())


def write_metadata(run, value):
    (run / "run.json").write_text(json.dumps(value, indent=2) + "\n")


def build_hash(value):
    app = Path(value["app"])
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(app)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def owns_process(value):
    current = process(value["pid"])
    return current is not None and current == value["process_identity"] and str(Path(value["binary"]).resolve()) in current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--video", type=Path)
    launch = commands.add_parser("record-launch")
    launch.add_argument("run", type=Path)
    launch.add_argument("--pid", type=int, required=True)
    launch.add_argument("--session", required=True)
    doctor = commands.add_parser("doctor")
    doctor.add_argument("run", type=Path)
    action = commands.add_parser("append-action")
    action.add_argument("run", type=Path)
    action.add_argument("--feature", required=True)
    action.add_argument("--entry", required=True)
    action.add_argument("--action", required=True)
    action.add_argument("--observed", required=True)
    snapshot = commands.add_parser("save-ax")
    snapshot.add_argument("run", type=Path)
    snapshot.add_argument("--name", required=True)
    cleanup = commands.add_parser("cleanup")
    cleanup.add_argument("run", type=Path)
    args = parser.parse_args()

    if args.command == "prepare":
        video = (args.video or PROJECT / "Packages/Core/Tests/Fixtures/scroll-stops-navigation-return.mov").resolve()
        if not video.is_file() or video.suffix.lower() not in {".mov", ".mp4"}:
            raise ValueError("A readable local MOV/MP4 fixture is required.")
        run = Path(tempfile.mkdtemp(prefix="stillset-verification-"))
        (run / "evidence").mkdir()
        (run / "scratch").mkdir()
        (run / "scratch/invalid.mp4").write_bytes(b"Stillset verification: invalid video\n")
        (run / "scratch/non-video.png").write_bytes(bytes.fromhex("89504e470d0a1a0a"))
        app = PROJECT / "dist/Stillset.app"
        value = {"project": str(PROJECT), "app": str(app), "binary": str(app / "Contents/MacOS/Stillset"),
                 "video": str(video), "created_at": datetime.now(timezone.utc).isoformat(), "owned": False}
        write_metadata(run, value)
        print(run)
        return

    run = args.run.resolve()
    value = metadata(run)
    if value["project"] != str(PROJECT):
        raise ValueError("The run belongs to another checkout.")
    if args.command == "record-launch":
        identity = process(args.pid)
        if identity is None or str(Path(value["binary"]).resolve()) not in identity:
            raise ValueError("The launch PID does not run this checkout's Stillset binary.")
        value.update(pid=args.pid, launch_session=args.session, process_identity=identity, build_sha256=build_hash(value), owned=True)
        write_metadata(run, value)
        print(json.dumps(value, indent=2))
    elif args.command == "doctor":
        if not value.get("owned") or not owns_process(value):
            raise ValueError("The recorded app instance is not running; do not drive another instance.")
        if build_hash(value) != value["build_sha256"]:
            raise ValueError("The bundle changed after launch; relaunch and record the new instance.")
        print(json.dumps({"healthy": True, "pid": value["pid"], "app": value["app"],
                          "build_sha256": value["build_sha256"], "launch_session": value["launch_session"]}, indent=2))
    elif args.command == "append-action":
        with (run / "evidence/actions.jsonl").open("a") as file:
            file.write(json.dumps({"at": datetime.now(timezone.utc).isoformat(), "feature": args.feature,
                                   "entry": args.entry, "action": args.action, "observed": args.observed}) + "\n")
    elif args.command == "save-ax":
        if Path(args.name).name != args.name or not args.name.endswith(".txt"):
            raise ValueError("Use a plain .txt filename.")
        content = sys.stdin.read()
        if not content.strip():
            raise ValueError("An empty accessibility capture is not evidence.")
        target = run / "evidence" / args.name
        target.write_text(content)
        print(target)
    elif args.command == "cleanup":
        if value.get("owned") and owns_process(value):
            os.kill(value["pid"], signal.SIGTERM)
            deadline = time.monotonic() + 5
            while owns_process(value) and time.monotonic() < deadline:
                time.sleep(0.1)
            if owns_process(value):
                raise ValueError("The owned app has not stopped; use its recorded Xcode session. No forced kill attempted.")
        elif value.get("owned") and process(value["pid"]) is not None:
            raise ValueError("The PID now belongs to another instance; refusing cleanup.")
        shutil.rmtree(run / "scratch", ignore_errors=True)
        value["owned"] = False
        value["cleaned_at"] = datetime.now(timezone.utc).isoformat()
        write_metadata(run, value)
        print(json.dumps({"cleaned": True, "evidence": str(run / "evidence"),
                          "artifacts": sorted(path.name for path in (run / "evidence").iterdir())}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(f"verification: {error}", file=sys.stderr)
        sys.exit(1)
