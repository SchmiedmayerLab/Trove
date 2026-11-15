//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


actor ProviderWorkerLoop {
    private var task: Task<Void, Never>?
    let service: ProviderWorkerService

    init(service: ProviderWorkerService) { self.service = service }

    func start(logger: Logger) {
        guard task == nil else {
            return
        }
        let service = self.service
        task = Task {
            while !Task.isCancelled {
                do {
                    try await service.tick()
                } catch is CancellationError {
                    break
                } catch {
                    // The error may originate in credential-bearing transport or clinical conversion; retain no interpolated diagnostics.
                    logger.error("Provider scheduling step failed")
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
    }
}


struct ProviderWorkerLifecycle: LifecycleHandler {
    let loop: ProviderWorkerLoop

    func didBootAsync(_ application: Application) async throws {
        await loop.start(logger: application.logger)
    }

    func shutdownAsync(_ application: Application) async {
        await loop.stop()
    }
}
