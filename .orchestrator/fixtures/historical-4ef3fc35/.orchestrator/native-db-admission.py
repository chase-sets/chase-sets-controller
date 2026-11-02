#!/usr/bin/python3
"""Finite reconciliation-pg16/v1 namespace lifetime; never a command runner."""

import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import time


HELPER = Path('/opt/chase-sets-native-db/admission.py')
RUNNER = Path('/opt/chase-sets-native-db/reconciliation-pg16.mjs')
ROOT_PARENT = Path('/srv/chase-sets-pg-probe')
INPUT_PARENT = Path('/srv/chase-sets-native-db-input')
PROFILE = 'reconciliation-pg16/v1'
CONTROL_WAIT = 30


def closed(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise ValueError('missing or unknown keys')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate key')
        result[key] = value
    return result


def read_message(stream, maximum):
    raw = stream.readline(maximum + 1)
    if not raw or len(raw) > maximum or not raw.endswith(b'\n'):
        raise ValueError('missing, partial or oversized message')
    return json.loads(raw, object_pairs_hook=unique_object)


def emit(value):
    raw = json.dumps(value, separators=(',', ':'))
    if len(raw.encode()) > 8192:
        raise ValueError('oversized reply')
    print(raw, flush=True)


def safe_path(path, *, directory=False):
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError('noncanonical path')
    for parent in [*reversed(path.parents), path]:
        info = parent.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('path is not private root-owned input')
    info = path.stat()
    if directory and not stat.S_ISDIR(info.st_mode):
        raise ValueError('directory required')
    if not directory and not stat.S_ISREG(info.st_mode):
        raise ValueError('regular file required')
    return path


def execution_root(value):
    root = Path(value)
    if root.parent != ROOT_PARENT or not re.fullmatch(r'native-db-[a-f0-9]{32}', root.name):
        raise ValueError('execution root outside fixed parent')
    safe_path(ROOT_PARENT, directory=True)
    return root


def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def identity(pid):
    process = Path('/proc') / str(pid)
    data = (process / 'stat').read_text()
    ticks = data[data.rindex(')') + 2:].split()[19]
    status = (process / 'status').read_text().splitlines()
    nspid = [int(x) for x in next(x for x in status if x.startswith('NSpid:')).split()[1:]]
    return {'bootId': boot_id(), 'outerPid': pid, 'startTicks': ticks,
            'nspid': nspid, 'inode': str((process / 'ns/pid').stat().st_ino)}


def validate_tuple(value):
    closed(value, ('bootId', 'outerPid', 'startTicks', 'nspid', 'inode'))
    if type(value['bootId']) is not str or not re.fullmatch(
            r'[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}', value['bootId']):
        raise ValueError('invalid boot identity')
    if type(value['outerPid']) is not int or not 1 <= value['outerPid'] <= 2147483647:
        raise ValueError('invalid PID')
    if type(value['nspid']) is not list or any(type(x) is not int for x in value['nspid']) or value['nspid'] != [value['outerPid'], 1]:
        raise ValueError('invalid namespace PID vector')
    for key in ('startTicks', 'inode'):
        if type(value[key]) is not str or not re.fullmatch(r'[0-9]{1,20}', value[key]) or not 1 <= int(value[key]) <= 18446744073709551615:
            raise ValueError('invalid uint64 identity')


def minimal_environment(root):
    return {'PATH': '/usr/bin:/bin', 'HOME': str(root), 'LANG': 'C'}


def fixed_python(mode, root):
    return ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin', f'HOME={root}', 'LANG=C',
            '/usr/bin/python3', str(HELPER), mode, str(root)]


def wait_input(stream):
    if not select.select([stream], [], [], CONTROL_WAIT)[0]:
        raise ValueError('control channel expired')


def write_root_json(path, value):
    with path.open('x') as target:
        json.dump(value, target, separators=(',', ':'))
        target.flush()
        os.fsync(target.fileno())


def launch(root):
    wait_input(sys.stdin.buffer)
    # Framing escapes the original JSON string at most twice; the request
    # itself still has the public 65536-byte bound, including its whitespace.
    envelope = read_message(sys.stdin.buffer, 131200)
    closed(envelope, ('request', 'digest'))
    if type(envelope['request']) is not str or len(envelope['request'].encode()) > 65536:
        raise ValueError('invalid request bytes')
    if hashlib.sha256(envelope['request'].encode()).hexdigest() != envelope['digest']:
        raise ValueError('request digest mismatch')
    request = json.loads(envelope['request'], object_pairs_hook=unique_object)
    if request.get('profile') != PROFILE:
        raise ValueError('unsupported profile')
    root.mkdir(mode=0o755)
    safe_path(root, directory=True)
    write_root_json(root / 'request.json', request)
    child = subprocess.Popen(
        ['/usr/bin/unshare', '--mount', '--pid', '--fork', '--kill-child=SIGKILL',
         '--mount-proc', '--propagation', 'private', '--', *fixed_python('init', root)],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        env=minimal_environment(root))
    # Only this unshare's direct child can be the namespace init. No /proc census.
    deadline = time.monotonic() + CONTROL_WAIT
    captured = None
    while time.monotonic() < deadline and child.poll() is None:
        children = Path(f'/proc/{child.pid}/task/{child.pid}/children').read_text().split()
        if len(children) > 1:
            raise ValueError('ambiguous unshare child')
        if children:
            candidate = identity(int(children[0]))
            validate_tuple(candidate)
            captured = candidate
            break
        time.sleep(0.02)
    if captured is None:
        raise ValueError('namespace tuple unavailable; retain owner')
    write_root_json(root / 'linux.json', captured)
    emit({'linux': captured})
    wait_input(sys.stdin.buffer)
    acknowledgement = read_message(sys.stdin.buffer, 8192)
    closed(acknowledgement, ('linux',))
    validate_tuple(acknowledgement['linux'])
    if acknowledgement['linux'] != captured or identity(captured['outerPid']) != captured:
        raise ValueError('tuple acknowledgement mismatch')
    child.stdin.write(b'{"published":true}\n')
    child.stdin.flush()
    child.stdin.close()
    # Init writes bounded lifecycle data into root-owned storage, not stdout.
    child.wait()
    result_path = safe_path(root / 'result.json')
    result = json.loads(result_path.read_text(), object_pairs_hook=unique_object)
    closed(result, ('status', 'exit', 'diagnostic'))
    emit(result)


def init(root):
    if os.getpid() != 1 or os.getuid() != 0:
        raise ValueError('init requires root PID 1')
    safe_path(root, directory=True)
    wait_input(sys.stdin.buffer)
    acknowledgement = read_message(sys.stdin.buffer, 8192)
    closed(acknowledgement, ('published',))
    if acknowledgement['published'] is not True:
        raise ValueError('tuple not published')
    try:
        # ISS-170 installs this separate runner and its exact reviewed digest.
        # A component release never substitutes an ordinary native DB runner.
        safe_path(RUNNER)
        pin = safe_path(Path(str(RUNNER) + '.sha256')).read_text().strip()
        if not re.fullmatch(r'[a-f0-9]{64}', pin) or hashlib.sha256(RUNNER.read_bytes()).hexdigest() != pin:
            raise ValueError('reviewed runner unavailable or drifted')
        request = json.loads((root / 'request.json').read_text())
        staged = Path(request['stagedInputDirectory'])
        if staged.parent != INPUT_PARENT:
            raise ValueError('staged input outside fixed parent')
        safe_path(staged, directory=True)
        # Preserve only root-staged regular inputs; never dereference links.
        for current, directories, files in os.walk(staged, followlinks=False):
            safe_path(Path(current), directory=True)
            for name in directories:
                safe_path(Path(current) / name, directory=True)
            for name in files:
                safe_path(Path(current) / name)
        shutil.copytree(staged, root / 'input', symlinks=False)
        (root / 'tools').mkdir(mode=0o755)
        shutil.copy2(safe_path(staged / 'tools/node'), root / 'tools/node')
        scratch = root / 'scratch'
        scratch.mkdir(mode=0o700)
        os.chown(scratch, 65534, 65534)
        payload = subprocess.Popen([
            '/usr/bin/setpriv', '--reuid=65534', '--regid=65534', '--clear-groups', '--no-new-privs',
            '/usr/bin/env', '-i', 'PATH=/usr/bin:/bin', f'HOME={scratch}', f'TMPDIR={scratch}',
            'LANG=C', str(root / 'tools/node'), str(RUNNER), str(root / 'request.json')],
            cwd=scratch, env=minimal_environment(scratch),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Reap every adopted child while the fixed payload runs, not only the
        # payload PID. Exiting PID 1 then kills any remaining namespace members.
        while True:
            reaped, status = os.waitpid(-1, 0)
            if reaped == payload.pid:
                result = os.waitstatus_to_exitcode(status)
                payload.returncode = result
                break
        while True:
            try:
                if os.waitpid(-1, os.WNOHANG)[0] == 0:
                    break
            except ChildProcessError:
                break
        write_root_json(root / 'result.json', {'status': 'completed', 'exit': result, 'diagnostic': None})
    except (OSError, ValueError, KeyError) as error:
        write_root_json(root / 'result.json', {'status': 'refused', 'exit': None, 'diagnostic': str(error)[:2048]})


def reconcile(root):
    wait_input(sys.stdin.buffer)
    request = read_message(sys.stdin.buffer, 8192)
    closed(request, ('linux',))
    expected = request['linux']
    validate_tuple(expected)
    if boot_id() != expected['bootId']:
        raise ValueError('boot changed; retain owner')
    pid = expected['outerPid']
    process = Path('/proc') / str(pid)
    if process.exists():
        descriptor = None
        bound = False
        try:
            descriptor = os.pidfd_open(pid)
            if identity(pid) != expected:
                raise ValueError('PID reused or tuple changed; never signal')
            bound = True
            signal.pidfd_send_signal(descriptor, signal.SIGKILL)
            if not select.select([descriptor], [], [], CONTROL_WAIT)[0]:
                raise ValueError('init exit unknown')
        except (ProcessLookupError, FileNotFoundError):
            # A pidfd never renames to another process, so once the exact
            # tuple matched under the open descriptor an ESRCH is that bound
            # init exiting. Before that binding a missing field while /proc
            # still exists carries no identity and remains unknown.
            if not bound and process.exists():
                raise
        finally:
            if descriptor is not None:
                os.close(descriptor)
    deadline = time.monotonic() + CONTROL_WAIT
    while process.exists() and time.monotonic() < deadline:
        try:
            if identity(pid) != expected:
                raise ValueError('PID reuse after signal; retain owner')
        except (ProcessLookupError, FileNotFoundError):
            # SIGKILL can complete between the existence and identity reads,
            # as ENOENT once the entry drops or ESRCH while the task detaches.
            # Only complete /proc absence is death, not a missing tuple field.
            if process.exists():
                raise
            break
        time.sleep(0.02)
    if process.exists() or boot_id() != expected['bootId']:
        raise ValueError('exact init absence unknown')
    if root.exists():
        safe_path(root, directory=True)
        stored = json.loads(safe_path(root / 'linux.json').read_text(), object_pairs_hook=unique_object)
        if stored != expected:
            raise ValueError('root tuple mismatch')
        # No symlink traversal, no parent sweep, and only this exact generated R.
        # rmtree's fd implementation does not follow payload-created links.
        if not shutil.rmtree.avoids_symlink_attacks:
            raise ValueError('safe exact-root removal unavailable')
        if root.parent != ROOT_PARENT or root.resolve() != root:
            raise ValueError('root changed before removal')
        shutil.rmtree(root)
    if root.exists() or root.is_symlink() or process.exists() or boot_id() != expected['bootId']:
        raise ValueError('cleanup absence not established')
    emit({'linux': expected, 'root': str(root), 'initAbsent': True, 'rootAbsent': True})


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('launch', 'init', 'reconcile'):
        raise ValueError('only launch/init/reconcile of one fixed profile are supported')
    if os.geteuid() != 0:
        raise ValueError('namespace helper must be root')
    root = execution_root(sys.argv[2])
    {'launch': launch, 'init': init, 'reconcile': reconcile}[sys.argv[1]](root)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'native-db: {str(error)[:2048]}', file=sys.stderr, flush=True)
        sys.exit(73)
