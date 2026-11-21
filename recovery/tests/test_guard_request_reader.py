"""Focused checks for reusing the existing reader on the failed registered task."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('reader',Path(__file__).resolve().parents[1]/'read_004_guard_args.py')
reader=importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class GuardRequestReaderTests(unittest.TestCase):
    def test_command_metadata_distinguishes_contract_and_source_bases_without_raw_text(self):
        package=Path('/trusted/App/reports/contracts/TASK')
        context={'source_root':'/task','read_first':[{'path':'project/src/Parser.cs'}]}
        result=reader.command_metadata('sha256sum manifest.json && cat "$HERMES_CONTRACT_PACKAGE/project-context.json" '
            '/task/project/src/Parser.cs SECRET_TOKEN',package,context)
        self.assertEqual(result['known_shell_words'],['cat','sha256sum'])
        self.assertEqual(result['declared_file_refs'],[
            {'artifact':'manifest.json','base':'CWD_RELATIVE'},
            {'artifact':'project-context.json','base':'CONTRACT_ENV'},
            {'read_first_index':0,'base':'SOURCE_ABSOLUTE'}])
        self.assertNotIn('SECRET',json.dumps(result))

    def test_malformed_or_unknown_command_is_not_exposed(self):
        self.assertEqual(reader.command_metadata("cat 'SECRET",Path('/trusted'),{}),{'state':'UNPARSEABLE'})
        self.assertEqual(reader.command_metadata('SECRET_TOKEN',Path('/trusted'),{}),
                         {'known_shell_words':[],'declared_file_refs':[]})

    def test_binding_requires_registered_task_and_trusted_exact_package(self):
        with tempfile.TemporaryDirectory(dir='/var/tmp',prefix='guard-reader-') as d:
            base=Path(d)
            registry=base/'registry.json'
            trusted=base/'trusted'
            package=trusted/'App/reports/contracts/TASK'
            package.mkdir(parents=True)
            for name in ('verification-intent.json','project-context.json'):
                (package/name).write_text('{}')
            diag=base/'diag'
            (diag/'TASK').mkdir(parents=True)
            registry.write_text(json.dumps({'TASK':{'contract_package':str(package)}}))
            for path in base.rglob('*'):
                path.chmod(0o755 if path.is_dir() else 0o644)
            def resolve(task='TASK'):
                return reader.bind_registered(task,registry=registry,diag_root=diag,
                    trusted_root=trusted,required_uid=os.getuid())
            self.assertEqual(resolve(),(diag/'TASK',package))
            for task in ('OTHER','../TASK','/TASK'):
                with self.subTest(task=task),self.assertRaises(ValueError):resolve(task)
            (package/'project-context.json').chmod(0o666)
            with self.assertRaises(ValueError):resolve()
            (package/'project-context.json').chmod(0o644)
            registry.write_text(json.dumps({'TASK':{'contract_package':str(package.parent/'OTHER')}}))
            with self.assertRaises(ValueError):resolve()
            registry.write_text(json.dumps({'TASK':{'contract_package':str(package)}}))
            (diag/'TASK').rmdir()
            (diag/'TASK').symlink_to(package,target_is_directory=True)
            with self.assertRaises(ValueError):resolve()


if __name__=='__main__':unittest.main()
