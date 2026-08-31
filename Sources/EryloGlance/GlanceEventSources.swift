import AppKit
import AudioToolbox
import CoreAudio
import EventKit
import Foundation
import IOKit.ps

public enum GlanceEventSourceError: Error, Equatable, Sendable {
    case observerRegistrationFailed
    case permissionRequestFailed
}

public protocol PowerEventSource: Sendable {
    func start(
        handler: @escaping @Sendable (PowerSourceEvent) -> Void
    ) async throws
    func stop() async
}

public protocol VolumeEventSource: Sendable {
    func start(
        handler: @escaping @Sendable (VolumeSourceEvent) -> Void
    ) async throws
    func stop() async
}

public protocol CalendarEventSource: Sendable {
    func authorizationStatus() async -> CalendarAuthorization
    func requestFullAccess() async throws -> Bool
    func start(changeHandler: @escaping @Sendable () -> Void) async throws
    func start(eventHandler: @escaping @Sendable (CalendarSourceEvent) -> Void) async throws
    func stop() async
    func nextMeeting(after startDate: Date, until endDate: Date) async throws -> CalendarMeeting?
}

public extension CalendarEventSource {
    /// Compatibility path for sources that only distinguish EventKit changes. Production
    /// adapters override this seam to identify clock, time-zone, and wake convergence.
    func start(eventHandler: @escaping @Sendable (CalendarSourceEvent) -> Void) async throws {
        try await start {
            eventHandler(.eventStoreChanged)
        }
    }
}

private final class PowerCallbackBox: @unchecked Sendable {
    let handler: @Sendable (PowerSourceEvent) -> Void

    init(handler: @escaping @Sendable (PowerSourceEvent) -> Void) {
        self.handler = handler
    }

    func emitCurrentSnapshot() {
        handler(readPowerSourceEvent())
    }
}

private final class PowerObserverState: @unchecked Sendable {
    var runLoopSource: CFRunLoopSource?
    var callbackContext: UnsafeMutableRawPointer?

    func removeObserver() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
            self.runLoopSource = nil
        }
        if let callbackContext {
            Unmanaged<PowerCallbackBox>.fromOpaque(callbackContext).release()
            self.callbackContext = nil
        }
    }

    deinit {
        removeObserver()
    }
}

private func powerSourceChanged(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<PowerCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .emitCurrentSnapshot()
}

private func readPowerSourceEvent() -> PowerSourceEvent {
    guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else { return .unavailable }
    let info = unmanagedInfo.takeRetainedValue()
    guard let unmanagedList = IOPSCopyPowerSourcesList(info) else { return .unavailable }
    let sources = unmanagedList.takeRetainedValue() as [AnyObject]

    for source in sources {
        guard let unmanagedDescription = IOPSGetPowerSourceDescription(info, source) else { continue }
        let description = unmanagedDescription.takeUnretainedValue() as NSDictionary
        guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              let currentCapacity = description[kIOPSCurrentCapacityKey] as? NSNumber,
              let maximumCapacity = description[kIOPSMaxCapacityKey] as? NSNumber,
              maximumCapacity.doubleValue > 0 else {
            continue
        }

        let chargeLevel = min(max(currentCapacity.doubleValue / maximumCapacity.doubleValue, 0), 1)
        let isCharging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
        let state = description[kIOPSPowerSourceStateKey] as? String
        do {
            return .snapshot(
                try PowerSnapshot(
                    chargeLevel: chargeLevel,
                    isCharging: isCharging,
                    isConnectedToPower: state == kIOPSACPowerValue
                )
            )
        } catch {
            return .unavailable
        }
    }
    return .unavailable
}

/// Public IOPowerSources notifications; no polling or repeating timer is used.
@MainActor
public final class IOPowerEventSource: PowerEventSource {
    private let observerState = PowerObserverState()

    public init() {}

    public func start(
        handler: @escaping @Sendable (PowerSourceEvent) -> Void
    ) async throws {
        guard observerState.runLoopSource == nil else { return }

        let box = PowerCallbackBox(handler: handler)
        let context = Unmanaged.passRetained(box).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource(powerSourceChanged, context) else {
            Unmanaged<PowerCallbackBox>.fromOpaque(context).release()
            throw GlanceEventSourceError.observerRegistrationFailed
        }

        let source = unmanagedSource.takeRetainedValue()
        observerState.runLoopSource = source
        observerState.callbackContext = context
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        box.emitCurrentSnapshot()
    }

    public func stop() async {
        observerState.removeObserver()
    }
}

/// Public CoreAudio property listeners for the default output device, volume, and mute.
public final class CoreAudioVolumeEventSource: VolumeEventSource, @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "com.erylo.glance.coreaudio")
    private let callbackQueueKey = DispatchSpecificKey<UInt8>()
    private var handler: (@Sendable (VolumeSourceEvent) -> Void)?
    private var isStarted = false
    private var currentDevice: AudioDeviceID?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var devicePropertyListener: AudioObjectPropertyListenerBlock?
    private var observedDeviceAddresses: [AudioObjectPropertyAddress] = []

    public init() {
        callbackQueue.setSpecific(key: callbackQueueKey, value: 1)
    }

    public func start(
        handler: @escaping @Sendable (VolumeSourceEvent) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            callbackQueue.async { [self] in
                do {
                    try startOnQueue(handler: handler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnQueue(
        handler: @escaping @Sendable (VolumeSourceEvent) -> Void
    ) throws {
        guard !isStarted else { return }
        self.handler = handler
        isStarted = true

        var defaultAddress = Self.defaultDeviceAddress
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.defaultOutputDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            callbackQueue,
            defaultListener
        )
        guard status == noErr else {
            self.handler = nil
            isStarted = false
            throw GlanceEventSourceError.observerRegistrationFailed
        }
        defaultDeviceListener = defaultListener
        installCurrentDeviceListenersOnQueue()
        self.handler?(currentEventOnQueue())
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            callbackQueue.async { [self] in
                stopOnQueue()
                continuation.resume()
            }
        }
    }

    deinit {
        performSynchronously {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard isStarted else { return }
        removeCurrentDeviceListenersOnQueue()
        if let defaultDeviceListener {
            var address = Self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                callbackQueue,
                defaultDeviceListener
            )
        }
        defaultDeviceListener = nil
        handler = nil
        isStarted = false
    }

    private func defaultOutputDeviceChanged() {
        guard isStarted else { return }
        removeCurrentDeviceListenersOnQueue()
        installCurrentDeviceListenersOnQueue()
        handler?(currentEventOnQueue())
    }

    private func devicePropertyChanged() {
        guard isStarted else { return }
        handler?(currentEventOnQueue())
    }

    private func installCurrentDeviceListenersOnQueue() {
        guard let device = Self.readDefaultOutputDevice() else {
            currentDevice = nil
            return
        }
        currentDevice = device

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.devicePropertyChanged()
        }
        devicePropertyListener = listener

        var addresses = [Self.volumeAddress, Self.muteAddress]
        for index in addresses.indices {
            guard AudioObjectHasProperty(device, &addresses[index]) else { continue }
            let status = AudioObjectAddPropertyListenerBlock(
                device,
                &addresses[index],
                callbackQueue,
                listener
            )
            if status == noErr {
                observedDeviceAddresses.append(addresses[index])
            }
        }
    }

    private func removeCurrentDeviceListenersOnQueue() {
        if let device = currentDevice, let listener = devicePropertyListener {
            for var address in observedDeviceAddresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, callbackQueue, listener)
            }
        }
        observedDeviceAddresses.removeAll(keepingCapacity: true)
        devicePropertyListener = nil
        currentDevice = nil
    }

    private func currentEventOnQueue() -> VolumeSourceEvent {
        guard let device = currentDevice,
              let volume = Self.readFloatProperty(device, address: Self.volumeAddress) else {
            return .unavailable
        }
        let muteValue = Self.readUInt32Property(device, address: Self.muteAddress) ?? 0
        do {
            return .snapshot(
                try VolumeSnapshot(
                    deviceID: device,
                    scalar: min(max(Double(volume), 0), 1),
                    isMuted: muteValue != 0,
                    outputDisplayName: Self.readStringProperty(
                        device,
                        address: Self.outputDisplayNameAddress
                    )
                )
            )
        } catch {
            return .unavailable
        }
    }

    private static func readDefaultOutputDevice() -> AudioDeviceID? {
        var address = defaultDeviceAddress
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func readFloatProperty(
        _ object: AudioObjectID,
        address originalAddress: AudioObjectPropertyAddress
    ) -> Float32? {
        var address = originalAddress
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func readUInt32Property(
        _ object: AudioObjectID,
        address originalAddress: AudioObjectPropertyAddress
    ) -> UInt32? {
        var address = originalAddress
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func readStringProperty(
        _ object: AudioObjectID,
        address originalAddress: AudioObjectPropertyAddress
    ) -> String? {
        var address = originalAddress
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func performSynchronously(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: callbackQueueKey) != nil {
            operation()
        } else {
            callbackQueue.sync(execute: operation)
        }
    }

    private static let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let outputDisplayNameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

/// Public EventKit access. Permission is requested only when the calendar provider calls it.
private final class CalendarObserverState: @unchecked Sendable {
    struct Registration {
        let center: NotificationCenter
        let observer: NSObjectProtocol
    }

    var registrations: [Registration] = []

    func removeObserver() {
        for registration in registrations {
            registration.center.removeObserver(registration.observer)
        }
        registrations.removeAll(keepingCapacity: true)
    }

    deinit {
        removeObserver()
    }
}

@MainActor
public final class EventKitCalendarEventSource: CalendarEventSource {
    private let eventStore: EKEventStore
    private let observerState = CalendarObserverState()

    public init() {
        eventStore = EKEventStore()
    }

    public func authorizationStatus() async -> CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .fullAccess:
            .fullAccess
        case .writeOnly:
            .writeOnly
        @unknown default:
            .restricted
        }
    }

    public func requestFullAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if error != nil {
                    continuation.resume(throwing: GlanceEventSourceError.permissionRequestFailed)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    public func start(changeHandler: @escaping @Sendable () -> Void) async throws {
        try await start { _ in
            changeHandler()
        }
    }

    public func start(
        eventHandler: @escaping @Sendable (CalendarSourceEvent) -> Void
    ) async throws {
        guard observerState.registrations.isEmpty else { return }

        let eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { _ in
            eventHandler(.eventStoreChanged)
        }
        observerState.registrations.append(
            .init(center: .default, observer: eventStoreObserver)
        )

        let clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { _ in
            eventHandler(.wallClockChanged)
        }
        observerState.registrations.append(
            .init(center: .default, observer: clockObserver)
        )

        let timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { _ in
            eventHandler(.timeZoneChanged)
        }
        observerState.registrations.append(
            .init(center: .default, observer: timeZoneObserver)
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            eventHandler(.didWake)
        }
        observerState.registrations.append(
            .init(center: workspaceCenter, observer: wakeObserver)
        )
    }

    public func stop() async {
        observerState.removeObserver()
    }

    public func nextMeeting(after startDate: Date, until endDate: Date) async throws -> CalendarMeeting? {
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && $0.endDate > startDate }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
                return ($0.eventIdentifier ?? $0.calendarItemIdentifier)
                    < ($1.eventIdentifier ?? $1.calendarItemIdentifier)
            }

        for event in events {
            do {
                return try CalendarMeeting(
                    eventIdentifier: event.eventIdentifier ?? event.calendarItemIdentifier,
                    title: event.title ?? "Upcoming meeting",
                    startDate: event.startDate,
                    endDate: event.endDate
                )
            } catch {
                continue
            }
        }
        return nil
    }

}
