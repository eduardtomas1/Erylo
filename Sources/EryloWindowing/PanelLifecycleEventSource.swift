import AppKit
import Carbon.HIToolbox
import CoreGraphics

public enum PanelLifecycleEvent: Equatable, Sendable {
    case displayConfigurationChanged
    case workspaceWillSleep
    case workspaceDidWake
    case activeSpaceChanged
    case pointerMoved(CGPoint)
    case primaryShortcut
}

@MainActor
public protocol PanelLifecycleEventSourcing: AnyObject {
    var isRunning: Bool { get }

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void)
    func stop()
}

@MainActor
public final class SystemPanelLifecycleEventSource: PanelLifecycleEventSourcing {
    public private(set) var isRunning = false

    private var handler: (@MainActor @Sendable (PanelLifecycleEvent) -> Void)?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var hotKey: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?

    public init() {}

    public func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        self.handler = handler
        installNotifications()
        installPointerMonitors()
        installPrimaryShortcut()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()

        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let hotKeyEventHandler {
            RemoveEventHandler(hotKeyEventHandler)
            self.hotKeyEventHandler = nil
        }

        handler = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    private func installNotifications() {
        applicationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handler?(.displayConfigurationChanged)
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handler?(.workspaceWillSleep)
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handler?(.workspaceDidWake)
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handler?(.activeSpaceChanged)
                }
            }
        )
    }

    private func installPointerMonitors() {
        let pointerEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] _ in
            Task { @MainActor in
                self?.handler?(.pointerMoved(NSEvent.mouseLocation))
            }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handler?(.pointerMoved(NSEvent.mouseLocation))
            }
            return event
        }
    }

    /// Carbon's public hot-key registration provides a global route without Accessibility
    /// permission or a global key-event monitor. The callback only changes panel state.
    private func installPrimaryShortcut() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            eryloHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &hotKeyEventHandler
        )
        guard installStatus == noErr else { return }

        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(cmdKey | optionKey | controlKey),
            EventHotKeyID(signature: 0x4552_594C, id: 1),
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registrationStatus == noErr else {
            if let hotKeyEventHandler {
                RemoveEventHandler(hotKeyEventHandler)
                self.hotKeyEventHandler = nil
            }
            return
        }
        hotKey = registeredHotKey
    }

    fileprivate func receivePrimaryShortcut() {
        handler?(.primaryShortcut)
    }
}

private func eryloHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var receivedHotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &receivedHotKeyID
    )
    guard status == noErr, receivedHotKeyID.signature == 0x4552_594C,
          receivedHotKeyID.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }

    let source = Unmanaged<SystemPanelLifecycleEventSource>
        .fromOpaque(userData)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        source.receivePrimaryShortcut()
    }
    return noErr
}
