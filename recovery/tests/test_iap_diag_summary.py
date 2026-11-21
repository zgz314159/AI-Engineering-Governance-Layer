"""Task-bound, read-only access to existing phase metadata (no root/model calls)."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('diag_summary',Path(__file__).resolve().parents[1]/'iap_diag_summary.py')
summary=importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class DiagnosticSummaryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='calendar-diag-test-',dir='/var/tmp')
        self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
        self.registry=self.base/'registry.json'
        self.registry.write_text(json.dumps({'CAL-DIAG':{'contract_package':'/trusted/CAL-DIAG'}}))
        self.registry.chmod(0o644)
        self.root=self.base/'diagnostics';self.root.mkdir(mode=0o700)
        self.sink=self.root/'CAL-DIAG';self.sink.mkdir(mode=0o700)
        self.events=self.sink/'events.jsonl'
        self.events.write_text(json.dumps({'task':'CAL-DIAG','phase':'upstream_response',
            'status':200,'bytes':17,'arg':'SECRET_BODY token=SECRET_TOKEN addr=1 family=IPv4 elapsed_ms=9'})+'\n')
        self.events.chmod(0o600)

    def resolve(self,task='CAL-DIAG'):
        return summary.registered_events(task,registry=self.registry,diag_root=self.root,required_uid=os.getuid())

    def test_registered_task_summary_does_not_expose_raw_argument(self):
        path=self.resolve()
        output=io.StringIO()
        before=self.events.read_bytes()
        with contextlib.redirect_stdout(output):
            self.assertEqual(summary.summarise(str(path)),0)
        self.assertIn('phase=upstream_response',output.getvalue())
        self.assertIn('elapsed_ms=9',output.getvalue())
        self.assertNotIn('SECRET',output.getvalue())
        self.assertEqual(before,self.events.read_bytes())

    def test_unregistered_or_path_escape_is_refused(self):
        for task in ('OTHER','../CAL-DIAG','/tmp','CAL-DIAG/../OTHER',''):
            with self.subTest(task=task),self.assertRaises(ValueError):
                self.resolve(task)

    def test_tool_outcome_is_visible_without_command_or_result_body(self):
        self.events.write_text(json.dumps({'phase':'tool_post_observe','seq':3,
            'arg':'src=hook trust=diagnostic when=post corr=1 tool=terminal '
                  'status=ERROR err=PermissionError duration_ms=4 exit=-1',
            'command':'SECRET_COMMAND','result':'SECRET_RESULT'})+'\n')
        output=io.StringIO()
        before=self.events.read_bytes()
        with contextlib.redirect_stdout(output):
            self.assertEqual(summary.summarise(str(self.resolve())),0)
        self.assertIn('tool=terminal tool_status=ERROR tool_error=PermissionError duration_ms=4 exit=-1',output.getvalue())
        self.assertNotIn('SECRET',output.getvalue())
        self.assertEqual(before,self.events.read_bytes())

    def test_unknown_outcomes_stay_unknown_and_pre_is_not_an_exit(self):
        prefix='src=hook trust=diagnostic when='
        self.assertEqual(summary.tool_fields('tool_post_observe',prefix+'post corr=1 tool=other '
            'status=UNKNOWN err=UNKNOWN duration_ms=UNKNOWN exit=UNKNOWN'),
            ['tool=other','tool_status=UNKNOWN','tool_error=UNKNOWN','duration_ms=UNKNOWN','exit=UNKNOWN'])
        self.assertEqual(summary.tool_fields('tool_pre_observe',prefix+'pre corr=1 tool=read_file '
            'status=OK err=UNKNOWN'),['tool=read_file','tool_status=OK','tool_error=UNKNOWN'])

    def test_malformed_or_injected_tool_record_never_exposes_free_text(self):
        valid='src=hook trust=diagnostic when=post corr=1 tool=terminal status=ERROR err=OSError duration_ms=4 exit=1'
        for arg in (valid+' SECRET',valid.replace('tool=terminal','tool=SECRET'),
                    valid.replace('err=OSError','err=SECRET'),valid.replace('exit=1','exit=1SECRET'),
                    valid.replace('when=post','when=pre'),valid.replace('corr=1','corr=0')):
            with self.subTest(arg=arg):
                self.assertEqual(summary.tool_fields('tool_post_observe',arg),['tool_metadata=UNKNOWN'])
        self.assertEqual(summary.tool_fields('upstream_response',valid),[])

    def test_wrong_owner_is_refused(self):
        with self.assertRaisesRegex(ValueError,'UNTRUSTED'):
            summary.registered_events('CAL-DIAG',registry=self.registry,diag_root=self.root,required_uid=os.getuid()+1)

    def test_symlink_sink_is_refused(self):
        self.events.unlink();self.sink.rmdir()
        self.sink.symlink_to(self.base,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'UNTRUSTED'):
            self.resolve()

    def test_symlink_event_file_is_refused(self):
        self.events.unlink();self.events.symlink_to(self.registry)
        with self.assertRaisesRegex(ValueError,'UNTRUSTED'):
            self.resolve()

    def test_writable_sink_is_refused(self):
        for path in (self.registry,self.root,self.sink,self.events):
            mode=path.stat().st_mode & 0o777
            path.chmod(mode|0o020)
            with self.subTest(path=path),self.assertRaisesRegex(ValueError,'UNTRUSTED'):
                self.resolve()
            path.chmod(mode)

    def test_missing_or_oversized_event_file_is_not_success(self):
        self.events.unlink()
        with self.assertRaises(FileNotFoundError):
            self.resolve()
        with self.events.open('wb') as f:
            f.truncate(8*1024*1024+1)
        self.events.chmod(0o600)
        with self.assertRaisesRegex(ValueError,'TOO_LARGE'):
            self.resolve()


if __name__=='__main__':
    unittest.main()
