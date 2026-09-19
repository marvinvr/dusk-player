import Foundation

/// One server's answer to a fanned-out request.
struct ServerResult<Value: Sendable>: Sendable {
    let serverID: String
    /// Position of the server in priority order, so a streamed result can be
    /// filed back into a priority-ordered array without re-sorting.
    let rank: Int
    let value: Value
}

/// Fan-out helpers: ask every connected server the same question at once.
///
/// Two rules shape everything here. A server that fails contributes an empty
/// answer instead of failing the request, because one unreachable share must
/// never empty a screen that three other servers could fill. And results are
/// committed per server as they land, so a relay connection on the other side
/// of the world never holds up the box on the same LAN.
extension PlexService {
    /// Connected servers in priority order.
    var mergeServerIDs: [String] {
        pool.connections.map(\.serverID)
    }

    /// Runs `operation` on every connected server concurrently and returns the
    /// answers in priority order, once they have all landed.
    func fanOutAcrossServers<Value: Sendable>(
        _ operation: @Sendable @escaping (PlexService, String) async -> Value
    ) async -> [ServerResult<Value>] {
        let service = self
        let serverIDs = mergeServerIDs
        guard !serverIDs.isEmpty else { return [] }

        return await withTaskGroup(of: ServerResult<Value>.self) { group in
            for (rank, serverID) in serverIDs.enumerated() {
                group.addTask {
                    ServerResult(
                        serverID: serverID,
                        rank: rank,
                        value: await operation(service, serverID)
                    )
                }
            }

            var results: [ServerResult<Value>] = []
            results.reserveCapacity(serverIDs.count)
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.rank < $1.rank }
        }
    }

    /// Same fan-out, but each answer is published the moment it arrives so a
    /// screen can render the first server's content and refine it afterwards.
    func streamAcrossServers<Value: Sendable>(
        _ operation: @Sendable @escaping (PlexService, String) async -> Value
    ) -> AsyncStream<ServerResult<Value>> {
        let service = self
        let serverIDs = mergeServerIDs

        return AsyncStream { continuation in
            guard !serverIDs.isEmpty else {
                continuation.finish()
                return
            }

            let task = Task {
                await withTaskGroup(of: ServerResult<Value>.self) { group in
                    for (rank, serverID) in serverIDs.enumerated() {
                        group.addTask {
                            ServerResult(
                                serverID: serverID,
                                rank: rank,
                                value: await operation(service, serverID)
                            )
                        }
                    }
                    for await result in group {
                        continuation.yield(result)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Merged endpoints

    /// `/hubs` from every connected server, streamed. Each element carries that
    /// server's filtered rows; the caller merges what it has so far.
    func streamHomeHubs() -> AsyncStream<ServerResult<[PlexHub]>> {
        streamAcrossServers { service, serverID in
            (try? await service.getHubs(serverID: serverID)) ?? []
        }
    }

    /// `/hubs/continueWatching` from every connected server, streamed.
    func streamContinueWatching() -> AsyncStream<ServerResult<[PlexItem]>> {
        streamAcrossServers { service, serverID in
            (try? await service.getContinueWatching(serverID: serverID)) ?? []
        }
    }

    /// `/hubs/search` on every connected server, streamed so results appear as
    /// each one answers. The `Result` distinguishes "answered with nothing" from
    /// "failed", which is what lets search report an error only when every
    /// server failed.
    func streamSearch(query: String) -> AsyncStream<ServerResult<Result<[PlexSearchResult], any Error>>> {
        streamAcrossServers { service, serverID in
            do {
                return .success(try await service.search(query: query, serverID: serverID))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Pages a merged hub row by following each contributing source on its own
    /// server, then re-merging. Sources are already in priority order.
    func mergedHubItems(for hub: PlexHub, size: Int? = nil) async -> MergedPlexItems {
        let sources = hub.sources.filter { $0.key?.nilIfEmpty != nil }
        guard !sources.isEmpty else { return .empty }

        let service = self
        let lists = await withTaskGroup(of: (Int, [PlexItem]).self) { group in
            for (index, source) in sources.enumerated() {
                guard let key = source.key else { continue }
                let serverID = source.serverID
                group.addTask {
                    let items = (try? await service.getHubItems(
                        hubKey: key,
                        size: size,
                        serverID: serverID
                    )) ?? []
                    return (index, items)
                }
            }

            var results: [(Int, [PlexItem])] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        return PlexItemMerge.interleave(lists)
    }

    /// Records a merge's findings so playback can fall back to another server.
    ///
    /// Single-copy entries are registered too: they teach the index which
    /// content key that id belongs to, so the same title seen on another server
    /// on a different screen links up with it later.
    func registerAlternates(_ table: [PlexContentKey: [PlexItemID]]) {
        for (key, ids) in table {
            alternates.register(ids, for: key)
        }
    }
}
