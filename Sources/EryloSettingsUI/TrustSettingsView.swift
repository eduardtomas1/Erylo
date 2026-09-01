import AppKit
import EryloCore
import EryloTrust
import SwiftUI

public enum TrustSettingsPresentation {
    /// Only modules with a shipping Settings lifecycle belong in the visible module list.
    /// Other persisted module keys remain supported for decoding and library clients.
    public static let configurableModules: [EryloModule] = [.battery, .volume]
}

public struct TrustSettingsView: View {
    private let model: TrustSettingsViewModel
    private let destinationChooser: any DiagnosticsDestinationChoosing
    private let onStartFocusTimer: (@MainActor () -> Bool)?

    @State private var isResetConfirmationPresented = false
    @State private var focusTimerStartFailed = false

    @MainActor
    public init(
        model: TrustSettingsViewModel,
        destinationChooser: any DiagnosticsDestinationChoosing = SystemDiagnosticsDestinationChooser(),
        onStartFocusTimer: (@MainActor () -> Bool)? = nil
    ) {
        self.model = model
        self.destinationChooser = destinationChooser
        self.onStartFocusTimer = onStartFocusTimer
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if model.settings.onboardingCompleted {
                Form {
                    activitySection
                    displaySection
                    if model.supportsMotionPreference || model.supportsFullscreenPreference {
                        behaviorSection
                    }
                    generalSection
                    supportSection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 720)
            } else {
                onboardingView
            }
        }
        .task {
            await model.load()
        }
        .confirmationDialog(
            "Reset Erylo settings?",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Reset Settings", role: .destructive) {
                Task { await model.resetToSafeDefaults() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Battery, Volume, display choices, launch at login, and other saved preferences will return to their defaults. A running Focus Timer is not affected.")
        }
    }

    private var onboardingView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            EryloSignalMark()
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 48, height: 28)
                .accessibilityHidden(true)

            Text("Meet Erylo")
                .font(.system(size: 30, weight: .semibold))
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)

            Text(TrustAccessibilityCopy.onboardingSurfaceExplanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
                .accessibilityLabel(TrustAccessibilityCopy.onboardingLabel)
                .accessibilityHint(TrustAccessibilityCopy.onboardingHint)

            VStack(alignment: .leading, spacing: 18) {
                onboardingFeature(
                    symbol: "timer",
                    title: "Focus on demand",
                    detail: "Start a 15, 25, or 50 minute timer from the menu bar."
                )
                onboardingFeature(
                    symbol: "waveform.path",
                    title: "Only useful signals",
                    detail: "Battery and Volume appear briefly only when you enable them."
                )
                onboardingFeature(
                    symbol: "hand.raised.fill",
                    title: "Private by design",
                    detail: "No account, no telemetry, and no permission request at launch."
                )
            }
            .frame(maxWidth: 430)
            .padding(.top, 30)

            if let failure = model.onboardingActionFailure {
                Label(failure, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
                    .accessibilityLabel("Focus Timer start failed. \(failure)")
            }

            Spacer(minLength: 28)

            Button("Continue") {
                Task { await model.completeOnboarding() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("You can change every utility later in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 9)

            Spacer(minLength: 28)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 44)
        .accessibilityElement(children: .contain)
    }

    private func onboardingFeature(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activitySection: some View {
        Section {
            focusTimerRow

            ForEach(configurableModules, id: \.self) { module in
                moduleToggle(module)
            }
        } header: {
            Text("Utilities")
        } footer: {
            Text("Disabled utilities stop completely.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TrustAccessibilityCopy.moduleGroupLabel)
    }

    private var configurableModules: [EryloModule] {
        TrustSettingsPresentation.configurableModules.filter(model.isModuleAvailable)
    }

    private var focusTimerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                settingIcon("timer")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Focus Timer")
                    Text("Start here, or choose another duration from the Erylo menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if let onStartFocusTimer {
                    Button("Start 25 min") {
                        focusTimerStartFailed = !onStartFocusTimer()
                    }
                    .accessibilityHint("Starts a 25 minute Focus Timer. A running timer is replaced.")
                } else {
                    Text("Menu bar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if focusTimerStartFailed {
                Label("The timer couldn’t start.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TrustAccessibilityCopy.focusTimerLabel)
        .accessibilityHint(TrustAccessibilityCopy.focusTimerHint)
    }

    private func moduleToggle(_ module: EryloModule) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.settings.modules[module] },
                set: { enabled in
                    Task { await model.setModuleEnabled(module, enabled: enabled) }
                }
            )
        ) {
            HStack(alignment: .top, spacing: 12) {
                settingIcon(moduleIcon(module))

                VStack(alignment: .leading, spacing: 3) {
                    Text(ModuleCopy.title(for: module))
                    Text(ModuleCopy.explanation(for: module))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let feedback = model.moduleFeedback[module] {
                        Text(feedback)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(
                                model.moduleFeedbackIsFailure(for: module)
                                    ? Color.red
                                    : Color.secondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("\(ModuleCopy.title(for: module)) status: \(feedback)")
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 3)
        .accessibilityLabel(TrustAccessibilityCopy.moduleLabel(module))
        .accessibilityHint(TrustAccessibilityCopy.moduleHint(module))
    }

    private var displaySection: some View {
        Section {
            Toggle(
                "Show Erylo",
                isOn: Binding(
                    get: { model.settings.displays.isEnabled },
                    set: { enabled in Task { await model.setDisplaySurfaceEnabled(enabled) } }
                )
            )
            .toggleStyle(.switch)

            if model.settings.displays.isEnabled {
                Picker(
                    TrustAccessibilityCopy.displayScopePickerLabel,
                    selection: Binding(
                        get: { model.settings.displays.surfaceScope },
                        set: { scope in Task { await model.setDisplayScope(scope) } }
                    )
                ) {
                    Text("Automatic — Main Display").tag(DisplaySurfaceScope.automatic)
                    Text("All Displays").tag(DisplaySurfaceScope.allAvailable)
                    Text("Choose Displays").tag(DisplaySurfaceScope.custom)
                }
                .pickerStyle(.menu)
                .accessibilityHint(TrustAccessibilityCopy.displayScopePickerHint)

                if model.displayChoices.isEmpty {
                    Text("No display is currently available. Erylo will wait for one to connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if model.settings.displays.surfaceScope == .custom {
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
                        }
                    }
                }

                Picker(
                    TrustAccessibilityCopy.preferredDisplayPickerLabel,
                    selection: Binding<DisplayUUID?>(
                        get: { model.settings.displays.preferredDisplayUUID },
                        set: { identity in Task { await model.selectDisplay(identity) } }
                    )
                ) {
                    Text("Automatic").tag(DisplayUUID?.none)
                    if let unavailable = model.unavailablePreferredDisplayUUID {
                        Text("Previously selected — Not Connected")
                            .tag(Optional(unavailable))
                            .disabled(true)
                    }
                    ForEach(model.preferredDisplayChoices) { display in
                        Text(display.name).tag(Optional(display.identity))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityHint(TrustAccessibilityCopy.preferredDisplayPickerHint)

                if model.unavailablePreferredDisplayUUID != nil {
                    Label(
                        "The saved menu and shortcut display is unavailable. Erylo will not target another display.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Displays")
        } footer: {
            Text("Automatic uses one main display. All Displays is opt-in. The menu and shortcut target can only be an enabled, connected display.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TrustAccessibilityCopy.displayGroupLabel)
    }

    private var behaviorSection: some View {
        Section("Behavior") {
            if model.supportsMotionPreference {
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
                .pickerStyle(.menu)
                .accessibilityHint("System default follows the macOS Reduce Motion setting.")
            }

            if model.supportsFullscreenPreference {
                Picker(
                    TrustAccessibilityCopy.fullscreenPickerLabel,
                    selection: Binding(
                        get: { model.settings.fullscreenBehavior },
                        set: { value in Task { await model.setFullscreen(value) } }
                    )
                ) {
                    Text("Hide Erylo").tag(FullscreenBehavior.hide)
                    Text("Remain available").tag(FullscreenBehavior.remainAvailable)
                }
                .pickerStyle(.menu)
                .accessibilityHint(TrustAccessibilityCopy.fullscreenPickerHint)
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle(
                TrustAccessibilityCopy.launchAtLoginLabel,
                isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { enabled in Task { await model.setLaunchAtLoginEnabled(enabled) } }
                )
            )
            .toggleStyle(.switch)
            .disabled(model.launchAtLogin.capability == .unavailable)
            .accessibilityHint(TrustAccessibilityCopy.launchAtLoginHint)

            HStack(spacing: 7) {
                Image(systemName: launchAtLoginStatusSymbol)
                    .foregroundStyle(launchAtLoginStatusColor)
                    .accessibilityHidden(true)
                Text(launchAtLoginStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var supportSection: some View {
        Section {
            LabeledContent {
                Button {
                    Task {
                        guard let destination = await destinationChooser.chooseDestination() else { return }
                        await model.exportDiagnostics(to: destination)
                    }
                } label: { Text(TrustAccessibilityCopy.diagnosticsExportLabel) }
                .accessibilityHint(TrustAccessibilityCopy.diagnosticsExportHint)
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            LabeledContent {
                Button(TrustAccessibilityCopy.resetLabel, role: .destructive) {
                    isResetConfirmationPresented = true
                }
                .accessibilityHint(TrustAccessibilityCopy.resetHint)
            } label: {
                Label("Settings", systemImage: "arrow.counterclockwise")
            }

            if model.isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying changes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Applying settings change")
            }

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusMessageIsFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Settings status: \(statusMessage)")
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Diagnostics are redacted and saved only when you choose a file. Erylo has no analytics or automatic upload.")
        }
    }

    private func settingIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .symbolRenderingMode(.hierarchical)
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    private func moduleIcon(_ module: EryloModule) -> String {
        switch module {
        case .battery: "battery.100percent"
        case .volume: "speaker.wave.2.fill"
        case .timer: "timer"
        case .fileHold: "folder.fill"
        case .appleMusic, .spotify: "music.note"
        case .calendar: "calendar"
        case .localIntegrations: "point.3.connected.trianglepath.dotted"
        }
    }

    private var launchAtLoginStatus: String {
        switch model.launchAtLogin.registrationState {
        case .disabled: "Off in macOS Login Items."
        case .enabled: "Enabled in macOS Login Items."
        case .requiresApproval: "Waiting for approval in System Settings → Login Items."
        case .unavailable: "Available when Erylo is running as an installed app."
        }
    }

    private var launchAtLoginStatusSymbol: String {
        switch model.launchAtLogin.registrationState {
        case .enabled: "checkmark.circle.fill"
        case .requiresApproval: "exclamationmark.circle.fill"
        case .disabled: "circle"
        case .unavailable: "minus.circle"
        }
    }

    private var launchAtLoginStatusColor: Color {
        switch model.launchAtLogin.registrationState {
        case .enabled: .green
        case .requiresApproval: .orange
        case .disabled, .unavailable: .secondary
        }
    }

    private var statusMessageIsFailure: Bool {
        guard let statusMessage = model.statusMessage else { return false }
        return statusMessage.localizedCaseInsensitiveContains("could not")
            || statusMessage.localizedCaseInsensitiveContains("failed")
            || statusMessage.localizedCaseInsensitiveContains("needs attention")
    }
}
