from pathlib import Path
from contextlib import closing
import ctypes
import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'app'
PYTHON=ROOT/'runtime/python.exe'


class ScriptPetTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='wb-script-')
        self.root=Path(self.temp.name)
        self.database=self.root/'space # 中文.db'
        self.data=self.root/'data'
        self.audit=self.root/'audit'
        self.audit.mkdir()
        self.processes=[]
        now=int(time.time()*1000)
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.executescript('''
              CREATE TABLE sessions(id TEXT,title TEXT,custom_title TEXT,status TEXT,unread INT,cwd TEXT,model TEXT,
                created_at INT,updated_at INT,last_activity_at INT,deleted_at INT,is_playground INT);
              CREATE TABLE session_usage(session_id TEXT,used INT,size INT,updated_at INT,credit_json TEXT);
            ''')
            connection.execute('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                ('s','fixture',None,'working',0,'','',now,now,now,None,0))
            connection.execute('INSERT INTO session_usage VALUES(?,?,?,?,?)',('s',100,1000,now,'{"r":1.25}'))

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None: process.kill()
            process.wait(timeout=5)
        self.temp.cleanup()

    def command(self, *extra):
        return [str(PYTHON),'-I','-S',str(APP/'worker.py'),'--parent',str(os.getpid()),
                '--data',str(self.data),'--database',str(self.database),'--audit',str(self.audit),*map(str,extra)]

    def once(self, expected=0):
        completed=subprocess.run(self.command('--once'),capture_output=True,text=True,encoding='utf-8',timeout=10)
        self.assertEqual(completed.returncode,expected,completed.stderr)
        return json.loads((self.data/'state.json').read_text(encoding='utf-8'))

    def sql(self, statement):
        with closing(sqlite3.connect(self.database)) as connection, connection:connection.execute(statement)

    def wait(self, condition, seconds=6):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            try:
                if condition(): return
            except (OSError,ValueError):pass
            time.sleep(0.05)
        self.fail('Worker did not reach expected state')

    def state(self):return json.loads((self.data/'state.json').read_text(encoding='utf-8'))

    def start(self, *extra):
        process=subprocess.Popen(self.command(*extra),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.processes.append(process)
        return process

    def test_runtime_and_native_version(self):
        completed=subprocess.run([str(PYTHON),'-I','-S','-c','import sys,sqlite3,ctypes;print(sys.version.split()[0]);print(sqlite3.sqlite_version)'],capture_output=True,text=True,timeout=10)
        self.assertEqual(completed.returncode,0,completed.stderr)
        self.assertEqual(completed.stdout.splitlines()[1],'3.53.4')

    def test_paths_readonly_and_usage(self):
        before=hashlib.sha256(self.database.read_bytes()).digest()
        state=self.once()
        self.assertEqual(state['active']['title'],'fixture')
        self.assertEqual(state['usage']['session_used'],100)
        self.assertEqual(hashlib.sha256(self.database.read_bytes()).digest(),before)

    def test_absent_unread_column(self):
        self.sql('ALTER TABLE sessions DROP COLUMN unread')
        state=self.once()
        self.assertEqual(state['active']['unread'],0)
        self.assertEqual(state['usage']['session_used'],100)

    def test_existing_unread(self):
        self.sql("UPDATE sessions SET status='completed',unread=3")
        self.assertEqual(self.once()['active']['unread'],3)

    def test_completion_persists(self):
        self.once()
        self.sql("UPDATE sessions SET status='completed'")
        state=self.once()
        self.assertEqual(state['event']['type'],'done')
        self.assertEqual(self.once()['event']['seq'],state['event']['seq'])

    def test_missing_database_and_recovery(self):
        saved=self.database.with_suffix('.saved')
        self.database.rename(saved)
        self.assertTrue(self.once(1)['stale'])
        self.assertFalse(self.database.exists())
        saved.rename(self.database)
        self.assertNotIn('stale',self.once())

    def test_schema_error_diagnostic(self):
        self.sql('ALTER TABLE sessions RENAME TO hidden_sessions')
        state=self.once(1)
        self.assertTrue(state['stale'])
        self.assertEqual(state['sqlite_code'],1)

    def test_port_waiter_does_not_overwrite(self):
        with socket.socket() as holder:
            holder.bind(('127.0.0.1',0));holder.listen()
            port=holder.getsockname()[1]
            self.data.mkdir()
            path=self.data/'state.json';path.write_text('{"marker":1}',encoding='utf-8')
            process=self.start('--port',port)
            self.wait(lambda:json.loads((self.data/'script-worker.json').read_text())['error']=='collector_port_busy')
            self.assertEqual(path.read_text(),'{"marker":1}')
        self.wait(lambda:'active' in self.state())
        self.assertIsNone(process.poll())

    def test_parent_exit_stops_worker(self):
        parent=subprocess.Popen([str(PYTHON),'-I','-S','-c','import time;time.sleep(2)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.processes.append(parent)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
        command=self.command('--port',port)
        command[command.index('--parent')+1]=str(parent.pid)
        worker=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.processes.append(worker)
        self.wait(lambda:(self.data/'state.json').exists())
        parent.wait(timeout=5)
        self.assertEqual(worker.wait(timeout=5),0)
        with socket.socket() as probe:probe.bind(('127.0.0.1',port))

    def test_continuous_failure_recovers(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
        self.start('--port',port)
        self.wait(lambda:'active' in self.state())
        saved=self.database.with_suffix('.saved');self.database.rename(saved)
        self.wait(lambda:self.state().get('stale'))
        saved.rename(self.database)
        self.wait(lambda:not self.state().get('stale'))
        self.wait(lambda:json.loads((self.data/'script-worker.json').read_text())['error']=='')


if __name__=='__main__':unittest.main(verbosity=2)
