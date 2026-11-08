# -*- coding: utf-8 -*-
"""VLESS share-link parser/serializer (pure stdlib, fully testable).

Handles the vless:// URI scheme as produced by v2rayNG / v2rayN /
Shadowrocket, including tcp, ws, kcp, grpc, h2, quic, httpupgrade and
hysteria2 transports and none/tls/reality security, plus multi-link
subscription text.

NOTE on core compatibility: the bundled v2fly core (v5.53.0, v5 config
format) supports transports tcp, kcp, ws, h2, ds, quic, grpc, hysteria2.
httpupgrade links are parsed fine but cannot be used with this core
version (the v5-format transport table does not include it) — the engine
rejects them with a clear message.
"""
import base64
import binascii
from urllib.parse import unquote, quote, parse_qs

VALID_TYPES = ('tcp', 'ws', 'kcp', 'grpc', 'h2', 'quic', 'httpupgrade',
               'hysteria2', 'hy2')
VALID_SECURITY = ('none', 'tls', 'reality')
VALID_FP = ('chrome', 'firefox', 'safari', 'ios', 'android', 'edge',
            '360', 'qq', 'random')


class VLinkError(ValueError):
    pass


def _clean_uuid(s):
    """Normalize the user id to canonical dashed UUID when possible;
    otherwise pass through (vless accepts opaque string ids)."""
    import uuid as _uuid
    s = (s or '').strip()
    if not s:
        raise VLinkError('missing uuid')
    try:  # dashed / braced / urn forms
        return str(_uuid.UUID(s))
    except Exception:
        pass
    if len(s) == 32:  # bare hex
        try:
            return str(_uuid.UUID(bytes=binascii.unhexlify(s)))
        except Exception:
            pass
    try:  # base64 (16 bytes, url-safe, padding optional)
        pad = '=' * (-len(s) % 4)
        b = base64.urlsafe_b64decode(s + pad)
        if len(b) == 16:
            return str(_uuid.UUID(bytes=b))
    except Exception:
        pass
    return s


class Profile(object):
    """One VLESS server profile (parsed from a link)."""

    __slots__ = ('name', 'address', 'port', 'uuid', 'flow', 'type',
                 'security', 'sni', 'fp', 'pbk', 'sid', 'spx', 'host',
                 'path', 'service_name', 'allow_insecure', 'encryption',
                 'quic_security', 'key', 'password')

    def __init__(self):
        self.name = ''
        self.address = ''
        self.port = 443
        self.uuid = ''
        self.flow = ''
        self.type = 'tcp'
        self.security = 'none'
        self.sni = ''
        self.fp = ''
        self.pbk = ''
        self.sid = ''
        self.spx = ''
        self.host = ''
        self.path = ''
        self.service_name = ''
        self.allow_insecure = False
        self.encryption = 'none'
        self.quic_security = ''
        self.key = ''
        self.password = ''

    # ------------------------------------------------------------ outbound
    def stream_settings(self):
        """v5-format streamSettings (network + per-transport settings)."""
        ss = {'network': self.type}
        if self.security == 'tls':
            tls = {}
            if self.sni:
                tls['serverName'] = self.sni
            if self.allow_insecure:
                tls['allowInsecure'] = True
            ss['tlsSettings'] = tls
        elif self.security == 'reality':
            r = {}
            if self.sni:
                r['serverName'] = self.sni
            if self.fp:
                r['fingerprint'] = self.fp
            if self.pbk:
                r['publicKey'] = self.pbk
            if self.sid:
                r['shortId'] = self.sid
            if self.spx:
                r['spiderX'] = self.spx
            ss['realitySettings'] = r
        if self.type == 'tcp':
            # http header camouflage is optional; plain tcp is default
            pass
        elif self.type == 'ws':
            ws = {'path': self.path or '/'}
            if self.host:
                ws['headers'] = {'Host': self.host}
            ss['wsSettings'] = ws
        elif self.type == 'grpc':
            ss['grpcSettings'] = {
                'serviceName': self.service_name or self.name or 'grpc'}
        elif self.type == 'h2':
            ss['httpSettings'] = {'path': self.path or '/'}
        elif self.type == 'quic':
            q = {}
            if self.quic_security:
                q['security'] = self.quic_security
            if self.key:
                q['key'] = self.key
            if self.host:
                q['header'] = {'type': 'http',
                               'request': {'headers': {'Host': [self.host]}}}
            ss['quicSettings'] = q
        elif self.type == 'httpupgrade':
            h = {'path': self.path or '/'}
            if self.host:
                h['host'] = self.host
            ss['httpupgradeSettings'] = h
        elif self.type in ('hysteria2', 'hy2'):
            ss['network'] = 'hysteria2'
            h = {}
            if self.password:
                h['password'] = self.password
            ss['hysteria2Settings'] = h
        return ss

    def outbound(self):
        user = {'id': self.uuid, 'encryption': self.encryption or 'none'}
        if self.flow:
            user['flow'] = self.flow
        return {
            'protocol': 'vless',
            'settings': {'vnext': [{
                'address': self.address,
                'port': int(self.port),
                'users': [user],
            }]},
            'streamSettings': self.stream_settings(),
            'tag': 'proxy',
        }

    def summary(self):
        return 'vless://%s:%d (%s/%s)' % (
            self.address, self.port,
            'hysteria2' if self.type in ('hysteria2', 'hy2') else self.type,
            self.security)

    def to_dict(self):
        return {k: getattr(self, k) for k in self.__slots__}

    @classmethod
    def from_dict(cls, d):
        p = cls()
        for k in cls.__slots__:
            if k in d:
                setattr(p, k, d[k])
        return p


# ------------------------------------------------------------------- parse

def parse_link(link):
    """Parse a vless:// link into a Profile."""
    link = (link or '').strip()
    if not link.lower().startswith('vless://'):
        raise VLinkError('not a vless:// link')
    body = link[len('vless://'):]
    # split fragment (name)
    name = ''
    if '#' in body:
        body, frag = body.split('#', 1)
        # fragments may use form-encoding: '+' also means space
        name = unquote(frag).replace('+', ' ')
    # split query
    query = ''
    if '?' in body:
        body, query = body.split('?', 1)
    # split user@host
    if '@' not in body:
        raise VLinkError('missing uuid@host part')
    user, hostport = body.rsplit('@', 1)
    uuid = _clean_uuid(user)
    # host:port (IPv6 in brackets)
    if hostport.startswith('['):
        i = hostport.find(']')
        if i < 0:
            raise VLinkError('bad ipv6 host')
        address = hostport[1:i]
        rest = hostport[i + 1:]
        port = 443
        if rest.startswith(':'):
            port = int(rest[1:])
    else:
        if ':' in hostport:
            address, p = hostport.rsplit(':', 1)
            port = int(p)
        else:
            address, port = hostport, 443
    q = {}
    for k, v in parse_qs(query, keep_blank_values=True).items():
        q[k] = v[0] if v else ''
    p = Profile()
    p.name = name or ('%s:%d' % (address, port))
    p.address = address
    p.port = port
    p.uuid = uuid
    p.flow = q.get('flow', '')
    p.type = q.get('type', 'tcp').lower()
    if p.type == 'hy2':
        p.type = 'hysteria2'
    if p.type not in VALID_TYPES:
        raise VLinkError('unknown transport: ' + p.type)
    p.security = q.get('security', 'none').lower()
    if p.security not in VALID_SECURITY:
        raise VLinkError('unknown security: ' + p.security)
    p.sni = q.get('sni', '') or q.get('peer', '')
    p.fp = q.get('fp', '').lower()
    if p.fp and p.fp not in VALID_FP:
        p.fp = 'chrome'
    p.pbk = q.get('pbk', '')
    p.sid = q.get('sid', '')
    p.spx = q.get('spx', '')
    p.host = q.get('host', '')
    p.path = q.get('path', '')
    p.service_name = q.get('serviceName', '')
    p.allow_insecure = q.get('allowInsecure', '').lower() in (
        '1', 'true', 'yes')
    p.encryption = q.get('encryption', 'none') or 'none'
    p.quic_security = q.get('quicSecurity', '') or q.get('headerType', '')
    p.key = q.get('key', '')
    p.password = q.get('password', '')
    # common v2rayNG defaults
    if p.security in ('tls', 'reality') and not p.sni:
        p.sni = p.address
    if p.type in ('ws', 'h2') and not p.path:
        p.path = '/'
    if p.type == 'quic' and not p.quic_security:
        p.quic_security = 'none'
    return p


def parse_subscription(text):
    """Parse subscription text (one or more vless:// links, any lines)."""
    out = []
    for line in (text or '').splitlines():
        line = line.strip()
        if not line or not line.lower().startswith('vless://'):
            continue
        try:
            out.append(parse_link(line))
        except VLinkError:
            continue
    return out


# ------------------------------------------------------------------- emit

def to_link(p):
    """Serialize a Profile back to a vless:// link (for sharing)."""
    q = [('type', 'hysteria2' if p.type in ('hysteria2', 'hy2') else p.type)]
    q.append(('security', p.security))
    if p.sni:
        q.append(('sni', p.sni))
    if p.security == 'reality':
        for k, v in (('pbk', p.pbk), ('sid', p.sid), ('spx', p.spx),
                     ('fp', p.fp)):
            if v:
                q.append((k, v))
    if p.type == 'ws' or p.type == 'h2':
        if p.path:
            q.append(('path', p.path))
        if p.host:
            q.append(('host', p.host))
    elif p.type == 'grpc':
        q.append(('serviceName', p.service_name))
    elif p.type == 'httpupgrade':
        if p.path:
            q.append(('path', p.path))
        if p.host:
            q.append(('host', p.host))
    elif p.type == 'quic':
        if p.quic_security:
            q.append(('quicSecurity', p.quic_security))
        if p.key:
            q.append(('key', p.key))
    elif p.type in ('hysteria2', 'hy2'):
        if p.password:
            q.append(('password', p.password))
    if p.flow:
        q.append(('flow', p.flow))
    if p.allow_insecure:
        q.append(('allowInsecure', '1'))
    host = ('[' + p.address + ']') if ':' in p.address else p.address
    qs = '&'.join('%s=%s' % (k, quote(v, safe='')) for k, v in q)
    frag = quote(p.name, safe='') if p.name else ''
    return 'vless://%s@%s:%d?%s%s' % (
        p.uuid, host, p.port, qs, ('#' + frag) if frag else '')


if __name__ == '__main__':
    import sys
    import json
    for ln in sys.argv[1:]:
        try:
            pr = parse_link(ln)
            print(json.dumps(pr.to_dict(), ensure_ascii=False, indent=1))
        except VLinkError as e:
            print('ERROR:', e)
