#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WorkBuddy 桌宠数据采集器。

只读 WorkBuddy 本地会话库（workbuddy.db），把「当前任务状态 + 用量」写到
%LOCALAPPDATA%\\WbPet\\state.json，供 WPF 前端每 400ms 读取。

设计上照抄 codex-white-dragon-pet 的分层：采集器（Python，无第三方包）+ 渲染层（WPF）。
不联网、不改 WorkBuddy 任何数据。
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
DB_PATH = HOME / ".workbuddy" / "workbuddy.db"
OUT_DIR = Path(os.environ.get("LOCALAPPDATA", str(HOME / "AppData/Local"))) / "WbPet"
OUT_PATH = OUT_DIR / "state.json"
CACHE_PATH = OUT_DIR / "collector-cache.json"
CREDITS_PATH = OUT_DIR / "credits-day.json"
AUDIT_DIR = HOME / ".workbuddy" / "audit-log"
APPROVAL_TTL_MS = 15 * 60 * 1000

# 审计日志增量读取状态：path -> {off, pending, decided}
_audit_state: dict[str, dict] = {}
_audit_day = ""

# 只关心最近一段时间还在活动的会话，避免把一个月前的任务当成"刚刚完成"
WATCH_WINDOW = timedelta(hours=12)

STATUS_MAP = {
    "working": "working",
    "completed": "done",
    "error": "error",
    "pending": "pending",
    "idle": "idle",
}


def _ro_connect(path: Path) -> sqlite3.Connection:
    """始终以只读 URI 打开；失败就报告中断，不退回可写连接。"""
    conn = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=2.0)
    try:
        conn.execute("PRAGMA query_only=ON")
        conn.execute("select 1 from sessions limit 1")
        return conn
    except BaseException:
        conn.close()
        raise


def _load_cache() -> dict:
    try:
        return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {"statuses": {}, "seq": 0}


def _save_cache(cache: dict) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    content = json.dumps(cache, ensure_ascii=False)
    if CACHE_PATH.exists() and CACHE_PATH.read_text(encoding="utf-8") == content:
        return
    tmp = CACHE_PATH.with_suffix(".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, CACHE_PATH)


def _credits(raw: str | None) -> float:
    """credit_json 形如 {"<requestId>": 1.16, ...}，键是请求 ID，值是积分消耗。"""
    if not raw:
        return 0.0
    try:
        data = json.loads(raw)
        return round(sum(float(v) for v in data.values() if isinstance(v, (int, float))), 2)
    except Exception:
        return 0.0


def pending_approvals(now_ms: int) -> list[dict]:
    """从审计日志里找"正等你点确认"的请求。

    WorkBuddy 不把待确认状态写进数据库，但会在 audit-log 里成对落两条：
      <category>.needs-approval（decision=info） → <category>.approved/denied
    同一个 toolCallId 只有前者没有后者，就是还挂着。用增量读文件的方式跟，避免整份重扫。
    """
    from datetime import date

    global _audit_day
    day = date.today().isoformat()
    if day != _audit_day:
        _audit_state.clear()
        _audit_day = day

    files = []
    main = AUDIT_DIR / f"{day}.jsonl"
    if main.exists():
        files.append(main)
    spool = AUDIT_DIR / "spool"
    if spool.is_dir():
        files.extend(sorted(spool.glob(f"audit-spool-*-{day}.jsonl")))

    for path in files:
        key = str(path)
        st = _audit_state.setdefault(key, {"off": 0, "pending": {}, "decided": set()})
        try:
            size = path.stat().st_size
            if size < st["off"]:                      # 文件被截断/轮转，重头读
                st["off"], st["pending"], st["decided"] = 0, {}, set()
            if size == st["off"]:
                continue
            with open(path, "rb") as fh:
                fh.seek(st["off"])
                data = fh.read()
            cut = data.rfind(b"\n")
            if cut < 0:
                continue                              # 还没写完一整行
            chunk = data[:cut + 1]
            st["off"] += len(chunk)
            for raw in chunk.splitlines():
                if not raw.strip():
                    continue
                try:
                    d = json.loads(raw.decode("utf-8", "ignore"))
                except Exception:
                    continue
                tid = d.get("toolCallId")
                et = d.get("eventType") or ""
                if not tid or not et:
                    continue
                if et.endswith(".needs-approval"):
                    params = d.get("messageParams") or {}
                    raw_paths = str(params.get("paths") or params.get("command") or "")
                    first = raw_paths.split(",")[0].strip()
                    st["pending"][tid] = {
                        "ts": int(d.get("timestamp") or 0),
                        "kind": et.split(".")[0],
                        "label": os.path.basename(first) if first else et.split(".")[0],
                    }
                elif str(d.get("decision") or "info") not in ("info", "none", ""):
                    st["decided"].add(tid)
        except Exception:
            continue

    # 清掉已经不存在的文件
    for key in list(_audit_state):
        if key not in [str(f) for f in files]:
            _audit_state.pop(key, None)

    merged: dict[str, dict] = {}
    decided: set[str] = set()
    for st in _audit_state.values():
        merged.update(st["pending"])
        decided |= st["decided"]

    out = [v for tid, v in merged.items()
           if tid not in decided and now_ms - v["ts"] < APPROVAL_TTL_MS]
    out.sort(key=lambda x: x["ts"], reverse=True)
    return out


def update_daily_credits(totals: dict[str, float]) -> tuple[float, str]:
    """按日累计积分。

    workbuddy.db 里只有"每个会话累计消耗"，没有单条请求的时间，无法按天回溯。
    所以这里用增量记账：每轮记下各会话的累计值，今天新增 = 本轮累计 - 上轮累计，
    累加到 credits-day.json。跨天自动清零。统计起点记在 since 里，前端要如实标注。
    """
    from datetime import date
    today = date.today().isoformat()
    now_iso = datetime.now().strftime("%m-%d %H:%M")

    state: dict = {}
    try:
        if CREDITS_PATH.exists():
            state = json.loads(CREDITS_PATH.read_text(encoding="utf-8"))
            if not isinstance(state, dict):
                state = {}
    except Exception:
        state = {}

    if state.get("date") != today:
        state = {"date": today, "base": totals, "today": 0.0, "since": now_iso}
    else:
        base = state.get("base") or {}
        added = 0.0
        for sid, tot in totals.items():
            prev = float(base.get(sid, 0) or 0)
            if tot > prev:           # 库被清理导致变小时不记负数，直接重设基线
                added += tot - prev
        state["today"] = round(float(state.get("today", 0) or 0) + added, 2)
        state["base"] = totals
        state.setdefault("since", now_iso)

    try:
        CREDITS_PATH.parent.mkdir(parents=True, exist_ok=True)
        content = json.dumps(state, ensure_ascii=False)
        if not CREDITS_PATH.exists() or CREDITS_PATH.read_text(encoding="utf-8") != content:
            tmp = CREDITS_PATH.with_suffix(".tmp")
            tmp.write_text(content, encoding="utf-8")
            os.replace(tmp, CREDITS_PATH)
    except Exception:
        pass
    return round(float(state.get("today", 0) or 0), 2), str(state.get("since", ""))


def _ms(ts) -> int:
    try:
        return int(ts or 0)
    except Exception:
        return 0


def collect(pid_running: bool = True) -> dict:
    now = datetime.now()
    now_ms = int(now.timestamp() * 1000)
    today_start = datetime(now.year, now.month, now.day)
    today_ms = int(today_start.timestamp() * 1000)
    cache = _load_cache()
    prev_statuses: dict = cache.get("statuses", {})
    seq = int(cache.get("seq", 0))

    sessions: list[dict] = []
    usage_by_id: dict[str, dict] = {}
    event = None

    if not DB_PATH.is_file():
        raise FileNotFoundError("WorkBuddy database is not available")
    if DB_PATH.exists():
        conn = _ro_connect(DB_PATH)
        try:
            conn.execute("BEGIN")  # sessions 与 usage 使用同一个只读快照。
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT id, title, custom_title, status, unread, cwd, model,
                       created_at, updated_at, last_activity_at, deleted_at, is_playground
                FROM sessions
                WHERE deleted_at IS NULL
                ORDER BY COALESCE(last_activity_at, updated_at, created_at) DESC
                LIMIT 12
                """
            ).fetchall()
            for r in rows:
                sessions.append(
                    {
                        "id": r["id"],
                        "title": (r["custom_title"] or r["title"] or "未命名任务").strip(),
                        "status": STATUS_MAP.get(str(r["status"]).lower(), str(r["status"])),
                        "unread": int(r["unread"] or 0),
                        "cwd": r["cwd"] or "",
                        "model": r["model"] or "",
                        "created_at": _ms(r["created_at"]),
                        "updated_at": _ms(r["updated_at"]),
                        "last_activity_at": _ms(r["last_activity_at"]),
                    }
                )
            for u in conn.execute("SELECT session_id, used, size, updated_at, credit_json FROM session_usage"):
                usage_by_id[u["session_id"]] = {
                    "used": int(u["used"] or 0),
                    "size": int(u["size"] or 0),
                    "updated_at": _ms(u["updated_at"]),
                    "credits": _credits(u["credit_json"]),
                }
        finally:
            conn.close()

    # ---- 事件检测：working -> done / error ----
    watch_after = now - WATCH_WINDOW
    for s in sessions:
        last = datetime.fromtimestamp(max(s["updated_at"], s["last_activity_at"]) / 1000)
        if last < watch_after:
            continue
        old = prev_statuses.get(s["id"])
        if old == "working" and s["status"] in ("done", "error"):
            cand = {
                "type": "done" if s["status"] == "done" else "error",
                "session_id": s["id"],
                "title": s["title"],
                "at": max(s["updated_at"], s["last_activity_at"]),
            }
            if event is None or cand["at"] > event["at"]:
                event = cand

    statuses = {s["id"]: s["status"] for s in sessions}
    # 首次运行只记基线，不补发历史"完成"事件
    first_run = not prev_statuses
    if event is not None and first_run:
        event = None
    if event is not None:
        seq += 1
        event["seq"] = seq
    cache["statuses"] = statuses
    cache["seq"] = seq
    if event is not None:
        cache["event"] = event
    else:
        event = cache.get("event")  # 保留序号，避免 UI 错过两次轮询之间的事件。
    try:
        _save_cache(cache)
    except Exception:
        pass

    active = next((s for s in sessions if s["status"] == "working"), None)
    if active is None:
        active = sessions[0] if sessions else None

    pend = pending_approvals(now_ms)
    totals = {sid: round(u["credits"], 2) for sid, u in usage_by_id.items()}
    credits_today, credits_since = update_daily_credits(totals)
    active_usage = usage_by_id.get(active["id"]) if active else None

    return {
        "ts": int(time.time() * 1000),
        "app_running": bool(pid_running),
        "active": active,
        "usage": {
            "session_used": (active_usage or {}).get("used", 0),
            "session_size": (active_usage or {}).get("size", 0),
            "session_credits": (active_usage or {}).get("credits", 0.0),
            "credits_today": credits_today,
            "credits_since": credits_since,
        },
        "recent": sessions[:5],
        "pending": {
            "count": len(pend),
            "label": pend[0]["label"] if pend else "",
            "kind": pend[0]["kind"] if pend else "",
            "since": datetime.fromtimestamp(pend[0]["ts"] / 1000).strftime("%H:%M") if pend else "",
        },
        "event": event,
        "db_ok": DB_PATH.exists(),
    }


def _processes() -> dict[int, str]:
    """纯 ctypes 枚举进程。绝不能用 tasklist：pythonw 没有控制台，
    启动控制台子进程会让 Windows 新开一个黑窗，每查一次闪一次。"""
    import ctypes
    from ctypes import wintypes

    TH32CS_SNAPPROCESS = 0x00000002

    class PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD),
            ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD),
            ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
            ("th32ModuleID", wintypes.DWORD),
            ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD),
            ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", wintypes.DWORD),
            ("szExeFile", wintypes.WCHAR * 260),
        ]

    kernel32 = ctypes.windll.kernel32
    kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
    kernel32.Process32FirstW.restype = wintypes.BOOL
    kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
    kernel32.Process32NextW.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    snap = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == wintypes.HANDLE(-1).value:
        return {}
    out: dict[int, str] = {}
    entry = PROCESSENTRY32W()
    entry.dwSize = ctypes.sizeof(entry)
    try:
        ok = kernel32.Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            out[int(entry.th32ProcessID)] = entry.szExeFile
            ok = kernel32.Process32NextW(snap, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snap)
    return out


def _workbuddy_running() -> bool:
    try:
        return any(name.lower() == "workbuddy.exe" for name in _processes().values())
    except Exception:
        return True


def _pid_alive(pid: int) -> bool:
    try:
        return pid in _processes()
    except Exception:
        return True


def _acquire_singleton() -> socket.socket | None:
    """占一个本地端口当互斥体：桌宠重复拉起采集器时，后来的直接退出。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 51927))
        s.listen(1)
        return s
    except OSError:
        s.close()
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="采一次就退出（自检用）")
    ap.add_argument("--out", default=None)
    ap.add_argument("--interval", type=float, default=0.8)
    ap.add_argument("--parent", type=int, default=0, help="桌宠进程 PID；它退出后采集器也退出")
    args = ap.parse_args()
    if not 0.2 <= args.interval <= 60:
        ap.error("--interval must be between 0.2 and 60 seconds")

    global OUT_PATH
    OUT_PATH = Path(args.out) if args.out else OUT_PATH
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)

    lock = None if args.once else _acquire_singleton()
    if lock is None and not args.once:
        print("collector already running")
        return 0

    if args.once:
        state = collect(pid_running=_workbuddy_running())
        OUT_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(state, ensure_ascii=False, indent=2))
        return 0

    running_flag = True
    last_check = 0.0
    wb_absent_since = 0.0
    while True:
        # 父进程（桌宠）没了就跟着退，别留下孤儿进程
        if args.parent and not _pid_alive(args.parent):
            break
        try:
            if time.time() - last_check > 5:
                running_flag = _workbuddy_running()
                last_check = time.time()
                if running_flag:
                    wb_absent_since = 0.0
                elif not wb_absent_since:
                    wb_absent_since = time.time()
                # WorkBuddy 长时间不在（比如桌宠被强杀）也别一直跑
                if wb_absent_since and time.time() - wb_absent_since > 90:
                    break
            state = collect(pid_running=running_flag)
            tmp = OUT_PATH.with_suffix(".tmp")
            tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
            os.replace(tmp, OUT_PATH)
        except Exception as exc:  # 采集失败不该让桌宠跟着退出
            # 保留上一份好数据，只打上 stale 标记；否则前端会把"读不到"误判成"WorkBuddy 没开着"
            prev: dict = {}
            try:
                if OUT_PATH.exists():
                    prev = json.loads(OUT_PATH.read_text(encoding="utf-8"))
                    if not isinstance(prev, dict):
                        prev = {}
            except Exception:
                prev = {}
            prev["ts"] = int(time.time() * 1000)
            prev["error"] = str(exc)[:200]
            prev["stale"] = True
            try:
                tmp = OUT_PATH.with_suffix(".tmp")
                tmp.write_text(json.dumps(prev, ensure_ascii=False), encoding="utf-8")
                os.replace(tmp, OUT_PATH)
            except Exception:
                pass
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
