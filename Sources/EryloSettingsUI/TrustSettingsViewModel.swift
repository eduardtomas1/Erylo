import AppKit
import EryloCore
import EryloTrust
import Foundation
import Observation
import UniformTypeIdentifiers

package struct TrustSettingsSuccessfulChange: Sendable {
    package enum Kind: Sendable {
        case persistedSettings
        case module(EryloModule, enabled: Bool)
        case resetToSafeDefaults
    }

    package let kind: Kind
    package let settings: EryloSettings
}

public enum DisplayChoiceLimits {
    public static let maximumChoices = SettingsLimits.maximumEnabledDisplayIDs
    public static let maximumNameBytes = 80
    public static let maximumInjectedChoicesScanned = 256
}

public struct DisplayChoice: Identifiable, Equatable, Sendable {
    public let identity: DisplayIdentity
    public let name: String

    public var id: DisplayIdentity { identity }

    public init(identity: DisplayIdentity, name: String) {
        self.identity = identity
        self.name = Self.safeName(name)
    }

    private static func safeName(_ value: String) -> String {
        var result = ""
        var byteCount = 0
        for scalar in value.unicodeScalars.prefix(DisplayChoiceLimits.maximumNameBytes * 2) {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            let fragment = String(scalar)
            let fragmentBytes = fragment.utf8.count
            guard byteCount + fragmentBytes <= DisplayChoiceLimits.maximumNameBytes else { break }
            result.unicodeScalars.append(scalar)
            byteCount += fragmentBytes
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed display" : trimmed
    }
}

@MainActor
public protocol DiagnosticsDestinationChoosing: AnyObject {
    func chooseDestination() async -> URL?
}

@MainActor
public final class SystemDiagnosticsDestinationChooser: DiagnosticsDestinationChoosing {
    public init() {}

    public func chooseDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Erylo Diagnostics"
        panel.nameFieldStringValue = "Erylo-Diagnostics.json"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
@Observable
public final class TrustSettingsViewModel {
    public private(set) var settings: EryloSettings
    public private(set) var launchAtLogin: LaunchAtLoginSnapshot
    public private(set) var statusMessage: String?
    package private(set) var moduleFeedback: [EryloModule: String] = [:]
    public private(set) var isWorking = false
    public private(set) var displayChoices: [DisplayChoice]
    public let availableModules: Set<EryloModule>
    public let supportsMotionPreference: Bool
    public let supportsFullscreenPreference: Bool

    @ObservationIgnored
    private let coordinator: any TrustSettingsCoordinating

    @ObservationIgnored
    private let diagnosticsExporter: DiagnosticsExporter

    @ObservationIgnored
    private let settingsDidChange: @MainActor (EryloSettings) -> Void

    @ObservationIgnored
    private var successfulSettingsChangeHandler: @MainActor (TrustSettingsSuccessfulChange) -> Void = { _ in }

    @ObservationIgnored
    private var startupFailureFeedbackModules: Set<EryloModule> = []

    @ObservationIgnored
    private var operationCount = 0

    @ObservationIgnored
    private var hasLoaded = false

    @ObservationIgnored
    private var nextOperationSequence: UInt64 = 0

    @ObservationIgnored
    private var latestAppliedSequence: UInt64 = 0

    @ObservationIgnored
    private var modulesWithFailureFeedback: Set<EryloModule> = []

    public init(
        coordinator: any TrustSettingsCoordinating,
        diagnosticsExporter: DiagnosticsExporter,
        initialSettings: EryloSettings = .safeDefaults,
        displayChoices: [DisplayChoice] = [],
        availableModules: Set<EryloModule> = Set(EryloModule.allCases),
        supportsMotionPreference: Bool = true,
        supportsFullscreenPreference: Bool = true,
        settingsDidChange: @escaping @MainActor (EryloSettings) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.diagnosticsExporter = diagnosticsExporter
        self.availableModules = availableModules
        self.supportsMotionPreference = supportsMotionPreference
        self.supportsFullscreenPreference = supportsFullscreenPreference
        self.settingsDidChange = settingsDidChange
        settings = initialSettings
        launchAtLogin = .unavailable
        self.displayChoices = Self.normalizedDisplayChoices(displayChoices)
    }

    package func setSuccessfulSettingsChangeHandler(
        _ handler: @escaping @MainActor (TrustSettingsSuccessfulChange) -> Void
    ) {
        successfulSettingsChangeHandler = handler
    }

    /// Browsing settings performs reads only. It does not construct providers, start work, or
    /// request a permission.
    public func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        let sequence = allocateSequence()
        let loadedSettings = await coordinator.currentSettings()
        let loadedLaunchAtLogin = await coordinator.launchAtLoginSnapshot()
        guard accept(sequence) else { return }
        settings = loadedSettings
        launchAtLogin = loadedLaunchAtLogin
    }

    public func setModuleEnabled(_ module: EryloModule, enabled: Bool) async {
        guard availableModules.contains(module) else {
            let message = "This utility is not connected in this build. No work was started."
            moduleFeedback[module] = message
            modulesWithFailureFeedback.insert(module)
            statusMessage = message
            return
        }
        let sequence = beginOperation()
        let result = await coordinator.setModuleEnabled(
            module,
            enabled: enabled,
            permissionPolicy: module.permissionRequirement == nil ? .doNotRequest : .requestIfNeeded
        )
        if apply(
            result,
            sequence: sequence,
            successfulChangeKind: .module(module, enabled: enabled)
        ) {
            updateModuleFeedback(
                for: module,
                requestedEnabled: enabled,
                result: result
            )
            if result.failure != nil {
                // Module failures already have more specific row-local copy.
                statusMessage = nil
            }
        }
        endOperation()
    }

    public func isModuleAvailable(_ module: EryloModule) -> Bool {
        availableModules.contains(module)
    }

    package func moduleFeedbackIsFailure(for module: EryloModule) -> Bool {
        modulesWithFailureFeedback.contains(module)
    }

    /// Package-only startup reconciliation after the application restores enabled
    /// providers. This mutates view state only and performs no provider work.
    package func synchronize(
        settings: EryloSettings,
        statusMessage: String? = nil,
        startupFailureModules: Set<EryloModule>? = nil
    ) {
        self.settings = settings
        self.statusMessage = statusMessage
        guard let startupFailureModules else { return }

        for module in startupFailureFeedbackModules.subtracting(startupFailureModules) {
            moduleFeedback.removeValue(forKey: module)
            modulesWithFailureFeedback.remove(module)
        }
        for module in startupFailureModules {
            moduleFeedback[module] = Self.moduleFailureMessage(
                for: module,
                failure: .providerStartFailed
            )
            modulesWithFailureFeedback.insert(module)
        }
        startupFailureFeedbackModules = startupFailureModules
    }

    public func setDisplaySurfaceEnabled(_ enabled: Bool) async {
        var displays = settings.displays
        displays.isEnabled = enabled
        await applySettingChange(.displays(displays))
    }

    public func setDisplayEnabled(_ identity: DisplayIdentity, enabled: Bool) async {
        var displays = settings.displays
        var enabledIDs = displays.enabledDisplayIDs
            ?? displayChoices.map { $0.identity.rawValue }
        if enabled {
            enabledIDs.append(identity.rawValue)
        } else {
            enabledIDs.removeAll { $0 == identity.rawValue }
        }
        displays = DisplayPreferences(
            isEnabled: displays.isEnabled,
            enabledDisplayIDs: enabledIDs,
            selectedDisplayID: displays.selectedDisplayID
        )
        if displays.selectedDisplayID == identity.rawValue, !enabled {
            displays.selectedDisplayID = nil
        }
        await applySettingChange(.displays(displays))
    }

    public func setUseAllAvailableDisplays(_ useAll: Bool) async {
        var displays = settings.displays
        displays.enabledDisplayIDs = useAll
            ? nil
            : displayChoices.map { $0.identity.rawValue }
        await applySettingChange(.displays(displays))
    }

    public func useAllAvailableDisplays() async {
        await setUseAllAvailableDisplays(true)
    }

    public func updateDisplayChoices(_ choices: [DisplayChoice]) {
        displayChoices = Self.normalizedDisplayChoices(choices)
    }

    public func selectDisplay(_ identity: DisplayIdentity?) async {
        var displays = settings.displays
        displays.selectedDisplayID = identity?.rawValue
        await applySettingChange(.displays(displays))
    }

    public func setMotion(_ motion: MotionPreference) async {
        guard supportsMotionPreference else {
            statusMessage = "Motion preferences are not connected to the surface in this build."
            return
        }
        await applySettingChange(.motion(motion))
    }

    public func setFullscreen(_ fullscreen: FullscreenBehavior) async {
        guard supportsFullscreenPreference else {
            statusMessage = "Fullscreen preferences are not connected to the surface in this build."
            return
        }
        await applySettingChange(.fullscreen(fullscreen))
    }

    public func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        let sequence = beginOperation()
        let result = await coordinator.setLaunchAtLoginEnabled(enabled)
        apply(result, sequence: sequence, successfulChangeKind: .persistedSettings)
        endOperation()
    }

    public func setCrashAndDiagnosticSharingConsent(_ consent: Bool) async {
        await applySettingChange(.crashAndDiagnosticSharingConsent(consent))
    }

    public func completeOnboarding() async {
        await applySettingChange(.onboardingCompleted(true))
    }

    public func resetToSafeDefaults() async {
        let sequence = beginOperation()
        let result = await coordinator.resetToSafeDefaults()
        let didApply = apply(result, sequence: sequence, successfulChangeKind: .resetToSafeDefaults)
        if didApply, result.failure == nil {
            moduleFeedback.removeAll(keepingCapacity: true)
            modulesWithFailureFeedback.removeAll(keepingCapacity: true)
            if result.outcome == .applied {
                statusMessage = "Safe defaults restored. All activity modules are off."
            }
        }
        endOperation()
    }

    public func exportDiagnostics(to destination: URL) async {
        let sequence = beginOperation()
        let context = await coordinator.diagnosticsContext()
        do {
            _ = try await diagnosticsExporter.export(
                settings: context.settings,
                providerHealth: context.providerHealth,
                to: destination
            )
            if accept(sequence) {
                statusMessage = "Diagnostics saved. Nothing was uploaded."
            }
        } catch {
            if accept(sequence) {
                statusMessage = "Diagnostics could not be saved. No data was uploaded."
            }
        }
        endOperation()
    }

    public func isDisplayEnabled(_ identity: DisplayIdentity) -> Bool {
        settings.displays.enabledDisplayIDs?.contains(identity.rawValue) ?? true
    }

    private func applySettingChange(_ change: TrustSettingsChange) async {
        applyLocally(change)
        let sequence = beginOperation()
        let result = await coordinator.apply(change)
        apply(result, sequence: sequence, successfulChangeKind: .persistedSettings)
        endOperation()
    }

    private func applyLocally(_ change: TrustSettingsChange) {
        switch change {
        case let .displays(displays):
            settings.displays = displays
        case let .motion(motion):
            settings.motion = motion
        case let .fullscreen(fullscreen):
            settings.fullscreenBehavior = fullscreen
        case let .crashAndDiagnosticSharingConsent(consent):
            settings.crashAndDiagnosticSharingConsent = consent
        case let .onboardingCompleted(completed):
            settings.onboardingCompleted = completed
        }
    }

    private func updateModuleFeedback(
        for module: EryloModule,
        requestedEnabled: Bool,
        result: TrustSettingsUpdateResult
    ) {
        if let failure = result.failure {
            moduleFeedback[module] = Self.moduleFailureMessage(
                for: module,
                failure: failure
            )
            modulesWithFailureFeedback.insert(module)
            return
        }

        if !requestedEnabled, startupFailureFeedbackModules.contains(module) {
            return
        }
        modulesWithFailureFeedback.remove(module)
        startupFailureFeedbackModules.remove(module)
        guard requestedEnabled, result.settings.modules[module] else {
            moduleFeedback.removeValue(forKey: module)
            return
        }
        moduleFeedback[module] = switch module {
        case .volume:
            "Volume is on — adjust it to see Erylo."
        case .battery:
            "Battery is on — its next change will appear in Erylo."
        case .fileHold, .appleMusic, .spotify, .timer, .calendar, .localIntegrations:
            "\(ModuleCopy.title(for: module)) is on."
        }
    }

    private static func moduleFailureMessage(
        for module: EryloModule,
        failure: TrustUpdateFailure
    ) -> String {
        let title = module == .volume ? "Volume" : ModuleCopy.title(for: module)
        return switch failure {
        case .permissionDenied:
            "Access was not granted. \(title) remains off."
        case .providerFactoryFailed, .providerStartFailed:
            "\(title) could not start and remains off."
        case .persistenceFailed:
            "\(title) could not be saved and was rolled back."
        case .rollbackFailed:
            "\(title) failed to start and cleanup needs attention. Check diagnostics."
        case .operationCancelled:
            "The cancelled \(title) change did not run."
        case .operationSuperseded:
            "A newer \(title) change replaced this one."
        case .queueCapacityExceeded:
            "Too many changes are pending. Please try \(title) again in a moment."
        case .coordinatorShutDown:
            "Erylo is shutting down. \(title) did not change."
        case .launchAtLoginFailed:
            "\(title) did not change."
        }
    }

    @discardableResult
    private func apply(
        _ result: TrustSettingsUpdateResult,
        sequence: UInt64,
        successfulChangeKind: TrustSettingsSuccessfulChange.Kind?
    ) -> Bool {
        guard accept(sequence) else { return false }
        settings = result.settings
        settingsDidChange(settings)
        if let launchAtLogin = result.launchAtLogin {
            self.launchAtLogin = launchAtLogin
        }
        switch result.failure {
        case .none:
            statusMessage = nil
        case .permissionDenied:
            statusMessage = "Access was not granted. The module remains off."
        case .providerFactoryFailed, .providerStartFailed:
            statusMessage = "The module could not start and remains off."
        case .persistenceFailed:
            statusMessage = "The change could not be saved and was rolled back."
        case .rollbackFailed:
            statusMessage = "The change failed and cleanup needs attention. Check diagnostics."
        case .launchAtLoginFailed:
            statusMessage = "macOS could not change the Login Item. The saved preference was not changed."
        case .operationCancelled:
            statusMessage = "The cancelled change did not run."
        case .operationSuperseded:
            statusMessage = "A newer change replaced this one."
        case .queueCapacityExceeded:
            statusMessage = "Too many changes are pending. Please try again in a moment."
        case .coordinatorShutDown:
            statusMessage = "Erylo is shutting down. No further changes can run."
        }
        if result.outcome == .applied,
           result.failure == nil,
           let successfulChangeKind {
            successfulSettingsChangeHandler(
                TrustSettingsSuccessfulChange(
                    kind: successfulChangeKind,
                    settings: settings
                )
            )
        }
        return true
    }

    private func beginOperation() -> UInt64 {
        operationCount += 1
        isWorking = true
        return allocateSequence()
    }

    private func endOperation() {
        operationCount = max(operationCount - 1, 0)
        isWorking = operationCount > 0
    }

    private func allocateSequence() -> UInt64 {
        precondition(nextOperationSequence < UInt64.max, "settings UI operation sequence exhausted")
        nextOperationSequence += 1
        return nextOperationSequence
    }

    private func accept(_ sequence: UInt64) -> Bool {
        guard sequence >= latestAppliedSequence else { return false }
        latestAppliedSequence = sequence
        return true
    }

    private static func normalizedDisplayChoices(_ choices: [DisplayChoice]) -> [DisplayChoice] {
        var seen: Set<DisplayIdentity> = []
        var result: [DisplayChoice] = []
        for choice in choices.prefix(DisplayChoiceLimits.maximumInjectedChoicesScanned)
            where seen.insert(choice.identity).inserted {
            result.append(DisplayChoice(identity: choice.identity, name: choice.name))
            if result.count == DisplayChoiceLimits.maximumChoices { break }
        }
        return result
    }
}
