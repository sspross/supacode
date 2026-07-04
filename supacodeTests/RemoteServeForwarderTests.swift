import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct RemoteServeForwarderTests {
  private let host = RemoteHost(alias: "devbox")
  private let worktreeID = WorktreeID("devbox/home/me/wt")
  private let remoteURL = URL(string: "http://127.0.0.1:3000/")!

  @Test func firstCallForwardsAndRewrites() async throws {
    let harness = makeHarness(ports: [50001])
    let url = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    #expect(url == URL(string: "http://127.0.0.1:50001/"))
    #expect(
      harness.sshCalls.value == [
        CustomCodeSSH.muxForwardInvocation(
          host: host, localPort: 50001, targetHost: "127.0.0.1", targetPort: 3000
        )
      ]
    )
  }

  @Test func aliveMappingReusesWithoutSSH() async throws {
    let harness = makeHarness(ports: [50001], alive: { _ in true })
    let first = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    let second = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    // The per-tick fast path: same URL, and no ssh beyond the initial forward.
    #expect(second == first)
    #expect(harness.sshCalls.value.count == 1)
  }

  @Test func deadListenerRepairsOnSamePort() async throws {
    // A single scripted port proves repair never re-allocates: the same local
    // port keeps the URL stable so the page's in-page state survives.
    let harness = makeHarness(ports: [50001], alive: { _ in false })
    let first = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    let second = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    #expect(second == first)
    let expectedForward = CustomCodeSSH.muxForwardInvocation(
      host: host, localPort: 50001, targetHost: "127.0.0.1", targetPort: 3000
    )
    #expect(harness.sshCalls.value == [expectedForward, expectedForward])
  }

  @Test func remoteURLChangeCancelsOldForwardAndRekeysToNewPort() async throws {
    let harness = makeHarness(ports: [50001, 50002])
    _ = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    let movedURL = URL(string: "http://127.0.0.1:4000/")!
    let rekeyed = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: movedURL
    )
    // A respawned server gets a NEW local port so the URL changes and the
    // webview reloads, exactly like a local respawn.
    #expect(rekeyed == URL(string: "http://127.0.0.1:50002/"))
    #expect(
      harness.sshCalls.value == [
        CustomCodeSSH.muxForwardInvocation(
          host: host, localPort: 50001, targetHost: "127.0.0.1", targetPort: 3000
        ),
        CustomCodeSSH.muxCancelForwardInvocation(
          host: host, localPort: 50001, targetHost: "127.0.0.1", targetPort: 3000
        ),
        CustomCodeSSH.muxForwardInvocation(
          host: host, localPort: 50002, targetHost: "127.0.0.1", targetPort: 4000
        ),
      ]
    )
  }

  @Test func cancelFailureDuringRekeyIsSwallowed() async throws {
    let harness = makeHarness(
      ports: [50001, 50002],
      sshErrors: [nil, sshError(exitCode: 255), nil]
    )
    _ = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    let rekeyed = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: URL(string: "http://127.0.0.1:4000/")!
    )
    #expect(rekeyed == URL(string: "http://127.0.0.1:50002/"))
  }

  @Test func coldControlSocketProbesThenRetriesForwardOnce() async throws {
    let harness = makeHarness(
      ports: [50001],
      sshErrors: [sshError(exitCode: 255), nil, nil]
    )
    let url = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    #expect(url == URL(string: "http://127.0.0.1:50001/"))
    let forward = CustomCodeSSH.muxForwardInvocation(
      host: host, localPort: 50001, targetHost: "127.0.0.1", targetPort: 3000
    )
    #expect(
      harness.sshCalls.value == [
        forward,
        CustomCodeSSH.muxProbeInvocation(host: host),
        forward,
      ]
    )
  }

  @Test func failureAfterRetryThrowsServeForwardFailedWithStderrDetail() async {
    let harness = makeHarness(
      ports: [50001],
      sshErrors: [
        sshError(exitCode: 255),
        nil,
        sshError(exitCode: 255, stderr: "Permission denied (publickey).\n"),
      ]
    )
    await #expect(
      throws: CustomCodeError.serveForwardFailed(
        destination: "devbox", detail: "Permission denied (publickey)."
      )
    ) {
      _ = try await harness.forwarder.localURL(
        worktreeID: worktreeID, host: host, remoteURL: remoteURL
      )
    }
  }

  @Test func failureWithEmptyStderrFallsBackToExitCodeDetail() async {
    let harness = makeHarness(
      ports: [50001],
      sshErrors: [sshError(exitCode: 255), sshError(exitCode: 255)]
    )
    await #expect(
      throws: CustomCodeError.serveForwardFailed(
        destination: "devbox", detail: "ssh exited with code 255"
      )
    ) {
      _ = try await harness.forwarder.localURL(
        worktreeID: worktreeID, host: host, remoteURL: remoteURL
      )
    }
  }

  @Test func repairFailureFallsBackToFreshPort() async throws {
    // Repair (same-port re-forward) fails outright: the mapping is dropped
    // and a fresh port is allocated, so the changed URL triggers a reload.
    let harness = makeHarness(
      ports: [50001, 50002],
      alive: { _ in false },
      sshErrors: [nil, sshError(exitCode: 255), sshError(exitCode: 255), nil]
    )
    let first = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    #expect(first == URL(string: "http://127.0.0.1:50001/"))
    let recovered = try await harness.forwarder.localURL(
      worktreeID: worktreeID, host: host, remoteURL: remoteURL
    )
    #expect(recovered == URL(string: "http://127.0.0.1:50002/"))
  }

  @Test func distinctWorktreesGetDistinctPorts() async throws {
    let harness = makeHarness(ports: [50001, 50002])
    let first = try await harness.forwarder.localURL(
      worktreeID: WorktreeID("devbox/home/me/wt-a"), host: host, remoteURL: remoteURL
    )
    let second = try await harness.forwarder.localURL(
      worktreeID: WorktreeID("devbox/home/me/wt-b"), host: host, remoteURL: remoteURL
    )
    #expect(first == URL(string: "http://127.0.0.1:50001/"))
    #expect(second == URL(string: "http://127.0.0.1:50002/"))
  }

  @Test func rewritePreservesPathQueryFragmentAndPinsIPv4Loopback() async throws {
    let harness = makeHarness(ports: [50001, 50002])
    let localhostURL = try await harness.forwarder.localURL(
      worktreeID: worktreeID,
      host: host,
      remoteURL: URL(string: "http://localhost:3000/dash?tab=1#top")!
    )
    #expect(localhostURL == URL(string: "http://127.0.0.1:50001/dash?tab=1#top"))
    let ipv6URL = try await harness.forwarder.localURL(
      worktreeID: WorktreeID("devbox/home/me/wt-6"),
      host: host,
      remoteURL: URL(string: "http://[::1]:3000/x")!
    )
    #expect(ipv6URL == URL(string: "http://127.0.0.1:50002/x"))
    // The forward targets what the script announced; the IPv6 literal rides
    // bracketed inside the -L spec.
    #expect(harness.sshCalls.value[0].contains("127.0.0.1:50001:localhost:3000"))
    #expect(harness.sshCalls.value[1].contains("127.0.0.1:50002:[::1]:3000"))
  }

  private func makeHarness(
    ports: [Int],
    alive: @escaping @Sendable (Int) -> Bool = { _ in false },
    sshErrors: [ShellClientError?] = []
  ) -> (forwarder: RemoteServeForwarder, sshCalls: LockIsolated<[[String]]>) {
    let sshCalls = LockIsolated<[[String]]>([])
    let errorQueue = LockIsolated(sshErrors)
    let portQueue = LockIsolated(ports)
    let forwarder = RemoteServeForwarder(
      runSSH: { arguments in
        sshCalls.withValue { $0.append(arguments) }
        let error = errorQueue.withValue { queue -> ShellClientError? in
          guard !queue.isEmpty else { return nil }
          return queue.removeFirst()
        }
        if let error { throw error }
      },
      allocatePort: { portQueue.withValue { $0.removeFirst() } },
      canConnect: alive
    )
    return (forwarder, sshCalls)
  }

  private func sshError(exitCode: Int32, stderr: String = "") -> ShellClientError {
    ShellClientError(command: "ssh", stdout: "", stderr: stderr, exitCode: exitCode)
  }
}
