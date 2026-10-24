"""Synthetic databases only. Never opens the user's WorkBuddy data."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("wb_collector", Path(__file__).parents[1] / "collector.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wb-pet-tests-")
        self.root = Path(self.tmp.name)
        c.DB_PATH = self.root / "with space # 中文.db"
        c.OUT_DIR = self.root
        c.CACHE_PATH = self.root / "cache.json"
        c.CREDITS_PATH = self.root / "credits.json"
        c.AUDIT_DIR = self.root / "audit"
        c._audit_state.clear()
        c._audit_day = ""
        self.now = int(time.time() * 1000)
        with sqlite3.connect(c.DB_PATH) as db:
            db.executescript("""
                CREATE TABLE sessions(id TEXT, title TEXT, custom_title TEXT, status TEXT,
                    unread INT, cwd TEXT, model TEXT, created_at INT, updated_at INT,
                    last_activity_at INT, deleted_at INT, is_playground INT);
                CREATE TABLE session_usage(session_id TEXT, used INT, size INT,
                    updated_at INT, credit_json TEXT);
            """)
            db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                       ("s1", "synthetic task", None, "working", 0, "", "", self.now,
                        self.now, self.now, None, 0))
            db.execute("INSERT INTO session_usage VALUES(?,?,?,?,?)", ("s1", 100, 1000, self.now, "{}"))

    def tearDown(self):
        self.tmp.cleanup()

    def change_status(self, value):
        with sqlite3.connect(c.DB_PATH) as db:
            db.execute("UPDATE sessions SET status=?,updated_at=?", (value, self.now + 1))

    def test_readonly_uri_with_spaces_hash_and_unicode(self):
        db = c._ro_connect(c.DB_PATH)
        try:
            self.assertEqual(db.execute("SELECT count(*) FROM sessions").fetchone()[0], 1)
            with self.assertRaises(sqlite3.OperationalError):
                db.execute("DELETE FROM sessions")
        finally:
            db.close()

    def test_missing_database_not_created(self):
        missing = self.root / "missing.db"
        with self.assertRaises(sqlite3.OperationalError):
            c._ro_connect(missing)
        self.assertFalse(missing.exists())

    def test_missing_database_is_not_empty_success(self):
        c.DB_PATH = self.root / "missing.db"
        with self.assertRaises(FileNotFoundError):
            c.collect()

    def test_first_poll_does_not_replay_history(self):
        self.change_status("completed")
        self.assertIsNone(c.collect()["event"])

    def test_completion_survives_a_missed_ui_poll(self):
        c.collect()
        self.change_status("completed")
        event = c.collect()["event"]
        self.assertEqual(event["type"], "done")
        self.assertEqual(c.collect()["event"], event)
        self.assertEqual(c.collect()["event"]["seq"], 1)

    def test_error_event_is_distinct(self):
        c.collect()
        self.change_status("error")
        self.assertEqual(c.collect()["event"]["type"], "error")

    def test_unchanged_poll_does_not_rewrite_caches(self):
        c.collect()
        before = [p.stat().st_mtime_ns for p in (c.CACHE_PATH, c.CREDITS_PATH)]
        c.collect()
        self.assertEqual(before, [p.stat().st_mtime_ns for p in (c.CACHE_PATH, c.CREDITS_PATH)])

    def test_daily_credit_increment_and_reset(self):
        self.assertEqual(c.update_daily_credits({"s1": 10})[0], 0)
        self.assertEqual(c.update_daily_credits({"s1": 12})[0], 2)
        self.assertEqual(c.update_daily_credits({"s1": 2})[0], 2)
        self.assertEqual(c.update_daily_credits({"s1": 3})[0], 3)

    def test_approval_incomplete_line_and_later_decision(self):
        from datetime import date
        c.AUDIT_DIR.mkdir()
        path = c.AUDIT_DIR / (date.today().isoformat() + ".jsonl")
        event = {"toolCallId": "t1", "eventType": "file.needs-approval", "timestamp": self.now}
        raw = json.dumps(event).encode()
        path.write_bytes(raw[:20])
        self.assertEqual(c.pending_approvals(self.now), [])
        with path.open("ab") as f:
            f.write(raw[20:] + b"\n")
        self.assertEqual(len(c.pending_approvals(self.now)), 1)
        with path.open("ab") as f:
            f.write(json.dumps({"toolCallId": "t1", "eventType": "file.approved", "decision": "allow"}).encode() + b"\n")
        self.assertEqual(c.pending_approvals(self.now), [])


if __name__ == "__main__":
    unittest.main()
