import Foundation
import SupacodeSettingsShared

private nonisolated let forwarderLogger = SupaLogger("RemoteServeForwarder")

/// Bridges a remote worktree's serve-mode loopback URL to this Mac: the
/// announced `http://127.0.0.1:<port>/` lives on the SSH host, so the panel
/// registers an `ssh -O forward -L` local forward on the panel's own
/// multiplexed master (`CustomCodeSSH`) and hands the webview a rewritten
/// `http://127.0.0.1:<localPort>` URL instead.
///
/// One instance is captured by `CustomCodeClient.liveValue`; mappings are
/// in-memory only. Forwards are re-ensured on every ~30s render tick, so a
/// dead master self-heals within a tick; leaked forwards die with the
/// master's ControlPersist at the latest (no app-quit teardown in v1).
///
/// Concurrency: renders are `cancelInFlight` for the single selected
/// worktree, so same-worktree reentrancy does not occur; distinct worktrees
/// hit distinct dictionary keys.
actor RemoteServeForwarder {
  private struct Mapping {
    let host: RemoteHost
    let remoteURL: URL
    let localPort: Int
  }

  private struct TimeoutError: LocalizedError {
    var errorDescription: String? { "ssh did not finish within 10 seconds" }
  }

  private let runSSH: @Sendable ([String]) async throws -> Void
  private let allocatePort: @Sendable () throws -> Int
  private let canConnect: @Sendable (Int) -> Bool
  private var mappings: [WorktreeID: Mapping] = [:]

  init(
    runSSH: @escaping @Sendable ([String]) async throws -> Void = RemoteServeForwarder.liveRunSSH,
    allocatePort: @escaping @Sendable () throws -> Int = LoopbackPort.allocate,
    canConnect: @escaping @Sendable (Int) -> Bool = LoopbackPort.canConnect(port:)
  ) {
    self.runSSH = runSSH
    self.allocatePort = allocatePort
    self.canConnect = canConnect
  }

  /// Returns a locally reachable rewrite of `remoteURL`, ensuring an SSH
  /// local forward backs it. Four outcomes:
  ///
  /// 1. **Reuse** — the worktree's mapping matches and its local port still
  ///    accepts connections: return the same URL, zero ssh (per-tick path).
  /// 2. **Repair** — mapping matches but the listener is gone (master died,
  ///    e.g. the Mac slept past ControlPersist): re-forward on the *same*
  ///    local port so the URL — and the page's in-page state — survive.
  /// 3. **Rekey** — the remote URL changed (server respawned after idle exit
  ///    or a VERSION bump): cancel the old forward best-effort and allocate a
  ///    *new* local port. Pinning the old port would keep the URL identical,
  ///    and stale page JS would keep talking to the new server undetected;
  ///    locally a respawn changes the URL and reloads, so remote mirrors that.
  /// 4. **Fresh** — no mapping: allocate, forward, remember.
  func localURL(worktreeID: WorktreeID, host: RemoteHost, remoteURL: URL) async throws -> URL {
    let targetHost = remoteURL.host() ?? "127.0.0.1"
    let targetPort = remoteURL.port ?? 80
    if let mapping = mappings[worktreeID] {
      if mapping.host == host, mapping.remoteURL == remoteURL {
        if canConnect(mapping.localPort) {
          return Self.rewritten(remoteURL: remoteURL, localPort: mapping.localPort)
        }
        do {
          forwarderLogger.debug("repairing forward :\(mapping.localPort) for \(host.sshDestination)")
          try await establishForward(
            host: host, localPort: mapping.localPort, targetHost: targetHost, targetPort: targetPort
          )
          return Self.rewritten(remoteURL: remoteURL, localPort: mapping.localPort)
        } catch {
          // Port stolen or host unreachable: fall through to a fresh mapping
          // — the URL change then correctly triggers a webview reload.
          mappings[worktreeID] = nil
        }
      } else {
        forwarderLogger.debug("rekeying forward :\(mapping.localPort) for \(host.sshDestination)")
        try? await runSSH(
          CustomCodeSSH.muxCancelForwardInvocation(
            host: mapping.host,
            localPort: mapping.localPort,
            targetHost: mapping.remoteURL.host() ?? "127.0.0.1",
            targetPort: mapping.remoteURL.port ?? 80
          )
        )
        mappings[worktreeID] = nil
      }
    }
    let localPort = try allocatePort()
    try await establishForward(host: host, localPort: localPort, targetHost: targetHost, targetPort: targetPort)
    mappings[worktreeID] = Mapping(host: host, remoteURL: remoteURL, localPort: localPort)
    forwarderLogger.debug("forwarded :\(localPort) → \(host.sshDestination):\(targetPort)")
    return Self.rewritten(remoteURL: remoteURL, localPort: localPort)
  }

  /// Registers the forward on the panel master. The first attempt fails when
  /// the master is cold (exit 255, "Control socket … No such file"); then a
  /// probe (re)establishes the master and the forward is retried once.
  private func establishForward(
    host: RemoteHost,
    localPort: Int,
    targetHost: String,
    targetPort: Int
  ) async throws {
    let forward = CustomCodeSSH.muxForwardInvocation(
      host: host, localPort: localPort, targetHost: targetHost, targetPort: targetPort
    )
    do {
      try await runSSH(forward)
    } catch {
      do {
        try await runSSH(CustomCodeSSH.muxProbeInvocation(host: host))
        try await runSSH(forward)
      } catch {
        throw Self.forwardFailure(host: host, error: error)
      }
    }
  }

  private static func forwardFailure(host: RemoteHost, error: any Error) -> CustomCodeError {
    let detail: String
    if let error = error as? ShellClientError {
      let stderr = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      detail = stderr.isEmpty ? "ssh exited with code \(error.exitCode)" : stderr
    } else {
      detail = error.localizedDescription
    }
    return .serveForwardFailed(destination: host.sshDestination, detail: detail)
  }

  /// The URL the webview loads: host pinned to `127.0.0.1` (the script may
  /// announce `localhost` / `::1`, but our `-L` listener is IPv4 loopback),
  /// port swapped to the forward's local end, path/query/fragment preserved.
  private static func rewritten(remoteURL: URL, localPort: Int) -> URL {
    var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = localPort
    return components.url ?? remoteURL
  }

  /// Live transport: one ssh child per call, raced against a 10s timeout.
  /// Cancellation tears the child down via ShellClient's termination path,
  /// so a stalled control socket can't wedge the render effect.
  private static let liveRunSSH: @Sendable ([String]) async throws -> Void = { arguments in
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = try await ShellClient.live.run(
          URL(fileURLWithPath: SSHCommand.sshExecutablePath), arguments, nil
        )
      }
      group.addTask {
        try await Task.sleep(for: .seconds(10))
        throw TimeoutError()
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }
}
