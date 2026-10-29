#!/usr/bin/env python3
"""Export a finished pair of commits to a new, externally anchored package.

Run as the developer, not root. Reads only git objects; refuses an existing output.
The package contains source from the chosen AEGL commit and full candidate history
bundles with baseline prerequisites. It does not access credentials or host state.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def git(repo, *args):
    return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-C', str(repo), *args],
                          capture_output=True, check=True).stdout


def build(aegl, stack, aegl_tip, stack_tip, out):
    if out.exists() or out.is_symlink():
        raise SystemExit('OUTPUT_EXISTS=' + str(out))
    for repo, tip, base in [(aegl, aegl_tip, '19c069d318ac5846864224d7950c9191fa900b2a'),
                            (stack, stack_tip, '3a93066de216e731900870d145032bbb995fb92f')]:
        git(repo, 'merge-base', '--is-ancestor', base, tip)
        if git(repo, 'rev-parse', tip).decode().strip() != tip:
            raise SystemExit('FULL_COMMIT_OID_REQUIRED')
    out.mkdir(mode=0o700)
    files = {
        'iap_delivery.py': 'recovery/iap_delivery.py',
        'bootstrap.sh': 'recovery/iap-delivery-bootstrap.sh',
        'install-model-task-registry.sh': 'recovery/install-model-task-registry.sh',
        'payload/aegl/bin/aegl-model-task': 'bin/aegl-model-task',
        'payload/aegl/recovery/model_task_registry.py': 'recovery/model_task_registry.py',
        'payload/aegl/recovery/gt1-install-manifest.txt': 'recovery/gt1-install-manifest.txt',
        'README.md': 'docs/IAP-DELIVERY.md',
    }
    for dst, src in files.items():
        target=out/dst; target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_bytes(git(aegl, 'show', aegl_tip + ':' + src)); target.chmod(0o600)
    (out/'bundle').mkdir(mode=0o700)
    release={'schema':1,'repos':[], 'source_files':files}
    for name, repo, tip, branch, base in [
        ('stack',stack,stack_tip,'master','3a93066de216e731900870d145032bbb995fb92f'),
        ('aegl',aegl,aegl_tip,'main','19c069d318ac5846864224d7950c9191fa900b2a')]:
        # A disposable ref is required to name HEAD in the bundle without switching
        # the developer's checkout. Use a separate temporary bare repository.
        import tempfile
        with tempfile.TemporaryDirectory(prefix='iap-bundle-', dir='/var/tmp') as t:
            git(repo, 'clone', '--bare', '--no-local', '--', str(repo), t+'/repo')
            git(t+'/repo', 'update-ref', '--no-deref', 'HEAD', tip)
            git(t+'/repo', 'bundle', 'create', str((out/'bundle'/(name+'.bundle')).resolve()), base+'..HEAD')
        release['repos'].append({'name':name,'path':'/home/zhong/Projects/'+(
            'Google-Android-Agent-Development-Stack' if name=='stack' else 'AI-Engineering-Governance-Layer'),
            'target_ref':'refs/heads/'+branch,'base':base,'final':tip,'bundle':'bundle/'+name+'.bundle',
            'gitlinks':{'references/architecture-templates':'4a3b2a141f457f1312c8dc52d6cbea6c9592af72'} if name=='stack' else {}})
    (out/'release.json').write_text(json.dumps(release,indent=2,sort_keys=True)+'\n')
    rows=[]
    for p in sorted(out.rglob('*')):
        if p.is_file(): rows.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(out).as_posix())
    (out/'MANIFEST.sha256').write_text('\n'.join(rows)+'\n')
    print('PACKAGE='+str(out))
    print('PACKAGE_ANCHOR='+hashlib.sha256((out/'MANIFEST.sha256').read_bytes()).hexdigest())
    print('BOOTSTRAP_SHA256='+hashlib.sha256((out/'bootstrap.sh').read_bytes()).hexdigest())


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--aegl',type=Path,required=True); p.add_argument('--stack',type=Path,required=True)
    p.add_argument('--aegl-tip',required=True); p.add_argument('--stack-tip',required=True)
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args(); build(a.aegl.resolve(),a.stack.resolve(),a.aegl_tip,a.stack_tip,a.out.resolve())
