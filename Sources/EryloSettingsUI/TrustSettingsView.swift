import EryloCore
import EryloTrust
import SwiftUI

public struct TrustSettingsView: View {
    private let model: TrustSettingsViewModel
    private let destinationChooser: any DiagnosticsDestinationChoosing

    @State private var isResetConfirmationPresented = false

    @MainActor
    public init(
        model: TrustSettingsViewModel,
        destinationChooser: any DiagnosticsDestinationChoosing = SystemDiagnosticsDestinationChooser()
    ) {
        self.model = model
        self.destinationChooser = destinationChooser
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                promiseCard
                moduleSection
                displaySection
                behaviorSection
                trustSection
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(EryloPalette.ink)
        .foregroundStyle(EryloPalette.cloud)
        .task {
            await model.load()
        }
        .confirmationDialog(
            "Reset Erylo to safe defaults?",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task { await model.resetToSafeDefaults() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All modules, login launch, diagnostic consent, and custom behavior will be turned off.")
        }
    }

    private var promiseCard: some View {
        sectionCard {
            HStack(alignment: .top, spacing: 14) {
                Circle()
                    .fill(EryloPalette.mint)
                    .frame(width: 10, height: 10)
                    .padding(.top, 7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Glance. Act. Disappear.")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("Erylo is a quiet, local-first activity layer. Utility modules stay off unless a build connects them and you explicitly enable them.")
                        .foregroundStyle(EryloPalette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.settings.onboardingCompleted {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(TrustAccessibilityCopy.onboardingSurfaceExplanation)
                            Text(TrustAccessibilityCopy.onboardingInteractionExplanation)
                            Text(TrustAccessibilityCopy.onboardingSafetyExplanation)
                            Text(TrustAccessibilityCopy.onboardingControlExplanation)
                        }
                        .font(.callout)
                        .foregroundStyle(EryloPalette.mist)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(TrustAccessibilityCopy.onboardingLabel)
                        .accessibilityHint(TrustAccessibilityCopy.onboardingHint)

                        Button("Continue with safe defaults") {
                            Task { await model.completeOnboarding() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(EryloPalette.mint)
                        .foregroundStyle(EryloPalette.ink)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TrustAccessibilityCopy.productPromiseLabel)
        .accessibilityHint(TrustAccessibilityCopy.productPromiseHint)
    }

    private var moduleSection: some View {
        sectionCard(
            title: "Modules",
            subtitle: model.availableModules.isEmpty
                ? "Utilities are not connected in this build. These controls are visible for transparency, but cannot start providers, permission requests, sockets, timers, media automation, or network work."
                : "Off means stopped: no permission-dependent work, timers, or network activity."
        ) {
            VStack(spacing: 0) {
                ForEach(EryloModule.allCases, id: \.self) { module in
                    moduleRow(module)
                    if module != EryloModule.allCases.last {
                        Divider().overlay(EryloPalette.mist.opacity(0.2))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TrustAccessibilityCopy.moduleGroupLabel)
    }

    private func moduleRow(_ module: EryloModule) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.settings.modules[module] },
                set: { enabled in
                    Task { await model.setModuleEnabled(module, enabled: enabled) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(ModuleCopy.title(for: module))
                        .foregroundStyle(EryloPalette.cloud)
                    if let badge = moduleBadge(module) {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(EryloPalette.amber)
                    }
                }
                Text(ModuleCopy.explanation(for: module))
                    .font(.caption)
                    .foregroundStyle(EryloPalette.mist)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.isModuleAvailable(module) {
                    Text("Not connected in this build; this utility is not running.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EryloPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(EryloPalette.mint)
        .disabled(!model.isModuleAvailable(module))
        .padding(.vertical, 10)
        .accessibilityLabel(
            model.isModuleAvailable(module)
                ? TrustAccessibilityCopy.moduleLabel(module)
                : TrustAccessibilityCopy.unavailableModuleLabel(module)
        )
        .accessibilityHint(
            model.isModuleAvailable(module)
                ? TrustAccessibilityCopy.moduleHint(module)
                : TrustAccessibilityCopy.unavailableModuleHint(module)
        )
    }

    private var displaySection: some View {
        sectionCard(title: "Displays", subtitle: "Choose where the activity surface may appear. Missing displays fall back safely.") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Show the Erylo surface",
                    isOn: Binding(
                        get: { model.settings.displays.isEnabled },
                        set: { enabled in Task { await model.setDisplaySurfaceEnabled(enabled) } }
                    )
                )
                .toggleStyle(.switch)
                .tint(EryloPalette.mint)

                if model.displayChoices.isEmpty {
                    Text("Display choices will appear when the host app supplies the current display list. Automatic selection remains available.")
                        .font(.caption)
                        .foregroundStyle(EryloPalette.mist)
                } else {
                    Toggle(
                        "Use all available displays",
                        isOn: Binding(
                            get: { model.settings.displays.enabledDisplayIDs == nil },
                            set: { useAll in
                                Task { await model.setUseAllAvailableDisplays(useAll) }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .tint(EryloPalette.sky)

                    ForEach(model.displayChoices) { display in
                        Toggle(
                            display.name,
                            isOn: Binding(
                                get: { model.isDisplayEnabled(display.identity) },
                                set: { enabled in
                                    Task { await model.setDisplayEnabled(display.identity, enabled: enabled) }
                                }
                            )
                        )
                        .disabled(model.settings.displays.enabledDisplayIDs == nil)
                    }

                    Picker(
                        "Shortcut display",
                        selection: Binding<DisplayIdentity?>(
                            get: {
                                model.settings.displays.selectedDisplayID.map(DisplayIdentity.init(rawValue:))
                            },
                            set: { identity in Task { await model.selectDisplay(identity) } }
                        )
                    ) {
                        Text("Automatic").tag(DisplayIdentity?.none)
                        ForEach(model.displayChoices) { display in
                            Text(display.name).tag(Optional(display.identity))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TrustAccessibilityCopy.displayGroupLabel)
    }

    private var behaviorSection: some View {
        sectionCard(
            title: "Behavior",
            subtitle: model.supportsMotionPreference && model.supportsFullscreenPreference
                ? nil
                : "Unavailable controls are not connected to the current surface and do not claim to change it."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(
                    TrustAccessibilityCopy.motionPickerLabel,
                    selection: Binding(
                        get: { model.settings.motion },
                        set: { value in Task { await model.setMotion(value) } }
                    )
                ) {
                    Text("Follow System Settings").tag(MotionPreference.systemDefault)
                    Text("Reduce motion").tag(MotionPreference.reduce)
                }
                .pickerStyle(.segmented)
                .disabled(!model.supportsMotionPreference)
                .accessibilityHint(
                    model.supportsMotionPreference
                        ? "System default follows the macOS Reduce Motion setting."
                        : TrustAccessibilityCopy.unavailableMotionHint
                )

                Picker(
                    TrustAccessibilityCopy.fullscreenPickerLabel,
                    selection: Binding(
                        get: { model.settings.fullscreenBehavior },
                        set: { value in Task { await model.setFullscreen(value) } }
                    )
                ) {
                    Text("Hide in fullscreen").tag(FullscreenBehavior.hide)
                    Text("Remain available").tag(FullscreenBehavior.remainAvailable)
                }
                .pickerStyle(.segmented)
                .disabled(!model.supportsFullscreenPreference)
                .accessibilityHint(
                    model.supportsFullscreenPreference
                        ? "Controls whether the activity surface remains available with a fullscreen app."
                        : TrustAccessibilityCopy.unavailableFullscreenHint
                )
            }
        }
    }

    private var trustSection: some View {
        sectionCard(title: "Trust and support", subtitle: "Your settings and diagnostics stay on this Mac unless you export a file.") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(
                    TrustAccessibilityCopy.launchAtLoginLabel,
                    isOn: Binding(
                        get: { model.settings.launchAtLogin },
                        set: { enabled in Task { await model.setLaunchAtLoginEnabled(enabled) } }
                    )
                )
                .toggleStyle(.switch)
                .tint(EryloPalette.sky)
                .disabled(model.launchAtLogin.capability == .unavailable)
                .accessibilityHint(TrustAccessibilityCopy.launchAtLoginHint)

                Text(launchAtLoginStatus)
                    .font(.caption)
                    .foregroundStyle(launchAtLoginStatusColor)

                Divider().overlay(EryloPalette.mist.opacity(0.2))

                Toggle(
                    TrustAccessibilityCopy.diagnosticsConsentLabel,
                    isOn: Binding(
                        get: { model.settings.crashAndDiagnosticSharingConsent },
                        set: { consent in Task { await model.setCrashAndDiagnosticSharingConsent(consent) } }
                    )
                )
                .toggleStyle(.switch)
                .tint(EryloPalette.mint)
                .accessibilityHint(TrustAccessibilityCopy.diagnosticsConsentHint)

                Text("Consent is off by default. There is no analytics SDK, automatic upload, or persistent device identifier in the report.")
                    .font(.caption)
                    .foregroundStyle(EryloPalette.mist)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(TrustAccessibilityCopy.diagnosticsExportLabel) {
                        Task {
                            guard let destination = await destinationChooser.chooseDestination() else { return }
                            await model.exportDiagnostics(to: destination)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(EryloPalette.sky)
                    .accessibilityHint(TrustAccessibilityCopy.diagnosticsExportHint)

                    Button(TrustAccessibilityCopy.resetLabel, role: .destructive) {
                        isResetConfirmationPresented = true
                    }
                    .buttonStyle(.bordered)
                    .tint(EryloPalette.coral)
                    .accessibilityHint(TrustAccessibilityCopy.resetHint)
                }

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Applying settings change")
                }
                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusMessage.contains("could not") || statusMessage.contains("failed")
                            ? EryloPalette.coral
                            : EryloPalette.mist)
                        .accessibilityLabel("Settings status: \(statusMessage)")
                }
            }
        }
    }

    private var launchAtLoginStatus: String {
        switch model.launchAtLogin.registrationState {
        case .disabled: "Off in macOS Login Items."
        case .enabled: "Enabled in macOS Login Items."
        case .requiresApproval: "Waiting for approval in System Settings → Login Items."
        case .unavailable: "Unavailable outside a signed application bundle."
        }
    }

    private func moduleBadge(_ module: EryloModule) -> String? {
        if !model.isModuleAvailable(module) { return "NOT AVAILABLE" }
        if module.permissionRequirement != nil { return "ASKS WHEN ENABLED" }
        switch module {
        case .fileHold: return "ACCESS ON USE"
        case .localIntegrations: return "LOCAL ONLY"
        case .battery, .timer, .volume: return nil
        case .appleMusic, .spotify, .calendar: return nil
        }
    }

    private var launchAtLoginStatusColor: Color {
        switch model.launchAtLogin.registrationState {
        case .enabled: EryloPalette.mint
        case .requiresApproval: EryloPalette.amber
        case .disabled, .unavailable: EryloPalette.mist
        }
    }

    private func sectionCard<Content: View>(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(EryloPalette.cloud)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(EryloPalette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EryloPalette.graphite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(EryloPalette.mist.opacity(0.12), lineWidth: 1)
        }
    }
}
