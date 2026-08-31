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
    package let accessibilityHint: String?
    package let accessibilityIdentifier: String?

    package init(
        kind: ApplicationMenuItemKind,
        title: String,
        keyEquivalent: String = "",
        accessibilityHint: String? = nil,
        accessibilityIdentifier: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.accessibilityHint = accessibilityHint
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

package enum ApplicationControlCopy {
    package static let statusItemLabel = "Erylo controls"
    package static let statusItemHint = "Opens Focus Timer controls, the Erylo surface, settings, updates, and quitting."
    package static let toggleSurface = "Show/Hide Erylo"
    package static let startFocus15 = "Start 15-Minute Focus Timer"
    package static let startFocus25 = "Start 25-Minute Focus Timer"
    package static let startFocus50 = "Start 50-Minute Focus Timer"
    package static let cancelFocus = "Cancel Focus Timer"
    package static let startFocusHint = "Starts a new focus timer and replaces any focus timer already running."
    package static let cancelFocusHint = "Cancels the current focus timer. It has no effect when no focus timer is running."
    package static let settings = "Settings…"
    package static let checkForUpdates = "Check for Updates…"
    package static let shortcutReminder = "Shortcut: Control–Option–Command–E"
    package static let quit = "Quit Erylo"
}

package struct ApplicationMenuDescriptor: Equatable, Sendable {
    package let items: [ApplicationMenuItemDescriptor]

    package init(canCheckForUpdates: Bool) {
        var items = [
            ApplicationMenuItemDescriptor(
                kind: .command(.toggleSurface),
                title: ApplicationControlCopy.toggleSurface
            ),
            ApplicationMenuItemDescriptor(kind: .separator, title: ""),
            ApplicationMenuItemDescriptor(
                kind: .command(.startFocusTimer15),
                title: ApplicationControlCopy.startFocus15,
                keyEquivalent: "1",
                accessibilityHint: ApplicationControlCopy.startFocusHint,
                accessibilityIdentifier: "erylo.focus-timer.start-15"
            ),
            ApplicationMenuItemDescriptor(
                kind: .command(.startFocusTimer25),
                title: ApplicationControlCopy.startFocus25,
                keyEquivalent: "2",
                accessibilityHint: ApplicationControlCopy.startFocusHint,
                accessibilityIdentifier: "erylo.focus-timer.start-25"
            ),
            ApplicationMenuItemDescriptor(
                kind: .command(.startFocusTimer50),
                title: ApplicationControlCopy.startFocus50,
                keyEquivalent: "5",
                accessibilityHint: ApplicationControlCopy.startFocusHint,
                accessibilityIdentifier: "erylo.focus-timer.start-50"
            ),
            ApplicationMenuItemDescriptor(
                kind: .command(.cancelFocusTimer),
                title: ApplicationControlCopy.cancelFocus,
                keyEquivalent: ".",
                accessibilityHint: ApplicationControlCopy.cancelFocusHint,
                accessibilityIdentifier: "erylo.focus-timer.cancel"
            ),
            ApplicationMenuItemDescriptor(kind: .separator, title: ""),
            ApplicationMenuItemDescriptor(
                kind: .command(.showSettings),
                title: ApplicationControlCopy.settings,
                keyEquivalent: ","
            ),
        ]
        if canCheckForUpdates {
            items.append(
                ApplicationMenuItemDescriptor(
                    kind: .command(.checkForUpdates),
                    title: ApplicationControlCopy.checkForUpdates
                )
            )
        }
        items.append(contentsOf: [
            ApplicationMenuItemDescriptor(kind: .separator, title: ""),
            ApplicationMenuItemDescriptor(
                kind: .information,
                title: ApplicationControlCopy.shortcutReminder
            ),
            ApplicationMenuItemDescriptor(kind: .separator, title: ""),
            ApplicationMenuItemDescriptor(
                kind: .command(.quit),
                title: ApplicationControlCopy.quit,
                keyEquivalent: "q"
            ),
        ])
        self.items = items
    }
}

@MainActor
package protocol ApplicationControlPresenting: AnyObject {
    func installStatusMenu(
        _ descriptor: ApplicationMenuDescriptor,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void
    )
    func presentSettings(model: TrustSettingsViewModel)
    func shutdown()
}

@MainActor
package protocol ApplicationControlPlaneOwning: AnyObject {
    func prepareForStartup() async -> DisplayPolicy
    func start(
        canCheckForUpdates: Bool,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void,
        displayPolicyHandler: @escaping @MainActor (DisplayPolicy) -> Void
    ) async
    func presentSettings()
    func shutdown() async
}

package protocol ApplicationSettingsOwning: TrustSettingsCoordinating {
    func startEnabledModules() async -> [TrustSettingsUpdateResult]
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
    private var displayPolicyHandler: (@MainActor (DisplayPolicy) -> Void)?
    private var isStarted = false
    private var isShutDown = false
    private var shutdownTask: Task<Void, Never>?

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
        guard !isShutDown else { return DisplayPolicy(isEnabled: false) }
        preparedSettings = settings
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
        return settings.displays.displayPolicy
    }

    package func start(
        canCheckForUpdates: Bool,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void,
        displayPolicyHandler: @escaping @MainActor (DisplayPolicy) -> Void
    ) async {
        guard !isShutDown, !isStarted else { return }
        if viewModel == nil {
            _ = await prepareForStartup()
        }
        guard !isShutDown, let viewModel else { return }

        let restoreResults = await settingsOwner.startEnabledModules()
        guard !isShutDown, !Task.isCancelled else { return }
        if let restoredSettings = restoreResults.last?.settings {
            preparedSettings = restoredSettings
            viewModel.synchronize(settings: restoredSettings)
        }

        self.displayPolicyHandler = displayPolicyHandler
        presenter.installStatusMenu(
            ApplicationMenuDescriptor(canCheckForUpdates: canCheckForUpdates),
            commandHandler: commandHandler
        )
        isStarted = true
        if preparedSettings?.onboardingCompleted == false {
            presenter.presentSettings(model: viewModel)
        }
    }

    package func presentSettings() {
        guard isStarted, !isShutDown, let viewModel else { return }
        viewModel.updateDisplayChoices(makeDisplayChoices())
        presenter.presentSettings(model: viewModel)
    }

    package func shutdown() async {
        if let shutdownTask {
            _ = await shutdownTask.value
            return
        }
        guard !isShutDown else { return }
        isShutDown = true
        isStarted = false
        displayPolicyHandler = nil
        let task = Task { @MainActor [self] in
            presenter.shutdown()
            _ = await settingsOwner.stopAll()
            viewModel = nil
            preparedSettings = nil
            shutdownTask = nil
        }
        shutdownTask = task
        _ = await task.value
    }
}

@MainActor
private final class NativeApplicationControlPresenter: NSObject, ApplicationControlPresenting {
    private var statusItem: NSStatusItem?
    private var commandHandler: (@MainActor (ApplicationControlCommand) -> Void)?
    private var settingsWindowController: NativeSettingsWindowController?

    func installStatusMenu(
        _ descriptor: ApplicationMenuDescriptor,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void
    ) {
        guard statusItem == nil else { return }
        self.commandHandler = commandHandler

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
                menuItem.isEnabled = true
                menuItem.keyEquivalentModifierMask = descriptor.keyEquivalent.isEmpty ? [] : [.command]
                menuItem.setAccessibilityLabel(descriptor.title)
                if let accessibilityHint = descriptor.accessibilityHint {
                    menuItem.setAccessibilityHelp(accessibilityHint)
                }
                if let accessibilityIdentifier = descriptor.accessibilityIdentifier {
                    menuItem.setAccessibilityIdentifier(accessibilityIdentifier)
                }
                menu.addItem(menuItem)
            case .information:
                let menuItem = NSMenuItem(
                    title: descriptor.title,
                    action: #selector(acknowledgeShortcutReminder(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.isEnabled = true
                menu.addItem(menuItem)
            }
        }
        item.menu = menu
        statusItem = item
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

    @objc
    private func acknowledgeShortcutReminder(_ sender: NSMenuItem) {
        _ = sender
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
