# Hamedis Performance Core — v1.12.1 release notes

**versionCode 11201** · hotfix — cosmetic

The Action button's log used to show two lines like:

```
./action.sh: line 45: can't open /proc/6944/cmdline: no such file
```

That was `web_kill_cmdline` (which stops any previous WebUI server before
starting a new one) reading the `/proc/PID/cmdline` of a process that had
already exited between the directory scan and the read. dash applies
redirects left-to-right, so the input-redirect error leaked past the
`2>/dev/null`. Fixed by ordering the redirections (`2>/dev/null` first).

No functional change. Action-button log is now clean.
