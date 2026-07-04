import Darwin
import Foundation

/// Raw POSIX helpers for the serve-mode port bridge (prior art:
/// `AgentHookSocketServer`). `allocate` asks the kernel for a free ephemeral
/// port; `canConnect` health-checks a forwarded port before reuse.
nonisolated enum LoopbackPort {
  struct AllocationError: Error {
    let detail: String
  }

  /// Bind `127.0.0.1:0`, read back the kernel-assigned ephemeral port, and
  /// release it. The port is free at return but unreserved (TOCTOU accepted):
  /// on a forward failure the caller retries with a fresh allocation.
  /// Deliberately no `SO_REUSEADDR` — the probe should see the port exactly
  /// as ssh's `-L` listener will.
  static func allocate() throws -> Int {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw AllocationError(detail: "socket: \(Self.errnoDescription())") }
    defer { close(socketFD) }
    var address = Self.loopbackAddress(port: 0)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { throw AllocationError(detail: "bind: \(Self.errnoDescription())") }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let resolved = withUnsafeMutablePointer(to: &assigned) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socketFD, $0, &length)
      }
    }
    guard resolved == 0 else { throw AllocationError(detail: "getsockname: \(Self.errnoDescription())") }
    return Int(UInt16(bigEndian: assigned.sin_port))
  }

  /// Whether something is listening on `127.0.0.1:port`, via a non-blocking
  /// connect. A *connect* probe, not a bind probe: after a master dies, its
  /// TIME_WAIT sockets hold the port for ~30-60s and would false-positive a
  /// bind check, delaying repair; a connect to a dead port gets an immediate
  /// RST. ssh sets `SO_REUSEADDR` on its `-L` listeners, so re-forwarding
  /// onto a TIME_WAIT-laden port works.
  static func canConnect(port: Int) -> Bool {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return false }
    defer { close(socketFD) }
    let flags = fcntl(socketFD, F_GETFL)
    guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }
    var address = Self.loopbackAddress(port: UInt16(clamping: port))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if result == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var pollFD = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
    guard poll(&pollFD, 1, 1000) > 0, pollFD.revents & Int16(POLLOUT) != 0 else { return false }
    var socketError: Int32 = -1
    var errorLength = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 else { return false }
    return socketError == 0
  }

  private static func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
    return address
  }

  private static func errnoDescription() -> String {
    String(cString: strerror(errno))
  }
}
