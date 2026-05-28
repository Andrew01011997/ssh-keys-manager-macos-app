import Foundation

@MainActor
extension AppModel {
    func loadConfig() {
        configCoordinator.load()
    }

    func loadConfigIfNeeded() async {
        await configCoordinator.loadIfNeeded()
    }

    func revealConfigInFinder() {
        configCoordinator.revealConfigInFinder()
    }

    func addConfigHost(_ request: SSHConfigHostSaveRequest) async throws {
        try await configCoordinator.addHost(request)
    }

    func updateConfigHost(_ entry: SSHConfigEntry, with request: SSHConfigHostSaveRequest) async throws {
        try await configCoordinator.updateHost(entry, with: request)
    }

    func deleteSelectedConfigEntry() async throws {
        try await configCoordinator.deleteSelectedEntry()
    }

    func checkConfigHostReachability() {
        configCoordinator.checkHostReachability()
    }
}

@MainActor
final class SSHConfigCoordinator {
    private unowned let model: AppModel
    private let reachabilityTimeout: Duration = .seconds(3)
    private let maximumConcurrentHostChecks = 8

    init(model: AppModel) {
        self.model = model
    }

    func load() {
        Task {
            await loadAsync()
        }
    }

    func loadIfNeeded() async {
        guard model.loadedConfigDirectoryPath != model.sshDirectoryPath else {
            return
        }

        await loadAsync()
    }

    func revealConfigInFinder() {
        guard model.canRevealSSHDirectoryInFinder else {
            return
        }

        model.keyActions.openDirectory(atPath: model.sshDirectoryPath)
    }

    func addHost(_ request: SSHConfigHostSaveRequest) async throws {
        guard !model.isReadOnlyModeEnabled else {
            model.rejectReadOnlyModeMutation()
            throw ReadOnlyModeRestrictionError.unavailable
        }

        let directoryPath = model.sshDirectoryPath

        try await model.withConfigOperation {
            do {
                try await model.configStorage.apply(
                    .add(request),
                    inDirectory: directoryPath,
                    propertyIndentation: model.hostPropertyIndentation,
                    backupLimit: model.configBackupLimit
                )
                guard directoryPath == model.sshDirectoryPath else {
                    return
                }

                try await model.reloadConfigEntries(from: directoryPath)
                guard directoryPath == model.sshDirectoryPath else {
                    return
                }

                model.invalidateConfigHostReachability()

                let addedHost = request.trimmedHost
                if let addedEntry = model.originalConfigEntries.last(where: { $0.host == addedHost }) {
                    model.selectedConfigEntryID = addedEntry.id
                } else {
                    model.selectedConfigEntryID = model.configEntries.last?.id
                }

                model.showNotification("Added SSH config host \(addedHost)", kind: .success)
            } catch {
                model.configErrorMessage = "Unable to add SSH config host: \(error.localizedDescription)"
                throw error
            }
        }
    }

    func updateHost(_ entry: SSHConfigEntry, with request: SSHConfigHostSaveRequest) async throws {
        guard !model.isReadOnlyModeEnabled else {
            model.rejectReadOnlyModeMutation()
            throw ReadOnlyModeRestrictionError.unavailable
        }

        let directoryPath = model.sshDirectoryPath

        try await model.withConfigOperation {
            do {
                try await model.configStorage.apply(
                    .update(entry: entry, request: request),
                    inDirectory: directoryPath,
                    propertyIndentation: model.hostPropertyIndentation,
                    backupLimit: model.configBackupLimit
                )
                guard directoryPath == model.sshDirectoryPath else {
                    return
                }

                try await model.reloadConfigEntries(from: directoryPath)
                guard directoryPath == model.sshDirectoryPath else {
                    return
                }

                model.invalidateConfigHostReachability()

                let updatedHost = request.trimmedHost
                if let updatedEntry = model.originalConfigEntries.first(where: { $0.host == updatedHost }) {
                    model.selectedConfigEntryID = updatedEntry.id
                } else {
                    model.selectedConfigEntryID = model.configEntries.first?.id
                }

                model.showNotification("Updated SSH config host \(updatedHost)", kind: .success)
            } catch {
                model.configErrorMessage = "Unable to update SSH config host: \(error.localizedDescription)"
                throw error
            }
        }
    }

    func deleteSelectedEntry() async throws {
        guard let selectedConfigEntry = model.selectedConfigEntry else {
            return
        }

        guard !model.isReadOnlyModeEnabled else {
            model.rejectReadOnlyModeMutation()
            throw ReadOnlyModeRestrictionError.unavailable
        }

        let directoryPath = model.sshDirectoryPath
        let previousIndex = model.configEntries.firstIndex { $0.id == selectedConfigEntry.id } ?? 0

        try await model.withConfigOperation {
            do {
                try await model.configStorage.apply(
                    .delete(entry: selectedConfigEntry),
                    inDirectory: directoryPath,
                    propertyIndentation: model.hostPropertyIndentation,
                    backupLimit: model.configBackupLimit
                )
                guard directoryPath == model.sshDirectoryPath else {
                    return
                }

                try await model.reloadConfigEntries(from: directoryPath)
                guard directoryPath == model.sshDirectoryPath else {
                    return
                }

                model.invalidateConfigHostReachability()
                selectConfigEntryAfterDeletion(previousIndex: previousIndex)
                model.showNotification("Deleted SSH config host \(selectedConfigEntry.host)", kind: .success)
            } catch {
                model.configErrorMessage = "Unable to delete SSH config host \(selectedConfigEntry.host): \(error.localizedDescription)"
                throw error
            }
        }
    }

    private func loadAsync() async {
        let previousSelection = model.selectedConfigEntryID
        let directoryPath = model.sshDirectoryPath
        var didLoadConfig = false
        model.invalidateConfigHostReachability()

        await model.withConfigOperation {
            do {
                let validatedPath = try model.validateWorkspaceDirectory(at: directoryPath)
                guard validatedPath == model.sshDirectoryPath else {
                    return
                }

                try await model.reloadConfigEntries(from: directoryPath)

                if let previousSelection, model.configEntries.contains(where: { $0.id == previousSelection }) {
                    model.selectedConfigEntryID = previousSelection
                } else {
                    model.selectedConfigEntryID = model.configEntries.first?.id
                }

                didLoadConfig = true
            } catch SSHConfigLoadError.fileMissing {
                guard directoryPath == model.sshDirectoryPath else {
                    return
                }

                model.configEntries = []
                model.originalConfigEntries = []
                model.selectedConfigEntryID = nil
                model.isConfigFileMissing = true
            } catch {
                guard directoryPath == model.sshDirectoryPath else {
                    return
                }

                model.configEntries = []
                model.originalConfigEntries = []
                model.selectedConfigEntryID = nil
                model.configErrorMessage = "Unable to load SSH config: \(error.localizedDescription)"
            }

            if didLoadConfig, directoryPath == model.sshDirectoryPath {
                model.loadedConfigDirectoryPath = directoryPath
            }
        }

        guard didLoadConfig, directoryPath == model.sshDirectoryPath else {
            return
        }

        scheduleAutoCheckAfterLoadIfNeeded()
    }

    private func selectConfigEntryAfterDeletion(previousIndex: Int) {
        guard !model.configEntries.isEmpty else {
            model.selectedConfigEntryID = nil
            return
        }

        let nextIndex = min(previousIndex, model.configEntries.count - 1)
        model.selectedConfigEntryID = model.configEntries[nextIndex].id
    }

    func checkHostReachability() {
        let directoryPath = model.sshDirectoryPath
        let entries = model.configEntries
        let retainedModel = model
        let preparedEntries = entries.map { entry in
            (entry, SSHHostReachabilityResolver.resolveTarget(for: entry))
        }

        model.configHostReachabilityTask?.cancel()
        model.configHostCheckGeneration += 1
        let generation = model.configHostCheckGeneration

        var statuses: [SSHConfigEntry.ID: SSHConfigHostReachabilityStatus] = [:]
        var initialErrorCount = 0
        var readyEntries: [(SSHConfigEntry, SSHHostReachabilityTarget)] = []

        for (entry, resolution) in preparedEntries {
            switch resolution {
            case .unsupported:
                break
            case .invalidConfiguration:
                statuses[entry.id] = .error
                initialErrorCount += 1
            case .target(let target):
                statuses[entry.id] = .checking
                readyEntries.append((entry, target))
            }
        }

        model.configHostStatuses = statuses
        model.isCheckingConfigHosts = !readyEntries.isEmpty

        guard !readyEntries.isEmpty else {
            if initialErrorCount > 0 {
                model.showConfigReachabilityErrorSummary(count: initialErrorCount)
            }
            return
        }

        model.configHostReachabilityTask = Task {
            await runReachabilityChecks(
                model: retainedModel,
                entries: readyEntries,
                directoryPath: directoryPath,
                generation: generation,
                initialErrorCount: initialErrorCount
            )
        }
    }

    func scheduleAutoCheckAfterLoadIfNeeded() {
        guard !model.configEntries.isEmpty else {
            return
        }

        checkHostReachability()
    }

    private func runReachabilityChecks(
        model: AppModel,
        entries: [(SSHConfigEntry, SSHHostReachabilityTarget)],
        directoryPath: String,
        generation: Int,
        initialErrorCount: Int
    ) async {
        var errorCount = initialErrorCount

        for batchStart in stride(from: 0, to: entries.count, by: maximumConcurrentHostChecks) {
            if Task.isCancelled {
                return
            }

            let batchEnd = min(batchStart + maximumConcurrentHostChecks, entries.count)
            let batch = Array(entries[batchStart..<batchEnd])

            let results = await withTaskGroup(
                of: (SSHConfigEntry.ID, SSHHostReachabilityCheckResult).self,
                returning: [(SSHConfigEntry.ID, SSHHostReachabilityCheckResult)].self
            ) { group in
                for (entry, target) in batch {
                    let checker = model.hostReachabilityChecker
                    group.addTask {
                        let result = await checker.check(
                            target: target,
                            timeout: self.reachabilityTimeout
                        )
                        return (entry.id, result)
                    }
                }

                var collected: [(SSHConfigEntry.ID, SSHHostReachabilityCheckResult)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            await MainActor.run {
                guard self.isCurrentReachabilityRun(model: model, generation: generation, directoryPath: directoryPath) else {
                    return
                }

                for (entryID, result) in results {
                    switch result {
                    case .reachable:
                        self.model.configHostStatuses[entryID] = .reachable
                    case .unreachable:
                        self.model.configHostStatuses[entryID] = .unreachable
                    case .error:
                        self.model.configHostStatuses[entryID] = .error
                        errorCount += 1
                    }
                }
            }
        }

        await MainActor.run {
            guard self.isCurrentReachabilityRun(model: model, generation: generation, directoryPath: directoryPath) else {
                return
            }

            model.isCheckingConfigHosts = false
            model.configHostReachabilityTask = nil

            if errorCount > 0 {
                model.showConfigReachabilityErrorSummary(count: errorCount)
            }
        }
    }

    private func isCurrentReachabilityRun(model: AppModel, generation: Int, directoryPath: String) -> Bool {
        generation == model.configHostCheckGeneration && directoryPath == model.sshDirectoryPath
    }
}
