"""One read-only collector process, owned by the script UI. No downloaded code."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import socket
import sys
import time

def startup_error(kind, error, traceback):
    try:
        directory = Path(sys.argv[sys.argv.index('--data') + 1])
        directory.mkdir(parents=True, exist_ok=True)
        diagnostic = {'ts':int(time.time()*1000), 'stale':True, 'error':kind.__name__}
        if isinstance(error, (ImportError, OSError)): diagnostic['message'] = str(error)[:240]
        (directory/'script-worker.json').write_text(json.dumps(diagnostic, ensure_ascii=False), encoding='utf-8')
    except Exception:
        pass
    sys.__excepthook__(kind, error, traceback)

sys.excepthook = startup_error
import sqlite3
sys.path.insert(0, str(Path(__file__).resolve().parent))
import collector


def configure(data: Path, database: Path | None = None, audit: Path | None = None):
    collector.OUT_DIR = data
    collector.OUT_PATH = data / 'state.json'
    collector.CACHE_PATH = data / 'collector-cache.json'
    collector.CREDITS_PATH = data / 'credits-day.json'
    if database: collector.DB_PATH = database
    if audit: collector.AUDIT_DIR = audit


def atomic_state(path: Path, value: dict):
    temp = path.with_suffix('.script.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False), encoding='utf-8')
    os.replace(temp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--parent', type=int, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--database', type=Path)
    parser.add_argument('--audit', type=Path)
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--port', type=int, default=51927)
    args = parser.parse_args()
    args.data.mkdir(parents=True, exist_ok=True)
    configure(args.data, args.database, args.audit)
    status = args.data / 'script-worker.json'
    lock = None
    last_process_check, running = 0.0, True
    try:
        while args.once or collector._pid_alive(args.parent):
            if lock is None and not args.once:
                candidate = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                try:
                    candidate.bind(('127.0.0.1', args.port))
                    candidate.listen(1)
                    lock = candidate
                except OSError:
                    candidate.close()
                if lock is None:
                    atomic_state(status, {'ts':int(time.time()*1000), 'error':'collector_port_busy'})
                    if args.once: return 2
                    time.sleep(2)
                    continue
            try:
                if time.monotonic() - last_process_check > 5:
                    running = collector._workbuddy_running()
                    last_process_check = time.monotonic()
                state = collector.collect(pid_running=running)
                atomic_state(collector.OUT_PATH, state)
                atomic_state(status, {'ts':state['ts'], 'error':'', 'version':'0.3.1-script'})
            except Exception as error:
                diagnostic = {'ts':int(time.time()*1000), 'stale':True,
                              'error':type(error).__name__}
                if isinstance(error, sqlite3.Error):
                    diagnostic.update(sqlite_code=getattr(error, 'sqlite_errorcode', None),
                                      sqlite_name=getattr(error, 'sqlite_errorname', None),
                                      sqlite_message=str(error)[:240])
                try:
                    atomic_state(collector.OUT_PATH, diagnostic)
                    atomic_state(status, diagnostic)
                except OSError:
                    pass # Keep retrying even when the state directory becomes unwritable.
                if args.once: return 1
            if args.once: return 0
            time.sleep(0.8)
    finally:
        if lock is not None: lock.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
