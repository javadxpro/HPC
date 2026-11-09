# -*- coding: utf-8 -*-
"""elevated — privileged worker, executed AS ROOT via pkexec
(one polkit prompt per job) or directly when the app is root.

Usage (internal):
    python3 -m hpc_km.elevated <action> <json-args>

Prints one log line per event to stdout; exit 0 on success,
exit 1 with a 'FAILED [stage]: msg' line on failure.
"""
import json
import sys


def _log(msg):
    print(msg, flush=True)


def main():
    if len(sys.argv) != 3:
        print('usage: elevated <action> <json-args>', file=sys.stderr)
        return 2
    action = sys.argv[1]
    args = json.loads(sys.argv[2]) or {}

    from . import flasher
    workdir = args.get('workdir')
    try:
        if action == 'probe':
            print(json.dumps(flasher.probe_root()), flush=True)
        elif action == 'backup':
            path, slot = flasher.backup(_log, workdir)
            print('BACKUP-OK %s %s' % (slot, path), flush=True)
        elif action == 'flash':
            res = flasher.flash(_log, args.get('kernel', '355'),
                                workdir=workdir, progress=None)
            print('FLASH-OK %s %s %s' % (res['slot'], res['other'],
                                         res['backup']), flush=True)
        elif action == 'restore':
            flasher.restore(_log, workdir)
        elif action == 'markok':
            flasher.mark_current_successful(_log)
        elif action == 'reboot':
            flasher.reboot(_log)
            return 0
        else:
            print('FAILED [unknown-action]: ' + action, flush=True)
            return 1
        return 0
    except flasher.FlashError as e:
        print('FAILED [%s]: %s' % (e.stage, e), flush=True)
        return 1
    except Exception as e:
        print('FAILED [error]: %s' % e, flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
