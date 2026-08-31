import CoreGraphics
import Darwin
import EryloCore
import EryloSettingsUI
import EryloTrust
import Foundation

@main
@MainActor
enum TrustHarnessMain {
    static func main() async {
        let harness = TrustHarness()
        await harness.run()
        harness.finish()
    }
}

@MainActor
private final class TrustHarness {
    private var checkCount = 0
    private var failures: [String] = []

    func run() async {
        await verifySafeDefaultsAndCompatibility()
        await verifyMigrationCorruptionAndBounds()
        await verifyAtomicPersistence()
        await verifyNoWorkWhileBrowsingOrDisabled()
        await verifyPromptFreePersistedRestore()
        await verifyConcurrentToggleSerialization()
        await verifyQueueCancellationCoalescingAndCapacity()
        await verifyCancellationDuringPermissionAndStart()
        await verifyLifecycleStopAndFailureRollback()
        await verifyResetAndTerminalStopAll()
        await verifyLaunchAtLoginSeam()
        await verifyDisplayScopeBoundsAndUIOrdering()
        await verifyDiagnosticsSchemaRedactionAndBounds()
        await verifyMaliciousCollectorReboundingAndExportFailures()
        verifyAccessibilityCopy()
    }

    private func verifySafeDefaultsAndCompatibility() async {
        let defaults = EryloSettings.safeDefaults
        check(EryloModule.allCases.allSatisfy { !defaults.modules[$0] }, "safe defaults disable every module")
        check(!defaults.crashAndDiagnosticSharingConsent, "crash and diagnostic sharing is opt-in")
        check(!defaults.launchAtLogin, "launch at login defaults off")
        check(defaults.motion == .systemDefault, "motion follows the system by default")
        check(defaults.fullscreenBehavior == .hide, "fullscreen behavior defaults to hidden")
        check(!MotionPreference.systemDefault.shouldReduceMotion(systemValue: false), "system motion preserves false")
        check(MotionPreference.systemDefault.shouldReduceMotion(systemValue: true), "system motion preserves true")
        check(MotionPreference.reduce.shouldReduceMotion(systemValue: false), "explicit Reduce Motion always reduces")
        check(EryloModule.calendar.permissionRequirement == .calendar, "Calendar owns the Calendar permission policy")
        check(EryloModule.appleMusic.permissionRequirement == .appleEvents, "Apple Music owns the Apple Events policy")
        check(EryloModule.spotify.permissionRequirement == .appleEvents, "Spotify owns the Apple Events policy")
        check(EryloModule.fileHold.permissionRequirement == nil, "File Hold does not pre-request a generic permission")
        check(EryloModule.localIntegrations.permissionRequirement == nil, "local integrations do not pre-request a system permission")
        check(ModuleCopy.explanation(for: .appleMusic).contains("not included"), "Apple Music copy is explicit future work")
        check(ModuleCopy.explanation(for: .spotify).contains("not included"), "Spotify copy is explicit future work")

        let main = display(10, isMain: true)
        let external = display(20)
        let preferences = DisplayPreferences(
            isEnabled: true,
            enabledDisplayIDs: [20, 20],
            selectedDisplayID: 20
        )
        let resolution = preferences.displayPolicy.resolve([main, external])
        check(resolution.enabledDisplays.map(\.identity) == [external.identity], "display preferences map to DisplayPolicy")
        check(resolution.selectedDisplayIdentity == external.identity, "display selection maps to DisplayPolicy")
    }

    private func verifyMigrationCorruptionAndBounds() async {
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "modules": {
            "fileHold": false, "appleMusic": false, "spotify": false,
            "battery": true, "timer": false, "calendar": false,
            "volume": true, "localIntegrations": false
          },
          "displayEnabled": true,
          "enabledDisplayIDs": [42, 7, 42],
          "selectedDisplayID": 42,
          "reduceMotion": true,
          "fullscreenBehavior": "remain-available",
          "launchAtLogin": true,
          "diagnosticSharingConsent": true
        }
        """
        let storage = TestAtomicSettingsStorage(initialData: Data(legacyJSON.utf8))
        let repository = SettingsRepository(storage: storage)
        let migrated = await repository.current()
        let report = await repository.loadReport()
        check(migrated.schemaVersion == EryloSettings.currentSchemaVersion, "v1 migrates to current schema")
        check(migrated.modules.battery && migrated.modules.volume, "v1 module values migrate")
        check(migrated.displays.enabledDisplayIDs == [7, 42], "migration deduplicates display IDs")
        check(migrated.motion == .reduce, "legacy Reduce Motion migrates")
        check(migrated.fullscreenBehavior == .remainAvailable, "fullscreen preference migrates")
        check(migrated.crashAndDiagnosticSharingConsent, "legacy diagnostic consent migrates to explicit crash and diagnostic consent")
        check(!migrated.onboardingCompleted, "new migration field uses safe default")
        check(report.disposition == .migrated && report.migrationWasPersisted, "migration persistence is reported")
        check(storage.successfulReplacementCount == 1, "migration uses one whole-value replacement")

        let readOnlyMigrationStorage = TestAtomicSettingsStorage(initialData: Data(legacyJSON.utf8))
        let readOnlyMigrationRepository = SettingsRepository(
            storage: readOnlyMigrationStorage,
            automaticallyPersistsMigrations: false
        )
        check(
            await readOnlyMigrationRepository.current().schemaVersion == EryloSettings.currentSchemaVersion,
            "read-only loading still exposes the migrated settings value"
        )
        check(
            readOnlyMigrationStorage.successfulReplacementCount == 0,
            "read-only loading performs no migration write"
        )

        let corruptStorage = TestAtomicSettingsStorage(initialData: Data("not-json".utf8))
        let corruptRepository = SettingsRepository(storage: corruptStorage)
        check(await corruptRepository.current() == .safeDefaults, "corruption falls back to safe defaults")
        check(await corruptRepository.loadReport().disposition == .corrupt, "corruption is reported")
        check(corruptStorage.successfulReplacementCount == 0, "corrupt bytes are not overwritten on read")

        let futureRepository = SettingsRepository(
            storage: TestAtomicSettingsStorage(initialData: Data("{\"schemaVersion\":999}".utf8))
        )
        check(await futureRepository.current() == .safeDefaults, "future schema falls back safely")
        check(await futureRepository.loadReport().disposition == .unsupportedVersion, "future schema is reported distinctly")

        let hugeData = Data(repeating: 0x20, count: SettingsLimits.maximumEncodedBytes + 1)
        let hugeStorage = TestAtomicSettingsStorage(initialData: hugeData)
        let hugeRepository = SettingsRepository(storage: hugeStorage)
        check(await hugeRepository.current() == .safeDefaults, "oversized persisted settings fall back before decode")
        check(await hugeRepository.loadReport().disposition == .oversized, "oversized settings are reported")
        check(hugeStorage.successfulReplacementCount == 0, "oversized bytes are not rewritten automatically")

        let manyIDs = (0..<10_000).map(UInt32.init)
        let boundedPreferences = DisplayPreferences(enabledDisplayIDs: manyIDs)
        check(
            boundedPreferences.enabledDisplayIDs?.count == SettingsLimits.maximumEnabledDisplayIDs,
            "display preference initializer caps IDs"
        )
        var directMutation = EryloSettings.safeDefaults
        directMutation.displays.enabledDisplayIDs = manyIDs + manyIDs
        do {
            let data = try SettingsCodec().encode(directMutation)
            check(data.count <= SettingsLimits.maximumEncodedBytes, "settings encode remains byte bounded")
            let decoded = SettingsCodec().decode(data).settings
            check(
                decoded.displays.enabledDisplayIDs?.count == SettingsLimits.maximumEnabledDisplayIDs,
                "encode normalizes a directly mutated oversized ID array"
            )
        } catch {
            check(false, "bounded settings encode produced unexpected error")
        }
    }

    private func verifyAtomicPersistence() async {
        let codec = SettingsCodec()
        let storage = TestAtomicSettingsStorage(initialData: try? codec.encode(.safeDefaults))
        let repository = SettingsRepository(storage: storage)
        let before = storage.currentData
        storage.failNextReplacement()
        do {
            _ = try await repository.update { $0.modules.battery = true }
            check(false, "failed storage replacement throws")
        } catch let error {
            check(error == .storageWriteFailed, "storage failure is typed")
        }
        check(await repository.current() == .safeDefaults, "failed write leaves memory unchanged")
        check(storage.currentData == before, "failed write leaves prior complete value readable")
        check(storage.replacementAttemptCount == 1, "mutation attempts one atomic replacement")

        do {
            _ = try await repository.update { $0.modules.battery = true }
        } catch {
            check(false, "subsequent atomic write produced unexpected error")
        }
        check(codec.decode(storage.currentData).settings.modules.battery, "persisted blob is a complete updated value")
        check(storage.successfulReplacementCount == 1, "successful mutation uses one whole-value write")
    }

    private func verifyNoWorkWhileBrowsingOrDisabled() async {
        let provider = TestLifecycleProvider()
        let permissions = TestPermissionRequester()
        let fixture = makeFixture(provider: provider, permissionRequester: permissions)
        let writer = CapturingDiagnosticsWriter()
        let model = TrustSettingsViewModel(
            coordinator: fixture.coordinator,
            diagnosticsExporter: DiagnosticsExporter(
                collector: PrivacyPreservingDiagnosticsCollector(
                    metadata: SafeMetadataProvider(),
                    eventSource: fixture.events,
                    clock: FixedClock()
                ),
                writer: writer
            )
        )
        _ = TrustSettingsView(model: model, destinationChooser: CancelDestinationChooser())
        check(await fixture.factory.makeCount == 0, "constructing settings UI constructs no provider")
        check(await provider.startCount == 0, "constructing settings UI starts no provider")
        check(await permissions.requestCount == 0, "constructing settings UI requests no permission")

        await model.load()
        check(await fixture.factory.makeCount == 0, "browsing settings constructs no provider")
        check(await provider.startCount == 0, "browsing settings starts no provider")
        check(await permissions.requestCount == 0, "browsing settings requests no permission")

        _ = await fixture.coordinator.setModuleEnabled(.calendar, enabled: false)
        check(await fixture.factory.makeCount == 0, "disabled module constructs nothing")
        check(await provider.startCount == 0, "disabled module has zero starts")
        check(await permissions.requestCount == 0, "disabled module has zero permission requests")
        check(await fixture.coordinator.activeModules().isEmpty, "disabled state retains no provider")

        let unavailableModel = TrustSettingsViewModel(
            coordinator: fixture.coordinator,
            diagnosticsExporter: DiagnosticsExporter(
                collector: PrivacyPreservingDiagnosticsCollector(
                    metadata: SafeMetadataProvider(),
                    eventSource: fixture.events,
                    clock: FixedClock()
                ),
                writer: writer
            ),
            availableModules: [],
            supportsMotionPreference: false,
            supportsFullscreenPreference: false
        )
        await unavailableModel.setModuleEnabled(.calendar, enabled: true)
        check(await fixture.factory.makeCount == 0, "unavailable UI module cannot construct a provider")
        check(await permissions.requestCount == 0, "unavailable UI module cannot request permission")
        await unavailableModel.setMotion(.reduce)
        await unavailableModel.setFullscreen(.remainAvailable)
        check(await fixture.repository.current().motion == .systemDefault, "unavailable motion control cannot persist")
        check(await fixture.repository.current().fullscreenBehavior == .hide, "unavailable fullscreen control cannot persist")
    }

    private func verifyPromptFreePersistedRestore() async {
        do {
            var persisted = EryloSettings.safeDefaults
            persisted.modules.battery = true
            persisted.modules.volume = true
            let storage = TestAtomicSettingsStorage(
                initialData: try SettingsCodec().encode(persisted)
            )
            let provider = TestLifecycleProvider()
            let permissions = TestPermissionRequester()
            let fixture = makeFixture(
                storage: storage,
                provider: provider,
                permissionRequester: permissions
            )

            let firstRestore = await fixture.coordinator.startEnabledModules()
            check(firstRestore.count == 2, "persisted restore evaluates exactly the two enabled modules")
            check(
                await fixture.factory.madeModules == [.battery, .volume],
                "persisted Battery and Volume restore through the provider factory"
            )
            check(await provider.startCount == 2, "persisted Battery and Volume each start once")
            check(await permissions.requestCount == 0, "persisted restore never requests permission")
            check(
                await fixture.coordinator.activeModules() == [.battery, .volume],
                "persisted restore retains exactly the enabled module lifecycles"
            )
            check(
                await fixture.repository.current().modules.enabledModules == [.battery, .volume],
                "successful restore preserves persisted enable intent"
            )

            let repeatedRestore = await fixture.coordinator.startEnabledModules()
            check(
                repeatedRestore.allSatisfy { $0.outcome == .noChange },
                "repeated persisted restore is lifecycle-idempotent"
            )
            check(await fixture.factory.makeCount == 2, "repeated persisted restore constructs no duplicate providers")
            check(await provider.startCount == 2, "repeated persisted restore starts no duplicate work")

            let stopped = await fixture.coordinator.stopAll()
            check(stopped.stoppedModules == [.battery, .volume], "terminal restore cleanup reports both modules")
            check(await provider.stopCount == 2, "terminal restore cleanup awaits both provider stops")
            check(await fixture.coordinator.activeModules().isEmpty, "terminal restore cleanup releases provider ownership")
        } catch {
            check(false, "persisted restore fixture encodes valid settings: \(error)")
        }

        do {
            var persisted = EryloSettings.safeDefaults
            persisted.modules.battery = true
            let storage = TestAtomicSettingsStorage(
                initialData: try SettingsCodec().encode(persisted)
            )
            let provider = TestLifecycleProvider()
            await provider.failNextStart()
            let fixture = makeFixture(storage: storage, provider: provider)
            let results = await fixture.coordinator.startEnabledModules()
            check(results.first?.failure == .providerStartFailed, "persisted start failure is surfaced")
            check(!(await fixture.repository.current().modules.battery), "persisted start failure converges intent to off")
            check(await provider.stopCount == 1, "persisted start failure awaits provider cleanup")
            check(await fixture.coordinator.activeModules().isEmpty, "persisted start failure retains no lifecycle ownership")
        } catch {
            check(false, "persisted failure fixture encodes valid settings: \(error)")
        }
    }

    private func verifyConcurrentToggleSerialization() async {
        let provider = BlockingStartProvider()
        let fixture = makeFixture(provider: provider)
        let enable = Task { await fixture.coordinator.setModuleEnabled(.battery, enabled: true) }
        check(await waitUntil { await provider.startCount == 1 }, "first concurrent toggle reaches start")
        let disable = Task { await fixture.coordinator.setModuleEnabled(.battery, enabled: false) }
        for _ in 0..<50 { await Task.yield() }
        check(await provider.stopCount == 0, "second toggle waits for first transaction")
        await provider.releaseStart()
        _ = await enable.value
        _ = await disable.value
        check(await provider.startCount == 1, "serialized enable starts once")
        check(await provider.stopCount == 1, "serialized disable stops once")
        check(!(await fixture.repository.current().modules.battery), "concurrent final state is disabled")
        check(await fixture.coordinator.activeModules().isEmpty, "concurrent disable releases provider")
    }

    private func verifyQueueCancellationCoalescingAndCapacity() async {
        do {
            let blocker = BlockingStartProvider()
            let fixture = makeFixture(provider: blocker)
            let active = Task { await fixture.coordinator.setModuleEnabled(.battery, enabled: true) }
            check(await waitUntil { await blocker.startCount == 1 }, "queue cancellation fixture is blocked")
            let cancelled = Task {
                await fixture.coordinator.setModuleEnabled(.calendar, enabled: true)
            }
            for _ in 0..<20 { await Task.yield() }
            cancelled.cancel()
            let cancelledResult = await cancelled.value
            check(cancelledResult.failure == .operationCancelled, "cancelled queued toggle returns cancelled")
            await blocker.releaseStart()
            _ = await active.value
            check(await fixture.factory.madeModules == [.battery], "cancelled queued toggle never reaches factory")
        }

        do {
            let blocker = BlockingStartProvider()
            let fixture = makeFixture(provider: blocker)
            let active = Task { await fixture.coordinator.setModuleEnabled(.battery, enabled: true) }
            check(await waitUntil { await blocker.startCount == 1 }, "coalescing fixture is blocked")
            let older = Task { await fixture.coordinator.setModuleEnabled(.timer, enabled: true) }
            for _ in 0..<20 { await Task.yield() }
            let newer = Task { await fixture.coordinator.setModuleEnabled(.timer, enabled: false) }
            let olderResult = await older.value
            check(olderResult.failure == .operationSuperseded, "newer same-module toggle supersedes queued predecessor")
            await blocker.releaseStart()
            _ = await active.value
            let newerResult = await newer.value
            check(newerResult.outcome == .noChange, "coalesced newest disabled state executes")
            check(!(await fixture.repository.current().modules.timer), "coalescing preserves newest module state")
            check(!(await fixture.factory.madeModules.contains(.timer)), "superseded enable never constructs provider")
        }

        do {
            let blocker = BlockingStartProvider()
            let fixture = makeFixture(provider: blocker)
            let active = Task { await fixture.coordinator.setModuleEnabled(.fileHold, enabled: true) }
            check(await waitUntil { await blocker.startCount == 1 }, "capacity fixture is blocked")
            let otherModules = EryloModule.allCases.filter { $0 != .fileHold }
            var queued: [Task<TrustSettingsUpdateResult, Never>] = []
            for module in otherModules {
                queued.append(Task { await fixture.coordinator.setModuleEnabled(module, enabled: false) })
                for _ in 0..<5 { await Task.yield() }
            }
            queued.append(Task { await fixture.coordinator.apply(.motion(.reduce)) })
            for _ in 0..<20 { await Task.yield() }
            let overflow = await fixture.coordinator.apply(.fullscreen(.remainAvailable))
            check(overflow.failure == .queueCapacityExceeded, "bounded queue rejects excess distinct work")
            queued.forEach { $0.cancel() }
            for task in queued { _ = await task.value }
            await blocker.releaseStart()
            _ = await active.value
        }
    }

    private func verifyCancellationDuringPermissionAndStart() async {
        do {
            let provider = TestLifecycleProvider()
            let permissions = BlockingPermissionRequester()
            let fixture = makeFixture(provider: provider, permissionRequester: permissions)
            let task = Task {
                await fixture.coordinator.setModuleEnabled(
                    .calendar,
                    enabled: true,
                    permissionPolicy: .requestIfNeeded
                )
            }
            check(await waitUntil { await permissions.requestCount == 1 }, "permission cancellation reaches explicit request")
            task.cancel()
            await permissions.releaseRequest()
            let result = await task.value
            check(result.failure == .operationCancelled, "cancel after permission is reported")
            check(await fixture.factory.makeCount == 0, "cancel after permission constructs no provider")
            check(await provider.startCount == 0, "cancel after permission starts no provider")
            check(!(await fixture.repository.current().modules.calendar), "cancel after permission commits no setting")
        }

        do {
            let provider = BlockingStartProvider()
            let fixture = makeFixture(provider: provider)
            let task = Task { await fixture.coordinator.setModuleEnabled(.battery, enabled: true) }
            check(await waitUntil { await provider.startCount == 1 }, "start cancellation reaches provider")
            task.cancel()
            await provider.releaseStart()
            let result = await task.value
            check(result.failure == .operationCancelled, "cancel during start is reported")
            check(await provider.stopCount == 1, "cancel during start performs awaited stop cleanup")
            check(!(await fixture.repository.current().modules.battery), "cancel during start commits no setting")
            check(await fixture.coordinator.activeModules().isEmpty, "cancelled start is not retained")
        }
    }

    private func verifyLifecycleStopAndFailureRollback() async {
        do {
            let provider = TestLifecycleProvider()
            let permissions = TestPermissionRequester()
            let fixture = makeFixture(provider: provider, permissionRequester: permissions)
            let fileHold = await fixture.coordinator.setModuleEnabled(
                .fileHold,
                enabled: true,
                permissionPolicy: .requestIfNeeded
            )
            check(fileHold.outcome == .applied, "File Hold enable applies without generic permission")
            check(await permissions.requestCount == 0, "File Hold enable does not pre-request file permission")
            _ = await fixture.coordinator.setModuleEnabled(.fileHold, enabled: false)
            let enabled = await fixture.coordinator.setModuleEnabled(
                .calendar,
                enabled: true,
                permissionPolicy: .requestIfNeeded
            )
            check(enabled.outcome == .applied, "module enable applies")
            check(await permissions.requestCount == 1, "Calendar contextual enable requests only Calendar permission")
            let disabled = await fixture.coordinator.setModuleEnabled(.calendar, enabled: false)
            check(disabled.outcome == .applied, "disable applies")
            let appleMusic = await fixture.coordinator.setModuleEnabled(
                .appleMusic,
                enabled: true,
                permissionPolicy: .requestIfNeeded
            )
            check(appleMusic.outcome == .applied, "Apple Music contextual Automation enable applies")
            _ = await fixture.coordinator.setModuleEnabled(.appleMusic, enabled: false)
            let spotify = await fixture.coordinator.setModuleEnabled(
                .spotify,
                enabled: true,
                permissionPolicy: .requestIfNeeded
            )
            check(spotify.outcome == .applied, "Spotify contextual Automation enable applies")
            _ = await fixture.coordinator.setModuleEnabled(.spotify, enabled: false)
            check(await permissions.requestCount == 3, "Calendar and both public media adapters request only their contextual permission")
            check(await provider.stopCount == 4, "each disable awaits its provider stop")
            check(await fixture.coordinator.activeModules().isEmpty, "disable releases provider")
        }

        do {
            let provider = TestLifecycleProvider()
            await provider.failNextStart()
            let fixture = makeFixture(provider: provider)
            let result = await fixture.coordinator.setModuleEnabled(.battery, enabled: true)
            check(result.failure == .providerStartFailed, "start failure is reported")
            check(!(await fixture.repository.current().modules.battery), "start failure leaves setting disabled")
            check(await provider.stopCount == 1, "partial start failure receives stop cleanup")
        }

        do {
            let storage = TestAtomicSettingsStorage()
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(storage: storage, provider: provider)
            storage.failNextReplacement()
            let result = await fixture.coordinator.setModuleEnabled(.timer, enabled: true)
            check(result.outcome == .rolledBack && result.failure == .persistenceFailed, "enable write failure rolls back")
            let counts = await provider.counts
            check(counts == ProviderCounts(starts: 1, stops: 1), "enable rollback stops started provider")
            check(await fixture.coordinator.activeModules().isEmpty, "enable rollback releases provider")
        }

        do {
            let storage = TestAtomicSettingsStorage()
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(storage: storage, provider: provider)
            _ = await fixture.coordinator.setModuleEnabled(.timer, enabled: true)
            storage.failNextReplacement()
            let result = await fixture.coordinator.setModuleEnabled(.timer, enabled: false)
            check(result.outcome == .rolledBack, "disable write failure rolls back")
            let counts = await provider.counts
            check(counts == ProviderCounts(starts: 2, stops: 1), "disable rollback restores provider")
            check(await fixture.repository.current().modules.timer, "disable rollback retains setting")
            check(await fixture.coordinator.activeModules() == [.timer], "disable rollback retains provider honestly")
        }
    }

    private func verifyResetAndTerminalStopAll() async {
        do {
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(provider: provider)
            _ = await fixture.coordinator.setModuleEnabled(.battery, enabled: true)
            _ = await fixture.coordinator.apply(.motion(.reduce))
            _ = await fixture.coordinator.apply(.crashAndDiagnosticSharingConsent(true))
            _ = await fixture.coordinator.setLaunchAtLoginEnabled(true)
            let reset = await fixture.coordinator.resetToSafeDefaults()
            check(reset.outcome == .applied && reset.settings == .safeDefaults, "reset restores complete safe defaults")
            check(await provider.stopCount == 1, "reset stops active provider")
            check(await fixture.coordinator.activeModules().isEmpty, "reset releases providers")
            check(!fixture.launchController.isEnabled, "reset disables login item seam")
        }

        do {
            let provider = BlockingStopProvider()
            let fixture = makeFixture(provider: provider)
            _ = await fixture.coordinator.setModuleEnabled(.battery, enabled: true)
            let completion = CompletionProbe()
            let stopTask = Task {
                let result = await fixture.coordinator.stopAll()
                await completion.markComplete()
                return result
            }
            check(await waitUntil { await provider.stopCount == 1 }, "stopAll reaches provider stop")
            check(!(await completion.isComplete), "stopAll does not return before provider is fully stopped")

            let lateCompletion = CompletionProbe()
            let lateOperation = Task {
                let result = await fixture.coordinator.setModuleEnabled(.timer, enabled: true)
                await lateCompletion.markComplete()
                return result
            }
            check(
                await waitUntil { await lateCompletion.isComplete },
                "operation arriving during idle-gate shutdown is rejected without waiting for stop"
            )
            let lateResult = await lateOperation.value
            check(lateResult.failure == .coordinatorShutDown, "operation during provider stop reports terminal shutdown")
            check(await fixture.factory.madeModules == [.battery], "operation during shutdown cannot construct or start work")

            await provider.releaseStop()
            let result = await stopTask.value
            check(result.stoppedModules == [.battery], "stopAll reports stopped modules")
            check(await completion.isComplete, "stopAll returns after stop completion")
            check(!(await provider.isRunning), "stopAll return guarantees zero retained provider work")
            check(await fixture.coordinator.activeModules().isEmpty, "stopAll releases ownership")
            check(await fixture.repository.current().modules.battery, "shutdown preserves enabled intent for next launch")
            let postShutdown = await fixture.coordinator.apply(.motion(.reduce))
            check(postShutdown.failure == .coordinatorShutDown, "completed shutdown remains terminal for settings changes")
            check(await fixture.repository.current().motion == .systemDefault, "post-shutdown settings change is not persisted")
        }

        do {
            let provider = BlockingStartProvider()
            let fixture = makeFixture(provider: provider)
            let active = Task {
                await fixture.coordinator.setModuleEnabled(.battery, enabled: true)
            }
            check(await waitUntil { await provider.startCount == 1 }, "queued-shutdown fixture holds an active operation")

            let queuedCompletion = CompletionCounter()
            let firstQueued = Task {
                let result = await fixture.coordinator.setModuleEnabled(.timer, enabled: true)
                await queuedCompletion.increment()
                return result
            }
            let secondQueued = Task {
                let result = await fixture.coordinator.setModuleEnabled(.timer, enabled: true)
                await queuedCompletion.increment()
                return result
            }
            check(
                await waitUntil { await queuedCompletion.count == 1 },
                "same-key completion proves one operation remains queued behind active work"
            )

            let stopTask = Task { await fixture.coordinator.stopAll() }
            check(
                await waitUntil { await queuedCompletion.count == 2 },
                "queued shutdown promptly evicts the remaining operation"
            )
            let firstResult = await firstQueued.value
            let secondResult = await secondQueued.value
            let queuedFailures = [firstResult.failure, secondResult.failure]
            check(queuedFailures.contains(.operationSuperseded), "same-key queued predecessor is superseded")
            check(queuedFailures.contains(.coordinatorShutDown), "shutdown rejects the later operation waiting behind active work")
            check(await fixture.factory.madeModules == [.battery], "shutdown-evicted queued work never reaches the factory")

            await provider.releaseStart()
            let activeResult = await active.value
            let stopResult = await stopTask.value
            check(activeResult.outcome == .applied, "operation active before shutdown may finish its transaction")
            check(stopResult.stoppedModules == [.battery], "queued shutdown stops provider retained by prior active operation")
            check(await provider.stopCount == 1, "queued shutdown performs one awaited provider stop")
            check(await fixture.coordinator.activeModules().isEmpty, "queued shutdown leaves no retained provider")
        }

        do {
            let provider = BlockingStopProvider()
            let fixture = makeFixture(provider: provider)
            _ = await fixture.coordinator.setModuleEnabled(.battery, enabled: true)
            let completion = CompletionProbe()
            let stopTask = Task {
                let result = await fixture.coordinator.stopAll()
                await completion.markComplete()
                return result
            }
            check(await waitUntil { await provider.stopCount == 1 }, "cancellation fixture reaches provider stop")
            stopTask.cancel()
            for _ in 0..<50 { await Task.yield() }
            check(!(await completion.isComplete), "caller cancellation cannot make stopAll return before provider stop")
            check(await provider.isRunning, "caller cancellation does not abandon running provider work")

            await provider.releaseStop()
            let result = await stopTask.value
            check(result.stoppedModules == [.battery], "cancelled stopAll caller still receives completed shutdown result")
            check(await completion.isComplete, "cancelled stopAll completes only after shutdown finishes")
            check(!(await provider.isRunning), "cancellation-insensitive shutdown reaches zero provider work")
            let repeated = await fixture.coordinator.stopAll()
            check(repeated == result, "repeated stopAll observes the same terminal result")
        }

        do {
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(provider: provider)
            fixture.launchController.capability = .unavailable
            _ = await fixture.coordinator.apply(.motion(.reduce))
            let reset = await fixture.coordinator.resetToSafeDefaults()
            check(reset.outcome == .applied, "reset remains useful when login-item capability is unavailable and off")
            check(await fixture.repository.current() == .safeDefaults, "unavailable login seam does not block safe reset")
        }
    }

    private func verifyLaunchAtLoginSeam() async {
        do {
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(provider: provider)
            fixture.launchController.enableState = .requiresApproval
            let result = await fixture.coordinator.setLaunchAtLoginEnabled(true)
            check(result.outcome == .applied, "requires approval preserves explicit request")
            check(result.launchAtLogin?.registrationState == .requiresApproval, "approval state is surfaced")
            check(await fixture.repository.current().launchAtLogin, "launch request is persisted")
        }

        do {
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(provider: provider)
            fixture.launchController.failNextChange = true
            let result = await fixture.coordinator.setLaunchAtLoginEnabled(true)
            check(result.failure == .launchAtLoginFailed, "login item failure is surfaced")
            check(!(await fixture.repository.current().launchAtLogin), "failed login registration is not persisted")
        }

        do {
            let storage = TestAtomicSettingsStorage()
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(storage: storage, provider: provider)
            storage.failNextReplacement()
            let result = await fixture.coordinator.setLaunchAtLoginEnabled(true)
            check(result.outcome == .rolledBack, "login item rolls back on persistence failure")
            check(fixture.launchController.changeRequests == [true, false], "login seam receives compensating rollback")
        }

        let systemSnapshot = SystemLaunchAtLoginController().snapshot()
        check([.available, .unavailable].contains(systemSnapshot.capability), "SMAppService adapter reports bounded capability")
    }

    private func verifyDisplayScopeBoundsAndUIOrdering() async {
        do {
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(provider: provider)
            let choices = [
                DisplayChoice(
                    identity: DisplayIdentity(rawValue: 10),
                    name: "Built-in\u{0000} display " + String(repeating: "x", count: 500)
                ),
                DisplayChoice(identity: DisplayIdentity(rawValue: 10), name: "Duplicate"),
            ] + (11..<400).map {
                DisplayChoice(identity: DisplayIdentity(rawValue: UInt32($0)), name: "Display \($0)")
            }
            let model = TrustSettingsViewModel(
                coordinator: fixture.coordinator,
                diagnosticsExporter: makeDiagnosticsExporter(events: fixture.events),
                displayChoices: choices
            )
            await model.load()
            check(model.displayChoices.count == DisplayChoiceLimits.maximumChoices, "display choices are count bounded")
            check(Set(model.displayChoices.map(\.identity)).count == model.displayChoices.count, "display choices deduplicate IDs for ForEach")
            check(
                model.displayChoices.allSatisfy {
                    $0.name.utf8.count <= DisplayChoiceLimits.maximumNameBytes
                        && !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                },
                "display names are VoiceOver-safe and byte bounded"
            )

            await model.setUseAllAvailableDisplays(false)
            let customIDs = model.settings.displays.enabledDisplayIDs
            check(customIDs?.count == DisplayChoiceLimits.maximumChoices, "all-to-custom initializes bounded current choices")
            await model.setDisplayEnabled(DisplayIdentity(rawValue: 11), enabled: false)
            check(!(model.settings.displays.enabledDisplayIDs?.contains(11) ?? true), "custom mode enables per-display changes")
            await model.setUseAllAvailableDisplays(true)
            check(model.settings.displays.enabledDisplayIDs == nil, "custom-to-all restores automatic display scope")
        }

        do {
            let provider = TestLifecycleProvider()
            let fixture = makeFixture(provider: provider)
            let model = TrustSettingsViewModel(
                coordinator: fixture.coordinator,
                diagnosticsExporter: makeDiagnosticsExporter(events: fixture.events),
                displayChoices: []
            )
            await model.load()
            await model.setUseAllAvailableDisplays(false)
            check(model.settings.displays.enabledDisplayIDs == [], "empty display list can enter explicit custom mode")
            await model.setUseAllAvailableDisplays(true)
            check(model.settings.displays.enabledDisplayIDs == nil, "empty display custom mode can return to all")
        }

        do {
            let coordinator = OutOfOrderSettingsCoordinator()
            let events = InMemoryDiagnosticEventBuffer(clock: FixedClock())
            let model = TrustSettingsViewModel(
                coordinator: coordinator,
                diagnosticsExporter: makeDiagnosticsExporter(events: events)
            )
            let older = Task { await model.setMotion(.reduce) }
            check(await waitUntil { await coordinator.motionRequestIsWaiting }, "out-of-order fixture blocks older result")
            let newer = Task { await model.setFullscreen(.remainAvailable) }
            _ = await newer.value
            check(model.settings.fullscreenBehavior == .remainAvailable, "newer UI result applies first")
            await coordinator.releaseMotionRequest()
            _ = await older.value
            check(model.settings.fullscreenBehavior == .remainAvailable, "older completion cannot overwrite newer UI state")
            check(model.settings.motion == .systemDefault, "stale older snapshot is sequence-gated")
        }
    }

    private func verifyDiagnosticsSchemaRedactionAndBounds() async {
        let events = InMemoryDiagnosticEventBuffer(clock: FixedClock())
        for index in 0..<200 {
            await events.record(
                severity: index.isMultiple(of: 2) ? .info : .warning,
                subsystem: .lifecycle,
                code: .moduleEnabled,
                module: .timer
            )
        }
        check(
            await events.recentEvents(limit: Int.max).count == DiagnosticsLimits.maximumExportedEvents,
            "in-memory event read is caller-bound"
        )

        var settings = EryloSettings.safeDefaults
        settings.displays = DisplayPreferences(
            enabledDisplayIDs: [123_456_789, 987_654_321],
            selectedDisplayID: 987_654_321
        )
        settings.modules.timer = true
        let duplicateHealth = (0..<1_000).map { index in
            ProviderHealthSnapshot(
                module: EryloModule.allCases[index % EryloModule.allCases.count],
                state: .running
            )
        }
        let writer = CapturingDiagnosticsWriter()
        let exporter = DiagnosticsExporter(
            collector: PrivacyPreservingDiagnosticsCollector(
                metadata: MaliciousMetadataProvider(),
                eventSource: events,
                clock: FixedClock()
            ),
            writer: writer
        )
        do {
            let count = try await exporter.export(
                settings: settings,
                providerHealth: duplicateHealth,
                to: URL(fileURLWithPath: "/explicit/Erylo-Diagnostics.json")
            )
            check(count <= DiagnosticsLimits.maximumJSONBytes, "diagnostics JSON is byte bounded")
        } catch {
            check(false, "bounded diagnostics export produced unexpected error")
        }

        guard let data = await writer.lastData,
              let text = String(data: data, encoding: .utf8) else {
            check(false, "diagnostics writer received JSON")
            return
        }
        check(await writer.writeCount == 1, "explicit export writes exactly once")
        check(text.contains("\"schemaVersion\" : 1"), "diagnostics schema version is explicit")
        check(text.contains("\"schemaVersion\" : 2"), "settings schema version is included")
        check(!text.contains("123456789") && !text.contains("987654321"), "display identifiers are excluded")
        let forbidden = [
            "/Users/alice", "vacation.mov", "meeting-title", "attendee@example.com",
            "https://private.example", "socket-payload", "secret-token", "rawURL",
            "deviceIdentifier", "fileName", "mediaTitle", "meetingTitle", "payload",
        ]
        for value in forbidden {
            check(!text.localizedCaseInsensitiveContains(value), "diagnostics exclude forbidden value or field: \(value)")
        }
        check(text.contains("redacted"), "unsafe metadata is redacted")

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let report = try decoder.decode(DiagnosticsReport.self, from: data)
            check(report.schemaVersion == DiagnosticsReport.currentSchemaVersion, "report decodes against stable schema")
            check(report.recentEvents.count == DiagnosticsLimits.maximumExportedEvents, "event export is bounded")
            check(report.providerHealth.count == EryloModule.allCases.count, "provider health is deduplicated by module")
            check(Set(report.providerHealth.map(\.module)).count == report.providerHealth.count, "provider health has no duplicates")
            check(report.settings.customDisplayCount == 2, "non-identifying display count is retained")
            check(report.settings.displaySelection == .explicit, "selection mode is retained without ID")
        } catch {
            check(false, "diagnostics failed stable-schema decode")
        }
    }

    private func verifyMaliciousCollectorReboundingAndExportFailures() async {
        do {
            let writer = CapturingDiagnosticsWriter()
            let exporter = DiagnosticsExporter(
                collector: MaliciousDiagnosticsCollector(),
                writer: writer
            )
            _ = try await exporter.export(
                settings: .safeDefaults,
                providerHealth: [],
                to: URL(fileURLWithPath: "/explicit/rebounded.json")
            )
            guard let data = await writer.lastData else {
                check(false, "malicious collector output was written after rebounding")
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let report = try decoder.decode(DiagnosticsReport.self, from: data)
            check(report.recentEvents.count == DiagnosticsLimits.maximumExportedEvents, "exporter re-bounds malicious event output")
            check(report.providerHealth.count == 1, "exporter deduplicates malicious provider output")
            check(report.app.version == "redacted" && report.platform.architecture == "unknown", "exporter re-sanitizes injected metadata")
        } catch {
            check(false, "malicious collector rebounding produced unexpected error")
        }

        let events = InMemoryDiagnosticEventBuffer(clock: FixedClock())
        let collector = PrivacyPreservingDiagnosticsCollector(
            metadata: SafeMetadataProvider(),
            eventSource: events,
            clock: FixedClock()
        )
        do {
            _ = try await DiagnosticsExporter(
                collector: collector,
                writer: FailingDiagnosticsWriter()
            ).export(
                settings: .safeDefaults,
                providerHealth: [],
                to: URL(fileURLWithPath: "/explicit/failure.json")
            )
            check(false, "writer failure throws")
        } catch let error {
            check(error == .writeFailed, "writer failure maps to stable error")
        }

        do {
            _ = try await DiagnosticsExporter(
                collector: collector,
                writer: CapturingDiagnosticsWriter()
            ).export(
                settings: .safeDefaults,
                providerHealth: [],
                to: URL(string: "https://example.com/automatic-upload")!
            )
            check(false, "network destination is rejected")
        } catch let error {
            check(error == .invalidDestination, "diagnostics reject network destinations")
        }

        do {
            _ = try await DiagnosticsExporter(
                collector: FailingDiagnosticsCollector(),
                writer: CapturingDiagnosticsWriter()
            ).export(
                settings: .safeDefaults,
                providerHealth: [],
                to: URL(fileURLWithPath: "/explicit/collection.json")
            )
            check(false, "collector failure throws")
        } catch let error {
            check(error == .collectionFailed, "collector failure maps to stable error")
        }
    }

    private func verifyAccessibilityCopy() {
        let labels = TrustAccessibilityCopy.fixedLabels
            + EryloModule.allCases.map(TrustAccessibilityCopy.moduleLabel)
        let hints = [
            TrustAccessibilityCopy.productPromiseHint,
            TrustAccessibilityCopy.onboardingHint,
            TrustAccessibilityCopy.launchAtLoginHint,
            TrustAccessibilityCopy.diagnosticsConsentHint,
            TrustAccessibilityCopy.diagnosticsExportHint,
            TrustAccessibilityCopy.resetHint,
            TrustAccessibilityCopy.unavailableMotionHint,
            TrustAccessibilityCopy.unavailableFullscreenHint,
        ] + EryloModule.allCases.map(TrustAccessibilityCopy.moduleHint)
            + EryloModule.allCases.map(TrustAccessibilityCopy.unavailableModuleHint)
        check(labels.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "accessibility labels are non-empty")
        check(Set(labels).count == labels.count, "accessibility labels are distinct")
        check(hints.allSatisfy { $0.count >= 12 }, "accessibility hints explain controls")
        check(EryloModule.allCases.allSatisfy { TrustAccessibilityCopy.moduleLabel($0).hasPrefix("Enable ") }, "module labels expose action")
        check(
            EryloModule.allCases.allSatisfy {
                TrustAccessibilityCopy.unavailableModuleLabel($0).hasSuffix(" unavailable")
            },
            "unavailable module labels do not claim an enabled action"
        )
    }

    private func makeFixture(
        storage: TestAtomicSettingsStorage = TestAtomicSettingsStorage(),
        provider: any ModuleLifecycleProvider,
        permissionRequester: (any ModulePermissionRequesting)? = nil
    ) -> Fixture {
        let repository = SettingsRepository(storage: storage)
        let factory = TestProviderFactory(provider: provider)
        let permissions = permissionRequester ?? TestPermissionRequester()
        let launchController = TestLaunchAtLoginController()
        let events = InMemoryDiagnosticEventBuffer(clock: FixedClock())
        let coordinator = TrustSettingsCoordinator(
            repository: repository,
            providerFactory: factory,
            permissionRequester: permissions,
            launchAtLoginController: launchController,
            events: events
        )
        return Fixture(
            repository: repository,
            factory: factory,
            launchController: launchController,
            events: events,
            coordinator: coordinator
        )
    }

    private func makeDiagnosticsExporter(
        events: InMemoryDiagnosticEventBuffer
    ) -> DiagnosticsExporter {
        DiagnosticsExporter(
            collector: PrivacyPreservingDiagnosticsCollector(
                metadata: SafeMetadataProvider(),
                eventSource: events,
                clock: FixedClock()
            ),
            writer: CapturingDiagnosticsWriter()
        )
    }

    private func display(_ identity: UInt32, isMain: Bool = false) -> DisplaySnapshot {
        DisplaySnapshot(
            identity: DisplayIdentity(rawValue: identity),
            geometry: DisplayGeometry(
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
                backingScaleFactor: 2,
                topEdgeOcclusion: nil
            ),
            isMain: isMain
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func check(_ condition: Bool, _ name: String) {
        checkCount += 1
        if !condition { failures.append(name) }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Trust harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        fputs("Trust harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private struct Fixture {
    let repository: SettingsRepository
    let factory: TestProviderFactory
    let launchController: TestLaunchAtLoginController
    let events: InMemoryDiagnosticEventBuffer
    let coordinator: TrustSettingsCoordinator
}

private final class TestAtomicSettingsStorage: AtomicSettingsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var failNext = false
    private var attempts = 0
    private var successes = 0

    init(initialData: Data? = nil) { data = initialData }
    var currentData: Data? { lock.withLock { data } }
    var replacementAttemptCount: Int { lock.withLock { attempts } }
    var successfulReplacementCount: Int { lock.withLock { successes } }
    func failNextReplacement() { lock.withLock { failNext = true } }
    func data(forKey key: String) throws -> Data? { lock.withLock { data } }
    func replace(_ data: Data, forKey key: String) throws {
        try lock.withLock {
            attempts += 1
            if failNext {
                failNext = false
                throw TestFailure.requested
            }
            self.data = data
            successes += 1
        }
    }
}

private struct ProviderCounts: Equatable {
    let starts: Int
    let stops: Int
}

private actor TestLifecycleProvider: ModuleLifecycleProvider {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var shouldFailStart = false
    var counts: ProviderCounts { ProviderCounts(starts: startCount, stops: stopCount) }
    func failNextStart() { shouldFailStart = true }
    func start() async throws {
        startCount += 1
        if shouldFailStart {
            shouldFailStart = false
            throw TestFailure.requested
        }
    }
    func stop() async { stopCount += 1 }
}

private actor BlockingStartProvider: ModuleLifecycleProvider {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func start() async throws {
        startCount += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func stop() async { stopCount += 1 }
    func releaseStart() {
        continuation?.resume()
        continuation = nil
    }
}

private actor BlockingStopProvider: ModuleLifecycleProvider {
    private(set) var stopCount = 0
    private(set) var isRunning = false
    private var continuation: CheckedContinuation<Void, Never>?
    func start() async throws { isRunning = true }
    func stop() async {
        stopCount += 1
        await withCheckedContinuation { continuation = $0 }
        isRunning = false
    }
    func releaseStop() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TestProviderFactory: ModuleProviderFactory {
    private let provider: any ModuleLifecycleProvider
    private(set) var madeModules: [EryloModule] = []
    var makeCount: Int { madeModules.count }
    init(provider: any ModuleLifecycleProvider) { self.provider = provider }
    func makeProvider(for module: EryloModule) async throws -> any ModuleLifecycleProvider {
        madeModules.append(module)
        return provider
    }
}

private actor TestPermissionRequester: ModulePermissionRequesting {
    private(set) var requestCount = 0
    func requestPermission(
        _ requirement: ModulePermissionRequirement,
        for module: EryloModule
    ) async throws {
        requestCount += 1
    }
}

private actor BlockingPermissionRequester: ModulePermissionRequesting {
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func requestPermission(
        _ requirement: ModulePermissionRequirement,
        for module: EryloModule
    ) async throws {
        requestCount += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func releaseRequest() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CompletionProbe {
    private(set) var isComplete = false
    func markComplete() { isComplete = true }
}

private actor CompletionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor OutOfOrderSettingsCoordinator: TrustSettingsCoordinating {
    private(set) var motionRequestIsWaiting = false
    private var motionContinuation: CheckedContinuation<Void, Never>?

    func currentSettings() async -> EryloSettings { .safeDefaults }

    func launchAtLoginSnapshot() async -> LaunchAtLoginSnapshot { .unavailable }

    func setModuleEnabled(
        _ module: EryloModule,
        enabled: Bool,
        permissionPolicy: PermissionRequestPolicy
    ) async -> TrustSettingsUpdateResult {
        TrustSettingsUpdateResult(settings: .safeDefaults, outcome: .noChange)
    }

    func apply(_ change: TrustSettingsChange) async -> TrustSettingsUpdateResult {
        switch change {
        case .motion:
            motionRequestIsWaiting = true
            await withCheckedContinuation { motionContinuation = $0 }
            var stale = EryloSettings.safeDefaults
            stale.motion = .reduce
            return TrustSettingsUpdateResult(settings: stale, outcome: .applied)
        case .fullscreen:
            var newer = EryloSettings.safeDefaults
            newer.fullscreenBehavior = .remainAvailable
            return TrustSettingsUpdateResult(settings: newer, outcome: .applied)
        case .displays, .crashAndDiagnosticSharingConsent, .onboardingCompleted:
            return TrustSettingsUpdateResult(settings: .safeDefaults, outcome: .applied)
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async -> TrustSettingsUpdateResult {
        TrustSettingsUpdateResult(settings: .safeDefaults, outcome: .noChange)
    }

    func resetToSafeDefaults() async -> TrustSettingsUpdateResult {
        TrustSettingsUpdateResult(settings: .safeDefaults, outcome: .applied)
    }

    func diagnosticsContext() async -> DiagnosticsContext {
        DiagnosticsContext(settings: .safeDefaults, providerHealth: [])
    }

    func releaseMotionRequest() {
        motionContinuation?.resume()
        motionContinuation = nil
        motionRequestIsWaiting = false
    }
}

@MainActor
private final class TestLaunchAtLoginController: LaunchAtLoginControlling {
    var capability: LaunchAtLoginCapability = .available
    var enableState: LaunchAtLoginRegistrationState = .enabled
    var failNextChange = false
    private(set) var isEnabled = false
    private(set) var changeRequests: [Bool] = []
    func snapshot() -> LaunchAtLoginSnapshot {
        guard capability == .available else { return .unavailable }
        return LaunchAtLoginSnapshot(
            capability: .available,
            registrationState: isEnabled ? enableState : .disabled
        )
    }
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginSnapshot {
        changeRequests.append(enabled)
        guard capability == .available else { return .unavailable }
        if failNextChange {
            failNextChange = false
            return LaunchAtLoginSnapshot(
                capability: .available,
                registrationState: isEnabled ? enableState : .disabled,
                failure: enabled ? .registrationFailed : .unregistrationFailed
            )
        }
        isEnabled = enabled
        return snapshot()
    }
}

@MainActor
private final class CancelDestinationChooser: DiagnosticsDestinationChoosing {
    func chooseDestination() async -> URL? { nil }
}

private struct FixedClock: DiagnosticClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private struct SafeMetadataProvider: DiagnosticMetadataProviding {
    func appSnapshot() -> DiagnosticAppSnapshot { DiagnosticAppSnapshot(version: "1.0.0", build: "100") }
    func platformSnapshot() -> DiagnosticPlatformSnapshot {
        DiagnosticPlatformSnapshot(operatingSystem: "macOS", version: "14.0.0", architecture: "arm64")
    }
}

private struct MaliciousMetadataProvider: DiagnosticMetadataProviding {
    func appSnapshot() -> DiagnosticAppSnapshot {
        DiagnosticAppSnapshot(version: "/Users/alice/vacation.mov", build: "https://private.example/secret-token")
    }
    func platformSnapshot() -> DiagnosticPlatformSnapshot {
        DiagnosticPlatformSnapshot(
            operatingSystem: "attendee@example.com meeting-title",
            version: "socket-payload",
            architecture: "deviceIdentifier"
        )
    }
}

private actor CapturingDiagnosticsWriter: DiagnosticsWriting {
    private(set) var writeCount = 0
    private(set) var lastData: Data?
    func write(_ data: Data, to destination: URL) async throws {
        writeCount += 1
        lastData = data
    }
}

private struct MaliciousDiagnosticsCollector: DiagnosticsCollecting {
    func collect(
        settings: EryloSettings,
        providerHealth: [ProviderHealthSnapshot]
    ) async throws -> DiagnosticsReport {
        let event = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            severity: .info,
            subsystem: .diagnostics,
            code: .settingsLoaded
        )
        let health = ProviderHealthSnapshot(module: .timer, state: .running)
        return DiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            app: DiagnosticAppSnapshot(version: "/Users/alice/file.mov", build: "secret-token"),
            platform: DiagnosticPlatformSnapshot(operatingSystem: "private", version: "socket-payload", architecture: "device-id"),
            settings: DiagnosticSettingsSnapshot(settings: settings),
            providerHealth: Array(repeating: health, count: 10_000),
            recentEvents: Array(repeating: event, count: 10_000)
        )
    }
}

private struct FailingDiagnosticsWriter: DiagnosticsWriting {
    func write(_ data: Data, to destination: URL) async throws { throw TestFailure.requested }
}

private struct FailingDiagnosticsCollector: DiagnosticsCollecting {
    func collect(
        settings: EryloSettings,
        providerHealth: [ProviderHealthSnapshot]
    ) async throws -> DiagnosticsReport {
        throw TestFailure.requested
    }
}

private enum TestFailure: Error {
    case requested
}
