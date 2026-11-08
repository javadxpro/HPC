# -*- coding: utf-8 -*-
"""V2Ray engine management: binary discovery, config generation,
process lifecycle, TUN (system-wide) kernel setup. No GUI imports —
testable headless.

Config format notes (v2fly core v5.53.0, verified against source
v5.53.0 tag):
  * root = v5 (legacy) format: log/routing/inbounds/outbounds
  * TUN is a *service*, not an inbound: "services": {"tun": {...}}
  * supported transports in this format: tcp, kcp, ws, h2, ds, quic,
    grpc, hysteria2  (httpupgrade is NOT in the v5 transport table)
"""
import json
import os
import signal
import subprocess
import time
from pathlib import Path

from . import vlink

APP_STATE = 'hpc-v2ray'
DEFAULT_SOCKS_PORT = 10808
DEFAULT_HTTP_PORT = 10809
DEFAULT_TUN_MTU = 1500

# v5-format transports this core build accepts (v4 TransportProtocol)
SUPPORTED_TRANSPORTS = ('tcp', 'kcp', 'ws', 'h2', 'ds', 'quic', 'grpc',
                        'hysteria2')

# TUN device (created by the core itself when running as root)
TUN_IFACE = 'hpcv2ray'
TUN_IP = '10.0.0.2'
TUN_MASK = 24
TUN_GW = '10.0.0.1'


class EngineError(Exception):
    pass


# ------------------------------------------------------------------- state

def state_dir():
    d = Path(os.environ.get('XDG_STATE_HOME',
                            Path.home() / '.local' / 'state')) / APP_STATE
    d.mkdir(parents=True, exist_ok=True)
    return d


def load_json(name, default):
    try:
        with open(state_dir() / name, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return default


def save_json(name, data):
    try:
        with open(state_dir() / name, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
        return True
    except Exception:
        return False


class ProfileStore(object):
    """profiles.json: list of vlink.Profile dicts + active index."""

    def __init__(self):
        self.data = load_json('profiles.json', {'profiles': [], 'active': 0})
        if 'profiles' not in self.data:
            self.data = {'profiles': [], 'active': 0}

    def profiles(self):
        return [vlink.Profile.from_dict(d) for d in self.data['profiles']]

    def active(self):
        ps = self.profiles()
        i = self.data.get('active', 0)
        if 0 <= i < len(ps):
            return ps[i]
        return None

    def add(self, profile):
        # replace an existing one with same uuid+address+port+type
        for i, d in enumerate(self.data['profiles']):
            if (d.get('uuid') == profile.uuid and
                    d.get('address') == profile.address and
                    d.get('port') == profile.port and
                    d.get('type') == profile.type):
                self.data['profiles'][i] = profile.to_dict()
                self.data['active'] = i
                self.save()
                return i
        self.data['profiles'].append(profile.to_dict())
        self.data['active'] = len(self.data['profiles']) - 1
        self.save()
        return len(self.data['profiles']) - 1

    def remove(self, idx):
        if 0 <= idx < len(self.data['profiles']):
            self.data['profiles'].pop(idx)
            if self.data['active'] >= len(self.data['profiles']):
                self.data['active'] = max(0, len(self.data['profiles']) - 1)
            self.save()

    def set_active(self, idx):
        self.data['active'] = idx
        self.save()

    def save(self):
        save_json('profiles.json', self.data)


# ------------------------------------------------------------------ binary

def find_binary():
    """Locate the v2ray binary: env > bundled > system."""
    env = os.environ.get('HPC_V2RAY_BIN')
    if env and os.path.isfile(env):
        return env
    here = Path(__file__).resolve().parent
    candidates = [
        here / 'v2ray',                       # next to the package (dev)
        here / 'v2ray.bin',
        Path('/usr/lib/hpc-v2ray/v2ray'),     # .deb location
        Path('/usr/local/bin/v2ray'),
        Path('/usr/bin/v2ray'),
        Path.home() / '.local' / 'bin' / 'v2ray',
    ]
    import shutil
    for c in candidates:
        if c.is_file():
            return str(c)
    found = shutil.which('v2ray')
    return found


def binary_dir(v2ray):
    return str(Path(v2ray).resolve().parent)


def geo_available(v2ray):
    d = binary_dir(v2ray)
    return (Path(d, 'geoip.dat').is_file() and
            Path(d, 'geosite.dat').is_file())


def version(v2ray):
    try:
        r = subprocess.run([v2ray, 'version'], capture_output=True,
                           text=True, timeout=10)
        for line in r.stdout.splitlines():
            if line.startswith('V2Ray'):
                return line
        return r.stdout.strip().splitlines()[0] if r.stdout.strip() else ''
    except Exception:
        return ''


# ------------------------------------------------------------------ config

def _ip_cidr(addr):
    if ':' in addr:
        return addr + '/128'
    return addr + '/32'


def gen_config(profile, mode='socks', socks_port=DEFAULT_SOCKS_PORT,
               http_port=DEFAULT_HTTP_PORT, tun_mtu=DEFAULT_TUN_MTU,
               bypass_ir=True):
    """Build a full v5-format client config for the given profile.

    mode: 'socks' (local SOCKS5+HTTP inbounds) or
          'tun'   (adds the gvisor TUN *service* for system-wide routing;
                   requires root to run).
    """
    if profile.type not in SUPPORTED_TRANSPORTS:
        raise EngineError(
            'transport "%s" is not supported by core v5.53.0 (v5 format). '
            'Supported: %s' % (profile.type, ', '.join(SUPPORTED_TRANSPORTS)))
    d = state_dir()
    cfg = {
        'log': {
            'loglevel': 'warning',
            'access': str(d / 'access.log'),
            'error': str(d / 'error.log'),
        },
        'inbounds': [
            {
                'listen': '127.0.0.1',
                'port': int(socks_port),
                'protocol': 'socks',
                'settings': {'udp': True, 'auth': 'noauth'},
                'tag': 'socks',
            },
            {
                'listen': '127.0.0.1',
                'port': int(http_port),
                'protocol': 'http',
                'tag': 'http',
            },
        ],
        'outbounds': [
            profile.outbound(),               # proxy = default outbound
            {'protocol': 'freedom', 'tag': 'direct'},
            {'protocol': 'blackhole', 'tag': 'block'},
        ],
        'routing': {
            'domainStrategy': 'AsIs',
            'rules': [
                {'type': 'field', 'ip': ['geoip:private'],
                 'outboundTag': 'direct'},
            ],
        },
    }
    if mode == 'tun':
        # TUN is a service in v2fly v5 (gvisor stack), NOT an inbound.
        cfg['services'] = {
            'tun': {
                'name': TUN_IFACE,
                'ips': [{'ip_addr': '%s/%d' % (TUN_IP, TUN_MASK)}],
                'routes': [{'ip_addr': '0.0.0.0/0'},
                           {'ip_addr': '::/0'}],
                'mtu': int(tun_mtu),
                'enablePromiscuousMode': True,
                'enableSpoofing': True,
                'sniffingSettings': {
                    'enabled': True,
                    'destinationOverride': ['http', 'tls'],
                },
            }
        }
        # never loop the proxy server through the TUN
        cfg['routing']['rules'].append(
            {'type': 'field', 'ip': [_ip_cidr(profile.address)],
             'outboundTag': 'direct'})
    if bypass_ir:
        cfg['routing']['rules'].append(
            {'type': 'field', 'domain': ['geosite:category-ir'],
             'outboundTag': 'direct'})
    return cfg


def write_config(cfg, path):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=1)
    return path


def validate_config(v2ray, cfg_path):
    """Run `v2ray test -c`. Returns (ok, stderr)."""
    try:
        r = subprocess.run([v2ray, 'test', '-c', cfg_path],
                           capture_output=True, text=True, timeout=30)
        return r.returncode == 0, (r.stderr or r.stdout)[-500:]
    except Exception as e:
        return False, str(e)


# ----------------------------------------------------------------- TUN/ip

def _run_ip(args, check=False):
    try:
        r = subprocess.run(['ip'] + args, capture_output=True, text=True,
                           timeout=10)
        return r.returncode == 0, (r.stderr or '').strip()
    except Exception as e:
        return False, str(e)


def tun_cleanup_stale():
    _run_ip(['link', 'del', TUN_IFACE])  # ignore errors


def tun_capture_default():
    """Return the current default route line (to restore on stop)."""
    try:
        r = subprocess.run(['ip', 'route', 'show', 'default'],
                           capture_output=True, text=True, timeout=10)
        line = r.stdout.strip().splitlines()
        return line[0] if line else ''
    except Exception:
        return ''


def tun_wait_iface(timeout=10.0):
    """Wait until the core created the TUN interface."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.isdir('/sys/class/net/' + TUN_IFACE):
            return True
        time.sleep(0.2)
    return False


def tun_configure(mtu=DEFAULT_TUN_MTU):
    """Kernel-side setup for the TUN interface (must be root)."""
    tun_cleanup_stale()
    ok, _ = _run_ip(['link', 'set', 'dev', TUN_IFACE, 'up'])
    if not tun_wait_iface():
        return False, 'TUN interface %s did not appear (core not root?)' \
                     % TUN_IFACE
    ok, err = _run_ip(['addr', 'replace',
                       '%s/%d' % (TUN_IP, TUN_MASK), 'dev', TUN_IFACE])
    if not ok:
        return False, 'ip addr: ' + err
    ok, err = _run_ip(['link', 'set', 'dev', TUN_IFACE, 'up'])
    if not ok:
        return False, 'ip link up: ' + err
    ok, err = _run_ip(['route', 'replace', 'default', 'via', TUN_GW,
                       'dev', TUN_IFACE])
    if not ok:
        return False, 'ip route: ' + err
    return True, 'TUN %s up: %s/%d, default via %s' % (
        TUN_IFACE, TUN_IP, TUN_MASK, TUN_GW)


def tun_teardown(prev_default=''):
    ok, _ = _run_ip(['route', 'del', 'default', 'via', TUN_GW,
                     'dev', TUN_IFACE])
    _run_ip(['link', 'set', 'dev', TUN_IFACE, 'down'])
    _run_ip(['link', 'del', TUN_IFACE])
    if prev_default:
        args = prev_default.split()
        if args and args[0] == 'default':
            _run_ip(['route'] + args)
    return True, ''


# ----------------------------------------------------------------- process

PID_FILE = 'v2ray.pid'


def write_pid(pid):
    save_json(PID_FILE, {'pid': pid})


def read_pid():
    d = load_json(PID_FILE, {})
    return d.get('pid')


def is_running(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except Exception:
        return False


def current_status():
    """Return dict: running, pid, started, profile, mode, uptime."""
    pid = read_pid()
    st = load_json('run.json', {})
    out = {'running': is_running(pid), 'pid': pid if is_running(pid) else None,
           'started': st.get('started', 0),
           'profile': st.get('profile', ''),
           'mode': st.get('mode', 'socks')}
    out['uptime'] = (int(time.time() - st.get('started', time.time()))
                     if out['running'] else 0)
    return out


def start(profile, mode='socks', socks_port=DEFAULT_SOCKS_PORT,
          http_port=DEFAULT_HTTP_PORT, tun_mtu=DEFAULT_TUN_MTU,
          bypass_ir=True, v2ray=None):
    """Validate + launch v2ray. Returns (ok, message)."""
    v2ray = v2ray or find_binary()
    if not v2ray:
        return False, 'v2ray binary not found (install or set HPC_V2RAY_BIN)'
    try:
        cfg = gen_config(profile, mode=mode, socks_port=socks_port,
                         http_port=http_port, tun_mtu=tun_mtu,
                         bypass_ir=bypass_ir)
    except EngineError as e:
        return False, str(e)
    pid = read_pid()
    if is_running(pid):
        return False, 'already running (pid %d)' % pid
    d = state_dir()
    cfg_path = str(d / 'client.json')
    write_config(cfg, cfg_path)
    ok, err = validate_config(v2ray, cfg_path)
    if not ok:
        return False, 'config invalid: ' + err
    if mode == 'tun':
        if os.geteuid() != 0:
            return False, 'TUN mode requires root (the core must open ' \
                          '/dev/net/tun). Re-run as root or use Local mode.'
        tun_cleanup_stale()
    prev_default = tun_capture_default() if mode == 'tun' else ''
    logf = open(str(state_dir() / 'v2ray.out'), 'ab')
    try:
        proc = subprocess.Popen(
            [v2ray, 'run', '-c', cfg_path],
            stdout=logf, stderr=logf,
            cwd=str(state_dir()),
            start_new_session=True,
        )
    except Exception as e:
        return False, 'launch failed: ' + str(e)
    write_pid(proc.pid)
    save_json('run.json', {'pid': proc.pid, 'started': int(time.time()),
                           'profile': profile.name, 'mode': mode,
                           'socks': int(socks_port),
                           'http': int(http_port),
                           'tun_prev_default': prev_default})
    time.sleep(1.0)
    if not is_running(proc.pid):
        tail = _tail_out(400)
        if mode == 'tun':
            tun_teardown(prev_default)
        return False, 'engine exited: ' + tail[-300:]
    if mode == 'tun':
        ok, msg = tun_configure(mtu=tun_mtu)
        if not ok:
            stop()
            return False, msg
        return True, 'started (pid %d) — ' % proc.pid + msg
    return True, 'started (pid %d)' % proc.pid


def _tail_out(n=400):
    try:
        with open(str(state_dir() / 'v2ray.out'), 'rb') as f:
            return f.read()[-n:].decode('utf-8', 'replace')
    except Exception:
        return ''


def stop(v2ray=None):
    st = load_json('run.json', {})
    pid = read_pid()
    was_tun = st.get('mode') == 'tun'
    prev_default = st.get('tun_prev_default', '')
    if not is_running(pid):
        save_json(PID_FILE, {})
        if was_tun:
            tun_teardown(prev_default)
        return True, 'not running'
    try:
        os.kill(pid, signal.SIGTERM)
        for _ in range(20):
            if not is_running(pid):
                break
            time.sleep(0.25)
        if is_running(pid):
            os.kill(pid, signal.SIGKILL)
        save_json(PID_FILE, {})
        save_json('run.json', {})
        if was_tun:
            tun_teardown(prev_default)
        return True, 'stopped (pid %d)' % pid
    except Exception as e:
        return False, str(e)
