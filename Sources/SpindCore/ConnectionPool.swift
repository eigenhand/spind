// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reuses SSH connections across operations instead of paying the
/// ~1s handshake per call. Connections are checked out exclusively,
/// health-checked after idling, and discarded on any operation error.
public actor StorageBoxConnectionPool {
    private struct PooledClient {
        let client: StorageBoxClient
        var idleSince: Date
    }

    private let config: SpindConfig
    private let pinStore: URL?
    private let maxConnections: Int
    private let healthCheckAfterIdle: TimeInterval = 30
    private var idle: [PooledClient] = []
    private var liveCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter pinStore: see `StorageBoxClient.init(config:pinStore:)`.
    public init(config: SpindConfig, maxConnections: Int = 3, pinStore: URL? = nil) {
        self.config = config
        self.pinStore = pinStore
        self.maxConnections = maxConnections
    }

    public func withClient<T>(
        _ body: @Sendable (StorageBoxClient) async throws -> T
    ) async throws -> T {
        let client = try await checkout()
        do {
            let result = try await body(client)
            checkin(client)
            return result
        } catch {
            // The connection may be the reason for the failure; don't
            // risk handing it out again.
            await discard(client)
            throw error
        }
    }

    public func drain() async {
        for pooled in idle {
            await pooled.client.disconnect()
        }
        liveCount -= idle.count
        idle.removeAll()
    }

    private func checkout() async throws -> StorageBoxClient {
        while true {
            if var pooled = idle.popLast() {
                if Date().timeIntervalSince(pooled.idleSince) > healthCheckAfterIdle {
                    do {
                        _ = try await pooled.client.stat(".")
                    } catch {
                        await pooled.client.disconnect()
                        liveCount -= 1
                        continue
                    }
                    pooled.idleSince = Date()
                }
                return pooled.client
            }
            if liveCount < maxConnections {
                liveCount += 1
                do {
                    let client = StorageBoxClient(config: config, pinStore: pinStore)
                    try await client.connect()
                    return client
                } catch {
                    liveCount -= 1
                    resumeOneWaiter()
                    throw error
                }
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func checkin(_ client: StorageBoxClient) {
        idle.append(PooledClient(client: client, idleSince: Date()))
        resumeOneWaiter()
    }

    private func discard(_ client: StorageBoxClient) async {
        await client.disconnect()
        liveCount -= 1
        resumeOneWaiter()
    }

    private func resumeOneWaiter() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}
