import EryloActivity
import Foundation

/// The four MVP glance providers. Construction is inert; callers opt each provider in explicitly.
public struct EryloGlance: Sendable {
    public let power: PowerGlanceProvider
    public let countdown: CountdownGlanceProvider
    public let calendar: CalendarGlanceProvider
    public let volume: VolumeGlanceProvider

    @MainActor
    public init(broker: ActivityBroker) {
        let clock = SystemGlanceClock()
        self.init(
            broker: broker,
            powerSource: IOPowerEventSource(),
            volumeSource: CoreAudioVolumeEventSource(),
            calendarSource: EventKitCalendarEventSource(),
            clock: clock
        )
    }

    public init(
        broker: ActivityBroker,
        powerSource: any PowerEventSource,
        volumeSource: any VolumeEventSource,
        calendarSource: any CalendarEventSource,
        clock: any GlanceClock
    ) {
        power = PowerGlanceProvider(broker: broker, source: powerSource)
        countdown = CountdownGlanceProvider(broker: broker, clock: clock)
        calendar = CalendarGlanceProvider(
            broker: broker,
            source: calendarSource,
            clock: clock
        )
        volume = VolumeGlanceProvider(broker: broker, source: volumeSource)
    }

    /// Awaits every lifecycle tail so no glance observer, consumer, or boundary remains on return.
    public func disableAll() async {
        async let powerShutdown: Void = power.disable()
        async let countdownShutdown: Void = countdown.disable()
        async let calendarShutdown: Void = calendar.disable()
        async let volumeShutdown: Void = volume.disable()
        _ = await (
            powerShutdown,
            countdownShutdown,
            calendarShutdown,
            volumeShutdown
        )
    }
}
