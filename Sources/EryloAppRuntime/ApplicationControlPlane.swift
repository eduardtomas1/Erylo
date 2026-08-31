import AppKit
import EryloActivity
import EryloCore
import EryloSettingsUI
import EryloTrust
import EryloWindowing
import SwiftUI

package enum ApplicationControlCommand: Int, Equatable, Sendable {
    case toggleSurface
    case startFocusTimer15
    case startFocusTimer25
    case startFocusTimer50
    case cancelFocusTimer
    case showSettings
    case checkForUpdates
    case quit
}

package enum ApplicationMenuItemKind: Equatable, Sendable {
    case command(ApplicationControlCommand)
    case information
    case separator
}

package struct ApplicationMenuItemDescriptor: Equatable, Sendable {
    package let kind: ApplicationMenuItemKind
    package let title: String
    package let keyEquivalent: String
    package let accessibilityLabel: String?
    package let accessibilityHint: String?
    package let accessibilityIdentifier: String?
    package let isEnabled: Bool

    package init(
        kind: ApplicationMenuItemKind,
        title: String,
        keyEquivalent: String = "",
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        accessibilityIdentifier: String? = nil,
        isEnabled: Bool = true
    ) {
        self.kind = kind
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isEnabled = isEnabled
    }
}

package enum ApplicationReadinessState: Equatable, Sendable {
    case starting
    case setupRequired
    case ready
    case needsAttention
}

package struct ApplicationReadinessSnapshot: Equatable, Sendable {
    package static let maximumNotices = 3
    package static let starting = ApplicationReadinessSnapshot(state: .starting)

    package let state: ApplicationReadinessState
    package let notices: [String]

    package init(state: ApplicationReadinessState, notices: [String] = []) {
        self.state = state
        self.notices = Array(notices.prefix(Self.maximumNotices))
    }
}

package struct ApplicationRuntimeControlSnapshot: Equatable, Sendable {
    package static let starting = ApplicationRuntimeControlSnapshot(
        coreCommandsAreAdmitted: false,
        focusCommandsAreAdmitted: false,
        quitCommandIsAdmitted: false,
        canCheckForUpdates: false,
        focusTimer: .idle,
        surface: .temporarilyUnavailable
    )

    package let coreCommandsAreAdmitted: Bool
    package let focusCommandsAreAdmitted: Bool
    package let quitCommandIsAdmitted: Bool
    package let canCheckForUpdates: Bool
    package let focusTimer: ApplicationFocusTimerMenuContext
    package let surface: SelectedSurfaceState

    package init(
        coreCommandsAreAdmitted: Bool,
        focusCommandsAreAdmitted: Bool,
        quitCommandIsAdmitted: Bool,
        canCheckForUpdates: Bool,
        focusTimer: ApplicationFocusTimerMenuContext,
        surface: SelectedSurfaceState
    ) {
        self.coreCommandsAreAdmitted = coreCommandsAreAdmitted
        self.focusCommandsAreAdmitted = focusCommandsAreAdmitted
        self.quitCommandIsAdmitted = quitCommandIsAdmitted
        self.canCheckForUpdates = canCheckForUpdates
        self.focusTimer = focusTimer
        self.surface = surface
    }
}

package enum ApplicationFocusTimerMenuContext: Equatable, Sendable {
    case idle
    case active(remainingText: String)

    package var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

package enum ApplicationControlCopy {
    package static let statusItemLabel = "Erylo controls"
    package static let statusItemHint = "Opens Focus Timer controls, the Erylo surface, settings, updates, and quitting."
    package static let showSurface = "Show Erylo"
    package static let hideSurface = "Hide Erylo"
    package static let surfaceAccessibilityLabel = "Erylo surface visibility"
    package static let showSurfaceHint = "Shows the Erylo surface on the selected display."
    package static let hideSurfaceHint = "Hides the Erylo surface on the selected display."
    package static let disabledSurfaceHint = "The Erylo surface is turned off in Settings."
    package static let unavailableSurfaceHint = "The Erylo surface is temporarily unavailable."
    package static let startFocus15 = "Start 15-Minute Focus Timer"
    package static let startFocus25 = "Start 25-Minute Focus Timer"
    package static let startFocus50 = "Start 50-Minute Focus Timer"
    package static let cancelFocus = "Cancel Focus Timer"
    package static let startFocusHint = "Starts a new focus timer and replaces any focus timer already running."
    package static let replaceFocusHint = "Replaces the current focus timer with this duration."
    package static let cancelFocusHint = "Cancels the current focus timer. It has no effect when no focus timer is running."
    package static let settings = "Settings…"
    package static let startingSettings = "Settings (Starting…)"
    package static let restoringSettings = "Settings (Restoring…)"
    package static let settingsHint = "Opens Erylo Settings."
    package static let startingSettingsHint = "Settings will be available after Erylo finishes starting."
    package static let restoringSettingsHint = "Settings will be available after saved utilities finish restoring."
    package static let checkForUpdates = "Check for Updates…"
    package static let checkForUpdatesHint = "Checks for an Erylo update now."
    package static let shortcutReminder = "Shortcut: Control–Option–Command–E"
    package static let quit = "Quit Erylo"
    package static let quitHint = "Stops Erylo safely and quits."
    package static let starting = "Erylo is starting…"
    package static let restoring = "Restoring saved utilities…"
    package static let setupRequired = "Setup required"

    package static func remainingFocus(_ value: String) -> String {
        "Focus Timer · \(value) remaining"
    }

    package static func focusPreset(minutes: Int, replacing: Bool) -> String {
        replacing
            ? "Replace with \(minutes)-Minute Focus Timer"
            : "Start \(minutes)-Minute Focus Timer"
    }
}

package struct ApplicationMenuDescriptor: Equatable, Sendable {
    package let items: [ApplicationMenuItemDescriptor]

    package init(
        canCheckForUpdates: Bool,
        focusTimer: ApplicationFocusTimerMenuContext = .idle
    ) {
        self.init(
            runtime: ApplicationRuntimeControlSnapshot(
                coreCommandsAreAdmitted: true,
                focusCommandsAreAdmitted: true,
                quitCommandIsAdmitted: true,
                canCheckForUpdates: canCheckForUpdates,
                focusTimer: focusTimer,
                surface: .hidden
            ),
            readiness: ApplicationReadinessSnapshot(state: .ready)
        )
    }

    package init(
        runtime: ApplicationRuntimeControlSnapshot,
        readiness: ApplicationReadinessSnapshot
    ) {
        let focusCommandsAreAdmitted = runtime.focusCommandsAreAdmitted
        let focusTimer = focusCommandsAreAdmitted ? runtime.focusTimer : .idle
        let replacing = focusTimer.isActive
        let settingsCanOpen = runtime.coreCommandsAreAdmitted && readiness.state != .starting
        let surfaceIsActionable = runtime.coreCommandsAreAdmitted
            && (runtime.surface == .hidden || runtime.surface == .visible)
        let surfaceTitle = runtime.surface == .visible
            ? ApplicationControlCopy.hideSurface
            : ApplicationControlCopy.showSurface
        let surfaceHint: String = switch runtime.surface {
        case .visible:
            ApplicationControlCopy.hideSurfaceHint
        case .hidden:
            ApplicationControlCopy.showSurfaceHint
        case .disabled:
            ApplicationControlCopy.disabledSurfaceHint
        case .temporarilyUnavailable:
            ApplicationControlCopy.unavailableSurfaceHint
        }
        var items = [
            ApplicationMenuItemDescriptor(
                kind: .command(.toggleSurface),
                title: surfaceTitle,
                accessibilityLabel: ApplicationControlCopy.surfaceAccessibilityLabel,
                accessibilityHint: surfaceHint,
                accessibilityIdentifier: "erylo.surface.toggle",
                isEnabled: surfaceIsActionable
            ),
        ]
        switch readiness.state {
        case .starting:
            items.append(
                ApplicationMenuItemDescriptor(
                    kind: .information,
                    title: runtime.coreCommandsAreAdmitted
                        ? ApplicationControlCopy.restoring
                        : ApplicationControlCopy.starting,
                    accessibilityIdentifier: "erylo.readiness.starting",
                    isEnabled: false
                )
            )
        case .setupRequired:
            items.append(
                ApplicationMenuItemDescriptor(
                    kind: .information,
                    title: ApplicationControlCopy.setupRequired,
                    accessibilityIdentifier: "erylo.readiness.setup-required",
                    isEnabled: false
                )
            )
        case .needsAttention:
            for (index, notice) in readiness.notices.enumerated() {
                items.append(
                    ApplicationMenuItemDescriptor(
                        kind: .information,
                        title: notice,
                        accessibilityIdentifier: "erylo.readiness.attention.\(index + 1)",
                        isEnabled: false
                    )
                )
            }
        case .ready:
            break
        }
        if case let .active(remainingText) = focusTimer {
            items.append(
                ApplicationMenuItemDescriptor(
                    kind: .information,
                    title: ApplicationControlCopy.remainingFocus(remainingText),
                    accessibilityIdentifier: "erylo.focus-timer.remaining",
                    isEnabled: false
                )
            )
        }
        items.append(ApplicationMenuItemDescriptor(kind: .separator, title: ""))
        items.append(contentsOf: [
            ApplicationMenuItemDescriptor(
                kind: .command(.startFocusTimer15),
                title: ApplicationControlCopy.focusPreset(minutes: 15, replacing: replacing),
                keyEquivalent: focusCommandsAreAdmitted ? "1" : "",
                accessibilityLabel: "15-minute Focus Timer",
                accessibilityHint: replacing
                    ? ApplicationControlCopy.replaceFocusHint
                    : ApplicationControlCopy.startFocusHint,
                accessibilityIdentifier: "erylo.focus-timer.start-15",
                isEnabled: focusCommandsAreAdmitted
            ),
            ApplicationMenuItemDescriptor(
                kind: .command(.startFocusTimer25),
                title: ApplicationControlCopy.focusPreset(minutes: 25, replacing: replacing),
                keyEquivalent: focusCommandsAreAdmitted ? "2" : "",
                accessibilityLabel: "25-minute Focus Timer",
                accessibilityHint: replacing
                    ? ApplicationControlCopy.replaceFocusHint
                    : ApplicationControlCopy.startFocusHint,
                accessibilityIdentifier: "erylo.focus-timer.start-25",
                isEnabled: focusCommandsAreAdmitted
            ),
            ApplicationMenuItemDescriptor(
                kind: .command(.startFocusTimer50),
                title: ApplicationControlCopy.focusPreset(minutes: 50, replacing: replacing),
                keyEquivalent: focusCommandsAreAdmitted ? "5" : "",
                accessibilityLabel: "50-minute Focus Timer",
                accessibilityHint: replacing
                    ? ApplicationControlCopy.replaceFocusHint
                    : ApplicationControlCopy.startFocusHint,
                accessibilityIdentifier: "erylo.focus-timer.start-50",
                isEnabled: focusCommandsAreAdmitted
            ),
            ApplicationMenuItemDescriptor(
                kind: .command(.cancelFocusTimer),
                title: ApplicationControlCopy.cancelFocus,
                keyEquivalent: focusCommandsAreAdmitted && focusTimer.isActive ? "." : "",
                accessibilityLabel: "Cancel Focus Timer",
                accessibilityHint: ApplicationControlCopy.cancelFocusHint,
                accessibilityIdentifier: "erylo.focus-timer.cancel",
                isEnabled: focusCommandsAreAdmitted && focusTimer.isActive
            ),
            ApplicationMenuItemDescriptor(kind: .separator, title: ""),
            ApplicationMenuItemDescriptor(
                kind: .command(.showSettings),
                title: readiness.state == .starting
                    ? (runtime.coreCommandsAreAdmitted
                        ? ApplicationControlCopy.restoringSettings
                        : ApplicationControlCopy.startingSettings)
                    : ApplicationControlCopy.settings,
                keyEquivalent: settingsCanOpen ? "," : "",
                accessibilityLabel: "Erylo Settings",
                accessibilityHint: readiness.state == .starting
                    ? (runtime.coreCommandsAreAdmitted
                        ? ApplicationControlCopy.restoringSettingsHint
                        : ApplicationControlCopy.startingSettingsHint)
                    : ApplicationControlCopy.settingsHint,
                accessibilityIdentifier: "erylo.settings",
                isEnabled: settingsCanOpen
            ),
        ])
        if runtime.canCheckForUpdates {
            items.append(
                ApplicationMenuItemDescriptor(
                    kind: .command(.checkForUpdates),
                    title: ApplicationControlCopy.checkForUpdates,
                    accessibilityLabel: "Check for Erylo updates",
                    accessibilityHint: ApplicationControlCopy.checkForUpdatesHint,
                    accessibilityIdentifier: "erylo.updates.check",
                    isEnabled: runtime.coreCommandsAreAdmitted
                )
            )
        }
        if surfaceIsActionable {
            items.append(ApplicationMenuItemDescriptor(kind: .separator, title: ""))
            items.append(
                ApplicationMenuItemDescriptor(
                    kind: .information,
                    title: ApplicationControlCopy.shortcutReminder,
                    accessibilityIdentifier: "erylo.surface.shortcut",
                    isEnabled: false
                )
            )
        }
        items.append(ApplicationMenuItemDescriptor(kind: .separator, title: ""))
        items.append(
            ApplicationMenuItemDescriptor(
                kind: .command(.quit),
                title: ApplicationControlCopy.quit,
                keyEquivalent: runtime.quitCommandIsAdmitted ? "q" : "",
                accessibilityLabel: "Quit Erylo",
                accessibilityHint: ApplicationControlCopy.quitHint,
                accessibilityIdentifier: "erylo.quit",
                isEnabled: runtime.quitCommandIsAdmitted
            )
        )
        self.items = items
    }
}

@MainActor
package protocol ApplicationControlPresenting: AnyObject {
    func installStatusMenu(
        descriptorProvider: @escaping @MainActor () -> ApplicationMenuDescriptor,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void
    )
    func presentSettings(model: TrustSettingsViewModel)
    func shutdown()
}

@MainActor
package protocol ApplicationControlPlaneOwning: AnyObject {
    var readinessSnapshot: ApplicationReadinessSnapshot { get }
    func prepareForStartup() async -> DisplayPolicy
    @discardableResult
    func installEarlyControls(
        runtimeSnapshotProvider: @escaping @MainActor () -> ApplicationRuntimeControlSnapshot,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void,
        displayPolicyHandler: @escaping @MainActor (DisplayPolicy) -> Void
    ) -> Bool
    @discardableResult
    func restorePersistedModules() async -> Bool
    @discardableResult
    func presentSettings() -> Bool
    func shutdown() async
}

package protocol ApplicationSettingsOwning: TrustSettingsCoordinating {
    func loadReport() async -> SettingsLoadReport
    func restoreEnabledModules() async -> [PersistedModuleRestoreResult]
    func stopAll() async -> StopAllResult
}

extension TrustSettingsCoordinator: ApplicationSettingsOwning {}

/// Owns the menu/settings resources and the inert trust-settings composition.
/// Preparing and browsing perform reads only. Persisted provider work starts only
/// from the explicit application-start boundary.
@MainActor
package final class ApplicationControlPlane: ApplicationControlPlaneOwning {
    private let settingsOwner: any ApplicationSettingsOwning
    private let diagnosticsExporter: DiagnosticsExporter
    private let presenter: any ApplicationControlPresenting
    private let makeDisplayChoices: @MainActor () -> [DisplayChoice]
    private let availableModules: Set<EryloModule>
    private var viewModel: TrustSettingsViewModel?
    private var preparedSettings: EryloSettings?
    private var preparedLoadReport: SettingsLoadReport?
    private var displayPolicyHandler: (@MainActor (DisplayPolicy) -> Void)?
    private var controlsInstalled = false
    private var isRestoring = false
    private var hasRestored = false
    private var unsafeFallbackNeedsPersistence = false
    private var unresolvedRestoreFailures: Set<EryloModule> = []
    private var isShutDown = false
    private var shutdownTask: Task<Void, Never>?
    package private(set) var readinessSnapshot: ApplicationReadinessSnapshot = .starting

    package init(
        settingsOwner: any ApplicationSettingsOwning,
        diagnosticsExporter: DiagnosticsExporter,
        presenter: any ApplicationControlPresenting,
        availableModules: Set<EryloModule> = [],
        makeDisplayChoices: @escaping @MainActor () -> [DisplayChoice]
    ) {
        self.settingsOwner = settingsOwner
        self.diagnosticsExporter = diagnosticsExporter
        self.presenter = presenter
        self.availableModules = availableModules
        self.makeDisplayChoices = makeDisplayChoices
    }

    package static func production(activityBroker: ActivityBroker) -> ApplicationControlPlane {
        let repository = SettingsRepository(automaticallyPersistsMigrations: false)
        let events = InMemoryDiagnosticEventBuffer()
        let settingsOwner = TrustSettingsCoordinator(
            repository: repository,
            providerFactory: SystemGlanceModuleProviderFactory(broker: activityBroker),
            permissionRequester: DenyingModulePermissionRequester(),
            launchAtLoginController: SystemLaunchAtLoginController(),
            events: events
        )
        let diagnosticsExporter = DiagnosticsExporter(
            collector: PrivacyPreservingDiagnosticsCollector(eventSource: events)
        )
        return ApplicationControlPlane(
            settingsOwner: settingsOwner,
            diagnosticsExporter: diagnosticsExporter,
            presenter: NativeApplicationControlPresenter(),
            availableModules: [.battery, .volume],
            makeDisplayChoices: {
                let snapshots = SystemDisplayProvider().enabledDisplays()
                var externalIndex = 0
                return snapshots.map { snapshot in
                    let name: String
                    if snapshot.isMain {
                        name = "Main display"
                    } else {
                        externalIndex += 1
                        name = "External display \(externalIndex)"
                    }
                    return DisplayChoice(identity: snapshot.identity, name: name)
                }
            }
        )
    }

    package func prepareForStartup() async -> DisplayPolicy {
        if let preparedSettings {
            return preparedSettings.displays.displayPolicy
        }
        guard !isShutDown else { return DisplayPolicy(isEnabled: false) }

        let settings = await settingsOwner.currentSettings()
        let loadReport = await settingsOwner.loadReport()
        guard !isShutDown else { return DisplayPolicy(isEnabled: false) }
        preparedSettings = settings
        preparedLoadReport = loadReport
        viewModel = TrustSettingsViewModel(
            coordinator: settingsOwner,
            diagnosticsExporter: diagnosticsExporter,
            initialSettings: settings,
            displayChoices: makeDisplayChoices(),
            availableModules: availableModules,
            supportsMotionPreference: false,
            supportsFullscreenPreference: false,
            settingsDidChange: { [weak self] settings in
                self?.preparedSettings = settings
                self?.displayPolicyHandler?(settings.displays.displayPolicy)
            }
        )
        viewModel?.setSuccessfulSettingsChangeHandler { [weak self] change in
            self?.handleSuccessfulSettingsChange(change)
        }
        return settings.displays.displayPolicy
    }

    @discardableResult
    package func installEarlyControls(
        runtimeSnapshotProvider: @escaping @MainActor () -> ApplicationRuntimeControlSnapshot,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void,
        displayPolicyHandler: @escaping @MainActor (DisplayPolicy) -> Void
    ) -> Bool {
        guard !isShutDown, viewModel != nil else { return false }
        guard !controlsInstalled else { return false }
        self.displayPolicyHandler = displayPolicyHandler
        presenter.installStatusMenu(
            descriptorProvider: { [weak self] in
                ApplicationMenuDescriptor(
                    runtime: runtimeSnapshotProvider(),
                    readiness: self?.readinessSnapshot ?? .starting
                )
            },
            commandHandler: commandHandler
        )
        controlsInstalled = true
        return true
    }

    private func handleSuccessfulSettingsChange(_ change: TrustSettingsSuccessfulChange) {
        guard controlsInstalled, hasRestored, !isRestoring, !isShutDown else { return }

        unsafeFallbackNeedsPersistence = false
        preparedLoadReport = nil
        switch change.kind {
        case .persistedSettings:
            break
        case let .module(module, enabled):
            if enabled, change.settings.modules[module] {
                unresolvedRestoreFailures.remove(module)
            }
        case .resetToSafeDefaults:
            unresolvedRestoreFailures.removeAll(keepingCapacity: true)
        }
        let notices = currentRecoveryNotices()
        viewModel?.synchronize(
            settings: change.settings,
            statusMessage: notices.isEmpty ? nil : notices.joined(separator: " "),
            startupFailureModules: unresolvedRestoreFailures
        )
        readinessSnapshot = ApplicationReadinessSnapshot(
            state: notices.isEmpty
                ? (change.settings.onboardingCompleted ? .ready : .setupRequired)
                : .needsAttention,
            notices: notices
        )
    }

    @discardableResult
    package func restorePersistedModules() async -> Bool {
        guard controlsInstalled, !isShutDown, !isRestoring, !hasRestored else { return false }
        isRestoring = true
        let restoreResults = await settingsOwner.restoreEnabledModules()
        guard !isShutDown, !Task.isCancelled else { return false }

        // Re-read after the serial restoration transaction settles instead of
        // trusting one result to represent a multi-module launch.
        let settledSettings = await settingsOwner.currentSettings()
        guard !isShutDown, !Task.isCancelled, let viewModel else { return false }
        preparedSettings = settledSettings
        unsafeFallbackNeedsPersistence = preparedLoadReport?.usedUnsafeFallback == true
        unresolvedRestoreFailures = Set(
            restoreResults.compactMap { result in
                result.failure == nil ? nil : result.module
            }
        )
        let notices = recoveryNotices(for: restoreResults, loadReport: preparedLoadReport)
        viewModel.synchronize(
            settings: settledSettings,
            statusMessage: notices.isEmpty ? nil : notices.joined(separator: " "),
            startupFailureModules: unresolvedRestoreFailures
        )
        isRestoring = false
        hasRestored = true
        readinessSnapshot = ApplicationReadinessSnapshot(
            state: notices.isEmpty
                ? (settledSettings.onboardingCompleted ? .ready : .setupRequired)
                : .needsAttention,
            notices: notices
        )
        if !settledSettings.onboardingCompleted {
            presenter.presentSettings(model: viewModel)
        }
        return true
    }

    @discardableResult
    package func presentSettings() -> Bool {
        guard controlsInstalled,
              readinessSnapshot.state != .starting,
              !isShutDown,
              let viewModel else { return false }
        viewModel.updateDisplayChoices(makeDisplayChoices())
        presenter.presentSettings(model: viewModel)
        return true
    }

    package func shutdown() async {
        if let shutdownTask {
            _ = await shutdownTask.value
            return
        }
        guard !isShutDown else { return }
        isShutDown = true
        controlsInstalled = false
        displayPolicyHandler = nil
        let task = Task { @MainActor [self] in
            presenter.shutdown()
            _ = await settingsOwner.stopAll()
            viewModel = nil
            preparedSettings = nil
            preparedLoadReport = nil
            unsafeFallbackNeedsPersistence = false
            unresolvedRestoreFailures.removeAll(keepingCapacity: false)
            shutdownTask = nil
        }
        shutdownTask = task
        _ = await task.value
    }

    private func recoveryNotices(
        for results: [PersistedModuleRestoreResult],
        loadReport: SettingsLoadReport?
    ) -> [String] {
        var notices: [String] = []
        if let loadReport, loadReport.usedUnsafeFallback {
            notices.append("Safe defaults were used.")
        }
        for result in results where result.failure != nil {
            notices.append("\(result.module.userFacingName) could not start and was left off.")
        }
        return Array(notices.prefix(ApplicationReadinessSnapshot.maximumNotices))
    }

    private func currentRecoveryNotices() -> [String] {
        var notices: [String] = []
        if unsafeFallbackNeedsPersistence {
            notices.append("Safe defaults were used.")
        }
        for module in EryloModule.allCases where unresolvedRestoreFailures.contains(module) {
            notices.append("\(module.userFacingName) could not start and was left off.")
        }
        return Array(notices.prefix(ApplicationReadinessSnapshot.maximumNotices))
    }
}

private extension SettingsLoadReport {
    var usedUnsafeFallback: Bool {
        switch disposition {
        case .corrupt, .unsupportedVersion, .oversized, .readFailure:
            true
        case .missing, .current, .migrated:
            false
        }
    }
}

private extension EryloModule {
    var userFacingName: String {
        switch self {
        case .fileHold: "File Hold"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .battery: "Battery"
        case .timer: "Focus Timer"
        case .calendar: "Calendar"
        case .volume: "Volume"
        case .localIntegrations: "Local Integrations"
        }
    }
}

@MainActor
private final class NativeApplicationControlPresenter: NSObject, ApplicationControlPresenting {
    private var statusItem: NSStatusItem?
    private var commandHandler: (@MainActor (ApplicationControlCommand) -> Void)?
    private var settingsWindowController: NativeSettingsWindowController?
    private var descriptorProvider: (@MainActor () -> ApplicationMenuDescriptor)?

    func installStatusMenu(
        descriptorProvider: @escaping @MainActor () -> ApplicationMenuDescriptor,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void
    ) {
        guard statusItem == nil else { return }
        self.commandHandler = commandHandler
        self.descriptorProvider = descriptorProvider

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "Erylo"
            button.toolTip = ApplicationControlCopy.statusItemHint
            button.setAccessibilityLabel(ApplicationControlCopy.statusItemLabel)
            button.setAccessibilityHelp(ApplicationControlCopy.statusItemHint)
            button.setAccessibilityIdentifier("erylo.status-menu")
        }

        let menu = NSMenu(title: "Erylo")
        menu.autoenablesItems = false
        menu.delegate = self
        rebuild(menu, with: descriptorProvider())
        item.menu = menu
        statusItem = item
    }

    private func rebuild(_ menu: NSMenu, with descriptor: ApplicationMenuDescriptor) {
        menu.removeAllItems()
        for descriptor in descriptor.items {
            switch descriptor.kind {
            case .separator:
                menu.addItem(.separator())
            case let .command(command):
                let menuItem = NSMenuItem(
                    title: descriptor.title,
                    action: #selector(performCommand(_:)),
                    keyEquivalent: descriptor.keyEquivalent
                )
                menuItem.target = self
                menuItem.representedObject = NSNumber(value: command.rawValue)
                menuItem.isEnabled = descriptor.isEnabled
                menuItem.keyEquivalentModifierMask = descriptor.keyEquivalent.isEmpty ? [] : [.command]
                menuItem.setAccessibilityLabel(descriptor.accessibilityLabel ?? descriptor.title)
                if let accessibilityHint = descriptor.accessibilityHint {
                    menuItem.setAccessibilityHelp(accessibilityHint)
                }
                if let accessibilityIdentifier = descriptor.accessibilityIdentifier {
                    menuItem.setAccessibilityIdentifier(accessibilityIdentifier)
                }
                menu.addItem(menuItem)
            case .information:
                let menuItem = NSMenuItem(title: descriptor.title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = descriptor.isEnabled
                menuItem.setAccessibilityLabel(descriptor.accessibilityLabel ?? descriptor.title)
                if let accessibilityHint = descriptor.accessibilityHint {
                    menuItem.setAccessibilityHelp(accessibilityHint)
                }
                if let accessibilityIdentifier = descriptor.accessibilityIdentifier {
                    menuItem.setAccessibilityIdentifier(accessibilityIdentifier)
                }
                menu.addItem(menuItem)
            }
        }
    }

    func presentSettings(model: TrustSettingsViewModel) {
        let controller: NativeSettingsWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            controller = NativeSettingsWindowController(model: model)
            settingsWindowController = controller
        }
        controller.present()
    }

    func shutdown() {
        commandHandler = nil
        descriptorProvider = nil
        settingsWindowController?.shutdown()
        settingsWindowController = nil
        if let statusItem {
            statusItem.menu = nil
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc
    private func performCommand(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.intValue,
              let command = ApplicationControlCommand(rawValue: value) else {
            return
        }
        commandHandler?(command)
    }
}

extension NativeApplicationControlPresenter: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard let descriptorProvider else { return }
        rebuild(menu, with: descriptorProvider())
    }
}

@MainActor
private final class NativeSettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    init(model: TrustSettingsViewModel) {
        let hostingController = NSHostingController(rootView: TrustSettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Erylo Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 500)
        window.center()
        self.window = window
        super.init()
        window.delegate = self
    }

    func present() {
        guard let window else { return }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func shutdown() {
        guard let window else { return }
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        window.contentViewController = nil
        self.window = nil
    }
}

private enum UnavailableModuleProviderError: Error {
    case unavailable
}

private struct DenyingModulePermissionRequester: ModulePermissionRequesting {
    func requestPermission(
        _ requirement: ModulePermissionRequirement,
        for module: EryloModule
    ) async throws {
        _ = requirement
        _ = module
        throw UnavailableModuleProviderError.unavailable
    }
}
