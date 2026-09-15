// Spind — Copyright (C) 2026 Christoph Lindl-Guk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public
// License along with this program. If not, see <https://www.gnu.org/licenses/>.

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
    private let maxConnections: Int
    private let healthCheckAfterIdle: TimeInterval = 30
    private var idle: [PooledClient] = []
    private var liveCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(config: SpindConfig, maxConnections: Int = 3) {
        self.config = config
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
                    let client = StorageBoxClient(config: config)
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
