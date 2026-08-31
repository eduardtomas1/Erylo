import EryloGlance
import EryloTrust

package enum SystemGlanceRuntimeError: Error, Equatable, Sendable {
    case unsupportedModule(EryloModule)
    case activationFailed(GlanceProviderStatus)
}

/// The narrow composition seam between Trust's transactional module lifecycle and
/// the two event-driven system Glance providers mounted by the application.
package struct SystemGlanceModuleProviderFactory: ModuleProviderFactory {
    package typealias PowerSourceFactory = @Sendable () async -> any PowerEventSource
    package typealias VolumeSourceFactory = @Sendable () async -> any VolumeEventSource

    private let broker: any GlanceActivityBroker
    private let makePowerSource: PowerSourceFactory
    private let makeVolumeSource: VolumeSourceFactory

    package init(
        broker: any GlanceActivityBroker,
        makePowerSource: @escaping PowerSourceFactory = {
            await MainActor.run { IOPowerEventSource() }
        },
        makeVolumeSource: @escaping VolumeSourceFactory = {
            CoreAudioVolumeEventSource()
        }
    ) {
        self.broker = broker
        self.makePowerSource = makePowerSource
        self.makeVolumeSource = makeVolumeSource
    }

    /// Factory construction is inert. A source is constructed only for a deliberate
    /// Battery or Volume enable/restore transaction, and its own construction is inert.
    package func makeProvider(
        for module: EryloModule
    ) async throws -> any ModuleLifecycleProvider {
        switch module {
        case .battery:
            let provider = PowerGlanceProvider(
                broker: broker,
                source: await makePowerSource()
            )
            return PowerGlanceLifecycleAdapter(provider: provider)
        case .volume:
            let provider = VolumeGlanceProvider(
                broker: broker,
                source: await makeVolumeSource()
            )
            return VolumeGlanceLifecycleAdapter(provider: provider)
        case .fileHold, .appleMusic, .spotify, .timer, .calendar, .localIntegrations:
            throw SystemGlanceRuntimeError.unsupportedModule(module)
        }
    }
}

/// Exact start/stop translation for the Battery provider. A synchronous source
/// registration failure is normalized into Trust's provider-start rollback path.
package struct PowerGlanceLifecycleAdapter: ModuleLifecycleProvider {
    package let provider: PowerGlanceProvider

    package init(provider: PowerGlanceProvider) {
        self.provider = provider
    }

    package func start() async throws {
        await provider.enable()
        let status = await provider.status()
        let workState = await provider.workState()
        guard !Task.isCancelled,
              status.isEnabled,
              workState.activeObserverCount == 1,
              workState.activeConsumerTaskCount == 1 else {
            await provider.disable()
            if Task.isCancelled { throw CancellationError() }
            throw SystemGlanceRuntimeError.activationFailed(status)
        }
    }

    package func stop() async {
        await provider.disable()
    }
}

/// Exact start/stop translation for the default-output Volume provider.
package struct VolumeGlanceLifecycleAdapter: ModuleLifecycleProvider {
    package let provider: VolumeGlanceProvider

    package init(provider: VolumeGlanceProvider) {
        self.provider = provider
    }

    package func start() async throws {
        await provider.enable()
        let status = await provider.status()
        let workState = await provider.workState()
        guard !Task.isCancelled,
              status.isEnabled,
              workState.activeObserverCount == 1,
              workState.activeConsumerTaskCount == 1 else {
            await provider.disable()
            if Task.isCancelled { throw CancellationError() }
            throw SystemGlanceRuntimeError.activationFailed(status)
        }
    }

    package func stop() async {
        await provider.disable()
    }
}
