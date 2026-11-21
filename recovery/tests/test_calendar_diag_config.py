"""The reusable diagnostic config may change task IDs, never launcher code."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class CalendarDiagnosticConfigTests(unittest.TestCase):
    def setUp(self):
        prep=Path(__file__).resolve().parents[1]/'calendar_wpf_001/prepare.sh'
        self.validator=prep.read_text().split('# DIAG_CONFIG_VALIDATOR_BEGIN\n',1)[1].split('# DIAG_CONFIG_VALIDATOR_END',1)[0]
        self.source=Path('/usr/local/lib/aegl-model/aegl-hermes-sandbox').read_text()
        self.line=next(l for l in self.source.splitlines(keepends=True) if l.startswith('DIAG_ENABLED_TASKS="'))
        self.body_hash=hashlib.sha256(self.source.replace(self.line,'DIAG_ENABLED_TASKS="<REGISTERED_TASK_CONFIG>"\n',1).encode()).hexdigest()
        self.registry=json.loads(Path('/var/lib/aegl-model/registry.json').read_text())

    def check(self,text,registry=None):
        with tempfile.TemporaryDirectory(prefix='calendar-config-',dir='/var/tmp') as d:
            root=Path(d);(root/'launcher').write_text(text)
            (root/'registry.json').write_text(json.dumps(registry if registry is not None else self.registry))
            return subprocess.run(['python3','-B','-c',self.validator,str(root/'launcher'),
                str(root/'registry.json'),self.body_hash],capture_output=True,text=True,timeout=5)

    def test_existing_trusted_install_is_reusable(self):
        self.assertEqual(self.check(self.source).returncode,0)

    def test_registered_configuration_extension_is_valid(self):
        line=self.line[:-3]+' CAL-TEST-NEXT "\n'
        registry={**self.registry,'CAL-TEST-NEXT':{'contract_package':'/trusted/test'}}
        self.assertEqual(self.check(self.source.replace(self.line,line,1),registry).returncode,0)

    def test_any_other_launcher_change_is_refused(self):
        self.assertNotEqual(self.check(self.source+'\necho UNDECLARED\n').returncode,0)

    def test_unregistered_task_is_refused(self):
        line=self.line[:-3]+' CAL-UNREGISTERED "\n'
        self.assertNotEqual(self.check(self.source.replace(self.line,line,1)).returncode,0)

    def test_duplicate_or_shell_syntax_is_refused(self):
        for item in ('SYSTEM-E2E-005','$(id)','BAD;COMMAND'):
            with self.subTest(item=item):
                line=self.line[:-3]+' '+item+' "\n'
                self.assertNotEqual(self.check(self.source.replace(self.line,line,1)).returncode,0)


if __name__=='__main__': unittest.main()
