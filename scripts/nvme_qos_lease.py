#!/usr/bin/env python3
"""Optional bounded NVMe QoS0 lease; restores the exact captured per-device state.

Ported from the measured nvme-qos-trial-v0.1 helper. This portable wrapper
has not independently been exercised on hardware. No boot/module/firmware edits.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
import re
import signal
import socket
import subprocess
import threading
import time

VERSION = 'public-nvme-qos-lease-v0.1'


def utc():
    return datetime.now(timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(ok, reason):
    if not ok:
        raise RuntimeError(reason)


def save(path, data, new=False):
    path = Path(path)
    if new:
        with path.open('x') as f:
            os.chmod(path, 0o600)
            json.dump(data, f, indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
    else:
        temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
        save(temporary, data, new=True)
        os.replace(temporary, path)


class Device:
    def __init__(self, controller):
        require(re.fullmatch(r'nvme[0-9]+', controller), 'Explicit controller name nvmeN required')
        self.controller = controller
        self.sys = Path('/sys/class/nvme') / controller
        self.qos = self.sys / 'power/pm_qos_latency_tolerance_us'
        self.dev = '/dev/' + controller

    def command(self, *args):
        return subprocess.run(['nvme', *args, self.dev], check=True,
            capture_output=True, text=True, timeout=15).stdout.strip()

    def read(self):
        require((self.sys / 'state').read_text().strip() == 'live', 'Controller is not live')
        identify = json.loads(self.command('id-ctrl', '-o', 'json'))
        feature = self.command('get-feature', '-f', '0x0c', '-H')
        require(identify.get('apsta') == 1 and identify.get('sn', '').strip(), 'APST support/serial missing')
        return dict(version=VERSION, hostname=socket.gethostname(),
            boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            controller=self.controller, sysfs_target=str(self.sys.resolve()),
            serial=identify['sn'].strip(), model=identify['mn'].strip(), firmware=identify['fr'].strip(),
            qos=self.qos.read_text().strip(), feature=feature,
            identify=identify, helper_sha256=sha(__file__), utc=utc())

    def write(self, value):
        require(re.fullmatch(r'[0-9]+', value), 'QoS must be an explicit nonnegative integer')
        self.qos.write_text(value + '\n')


def identity_matches(actual, saved):
    keys = ('version', 'hostname', 'boot_id', 'controller', 'sysfs_target',
            'serial', 'model', 'firmware', 'helper_sha256')
    require(all(actual[k] == saved[k] for k in keys), 'Host/boot/controller/serial/source identity changed')


def disable(device, saved):
    before = device.read()
    identity_matches(before, saved)
    require(before['qos'] == saved['qos'] == '100000' and before['feature'] == saved['feature'],
            'Expected original QoS100000 and exact saved APST table')
    require('APSTE): Enabled' in before['feature'], 'Original APST was not enabled')
    device.write('0')
    after = device.read()
    identity_matches(after, saved)
    require(after['qos'] == '0' and 'APSTE): Disabled' in after['feature'],
            'QoS0 did not disable controller APST')
    return after


def restore(device, saved):
    current = device.read()
    identity_matches(current, saved)
    require(current['qos'] in ('0', saved['qos']), 'QoS changed by another actor; refusing to overwrite')
    # Always write the captured value, never a global/module default.
    device.write(saved['qos'])
    after = device.read()
    identity_matches(after, saved)
    require(after['qos'] == saved['qos'] and after['feature'] == saved['feature'],
            'Restoration readback differs from exact original QoS/APST feature')
    return after


def hold(device, saved, snapshot_path, out, seconds, stop):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    record = dict(version=VERSION, status='PREPARING', snapshot_sha256=sha(snapshot_path),
        snapshot=saved, pid=os.getpid(), max_seconds=seconds, started_utc=utc())
    save(out / 'receipt.json', record, new=True)  # Durable recovery state precedes the write.
    mutation_attempted = False
    try:
        # Validate first; restoration is armed before the potentially partial write.
        current = device.read(); identity_matches(current, saved)
        require(current['qos'] == saved['qos'] and current['feature'] == saved['feature'], 'Initial state drift')
        mutation_attempted = True
        record['disabled'] = disable(device, saved)
        record['status'] = 'ACTIVE_QOS0'
        record['active_utc'] = utc()
        save(out / 'receipt.json', record)
        print(json.dumps({'status': record['status'], 'receipt': str(out / 'receipt.json')}), flush=True)
        stop.wait(seconds)
    except BaseException as exc:
        record['trial_error'] = f'{type(exc).__name__}: {exc}'
        raise
    finally:
        if mutation_attempted:
            try:
                record['restored'] = restore(device, saved)
                record['status'] = 'RESTORED_EXACT'
            except BaseException as exc:
                record['status'] = 'RESTORE_FAILED'
                record['restore_error'] = f'{type(exc).__name__}: {exc}'
                raise
            finally:
                record['ended_utc'] = utc()
                save(out / 'receipt.json', record)
        else:
            record['status'] = 'PRECHECK_FAILED'
            record['ended_utc'] = utc()
            save(out / 'receipt.json', record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    snap = sub.add_parser('snapshot')
    snap.add_argument('--controller', required=True); snap.add_argument('--output', type=Path, required=True)
    for name in ('hold', 'restore'):
        p = sub.add_parser(name); p.add_argument('--snapshot', type=Path, required=True)
        p.add_argument('--output', type=Path, required=True); p.add_argument('--execute', action='store_true')
        if name == 'hold': p.add_argument('--seconds', type=int, default=1800)
    a = parser.parse_args()
    require(os.geteuid() == 0, 'Run on the host with root privilege; no password handling')
    if a.action == 'snapshot':
        value = Device(a.controller).read()
        require(value['qos'] == '100000' and 'APSTE): Enabled' in value['feature'], 'Unexpected baseline')
        save(a.output, value, new=True); print(json.dumps({'snapshot': str(a.output), 'sha256': sha(a.output)})); return
    require(a.execute, 'Default-off: --execute required for per-device QoS writes')
    info = a.snapshot.lstat()
    require(a.snapshot.is_file() and not a.snapshot.is_symlink() and info.st_uid == 0
            and info.st_mode & 0o077 == 0, 'Snapshot must be a root-owned regular file with mode0600')
    saved = json.loads(a.snapshot.read_text()); device = Device(saved['controller'])
    if a.action == 'restore':
        require(not a.output.exists(), 'Restoration output must be new')
        value = restore(device, saved)
        save(a.output, dict(version=VERSION, status='RESTORED_EXACT', snapshot=saved,
            snapshot_sha256=sha(a.snapshot), restored=value, ended_utc=utc()), new=True); return
    require(1 <= a.seconds <= 86400, 'Bound trial to1..86400 seconds')
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: stop.set())
    hold(device, saved, a.snapshot, a.output, a.seconds, stop)


if __name__ == '__main__':
    main()
