# Customcode status page (fork-only)

The right-hand project-status inspector renders whatever a repository's
`customcode.py` prints. This doc pins down the stdout contract and the remote
(SSH) serve-mode bridge. Everything here is fork-only; upstream files
(`SSHCommand.swift`, `ShellClient+SSH.swift`, `docs/remote-ssh-setup.md`) are
reused read-only and stay untouched.

## The stdout contract

Supacode runs `uv run --script customcode.py` (cwd = worktree root) roughly
every 30s while the panel is open, plus on selection changes, commits, and
manual refresh. Two modes, decided by the first stdout line
(`CustomCodeContent.parse`):

- **Snapshot (v0)**: print a complete, self-contained HTML document and exit
  0. Re-rendered in place on every tick.
- **Serve (v1)**: print exactly one line
  `supacode-serve: http://127.0.0.1:<port>/` (loopback http only; later lines
  reserved) and exit fast, leaving a detached server the *script* owns —
  spawning, health-checking, VERSION-gated restarts, idle shutdown. The
  webview reloads only when the URL changes, a load failed, or the user hits
  refresh — never on a same-URL tick, so in-page state survives.

## Remote worktrees: the SSH local-forward bridge

A remote worktree's announced URL is loopback *on the SSH host*, so
`RemoteServeForwarder` bridges it here instead of erroring out:

```
remote render tick (~30s)                    RemoteServeForwarder (actor)
uv run customcode.py  ──sentinel──►  .url(http://127.0.0.1:REMOTE)
        │                                     │ ensure forward, rewrite
        ▼                                     ▼
CustomCodeSSH master (~/.ssh/customcode-%C)   .url(http://127.0.0.1:LOCAL)
  ssh -O forward -L 127.0.0.1:LOCAL:127.0.0.1:REMOTE dest        │
                                                                 ▼
                                              WKWebView loads local URL
```

- **Panel-owned master.** All panel SSH traffic (presence probe, the 30s
  render handshake, `-O forward` / `-O cancel`) rides a dedicated multiplexed
  master at `ControlPath=~/.ssh/customcode-%C` with `ControlPersist=1h`
  (`CustomCodeSSH`). Upstream's `supacode-%C` master is never touched, so the
  fork's upstream-merge surface stays confined to the CustomCode feature.
  Cost: one extra SSH connection per host with its own auth when cold.
- **Re-ensured every tick.** `localURL` reuses a mapping whose local port
  still accepts connections (zero ssh on the hot path), repairs a dead
  forward on the *same* port (master died, e.g. the Mac slept past
  ControlPersist — same URL, so in-page state survives; the reducer's
  `serveLoadFailed` retry forces the reload), and rekeys to a *fresh* port
  when the remote URL changed (server respawn), which changes the local URL
  and correctly triggers a reload. `-L 0:` dynamic allocation is never
  reported for local forwards, so `LoopbackPort.allocate` picks the port.
- **Self-healing, not connection-holding.** There is no long-lived ssh
  process to babysit: the forward registers on the master and the master's
  ControlPersist owns its lifetime. Contrast with the abandoned long-lived
  `ssh -R` push channel noted in `docs/remote-ssh-setup.md` (the OSC
  presence section) — that design died precisely because a held-open
  channel is ControlMaster-fragile. Failures here surface as the existing
  "page server not responding — retrying…" overlay and recover within a
  tick.
- **No app-quit teardown (v1).** Mappings are in-memory; leaked forwards are
  loopback listeners that die with the master's persist window at the latest.
