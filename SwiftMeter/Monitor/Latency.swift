import Foundation
import Network

// Single-host TCP-RTT probe. We connect to the target and stop the clock as
// soon as the OS reports `.ready`. That's roughly one round-trip and avoids
// needing root for ICMP. Multi-target support is deferred to v1.3.

enum Latency {

    /// Default probe target — Cloudflare's public resolver.
    static let defaultHost = "1.1.1.1"
    static let defaultPort: UInt16 = 443

    /// Returns RTT in milliseconds, or -1 on timeout / failure.
    /// Hard-capped at `timeout` seconds.
    static func measure(host: String = defaultHost,
                        port: UInt16 = defaultPort,
                        timeout: TimeInterval = 5) async -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return -1 }

        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: nwPort,
                                      using: .tcp)
        let start = Date()

        // NSLock guards `done` — accessed from NWConnection's callback queue
        // and the timeout queue concurrently.
        let lock = NSLock()
        var done = false

        return await withCheckedContinuation { continuation in
            let finish: (Int) -> Void = { result in
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
                    connection.cancel()
                    finish(elapsed)
                case .failed, .cancelled:
                    finish(-1)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                finish(-1)
            }
        }
    }
}
