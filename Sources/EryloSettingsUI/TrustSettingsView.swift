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

            if model.recoveryReport != nil {
                settingsRecoveryView
            } else if model.settings.onboardingCompleted {
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

    private var settingsRecoveryView: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    Text("Saved Settings Need Attention")
                        .font(.system(size: 26, weight: .semibold))
                        .padding(.top, 18)
                        .accessibilityAddTraits(.isHeader)

                    Text("Erylo opened with safe defaults because the saved settings could not be read safely. Your existing saved data has not been changed.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    Label(
                        "Reset is the only action that can replace the saved value.",
                        systemImage: "lock.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 22)

                    if let statusMessage = model.statusMessage {
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(statusMessageIsFailure ? Color.red : Color.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 18)
                            .accessibilityLabel("Settings status: \(statusMessage)")
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                guard let destination = await destinationChooser.chooseDestination() else {
                                    return
                                }
                                await model.exportDiagnostics(to: destination)
                            }
                        } label: {
                            Text("Export Diagnostics…")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint(TrustAccessibilityCopy.diagnosticsExportHint)

                        Button("Reset Settings…", role: .destructive) {
                            isResetConfirmationPresented = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Replaces the unreadable saved value with safe defaults after confirmation.")
                    }
                    .controlSize(.large)
                    .padding(.top, 26)
                    .disabled(model.isWorking)

                    if model.isWorking {
                        ProgressView("Working…")
                            .controlSize(.small)
                            .padding(.top, 16)
                    }

                    Spacer(minLength: 40)
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 44)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var onboardingView: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    EryloSignalMark()
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 48, height: 28)
                        .accessibilityHidden(true)

                    Text("Your focus, at the top edge")
                        .font(.system(size: 30, weight: .semibold))
                        .padding(.top, 16)
                        .accessibilityAddTraits(.isHeader)

                    Text(TrustAccessibilityCopy.onboardingSurfaceExplanation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)

                    OnboardingSurfacePreview()
                        .frame(maxWidth: 440)
                        .padding(.top, 24)

                    HStack(alignment: .top, spacing: 24) {
                        onboardingPromise(
                            symbol: "cursorarrow",
                            title: "Stays out of the way",
                            detail: "Hover never activates your app or steals focus."
                        )
                        onboardingPromise(
                            symbol: "bolt.slash",
                            title: "Sleeps when idle",
                            detail: "No polling or permanent animation loop."
                        )
                        onboardingPromise(
                            symbol: "lock",
                            title: "Local by design",
                            detail: "No account, analytics, or automatic upload."
                        )
                    }
                    .frame(maxWidth: 500)
                    .padding(.top, 24)

                    if let failure = model.onboardingActionFailure {
                        Label(failure, systemImage: "exclamationmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 20)
                            .accessibilityLabel("Setup error. \(failure)")
                    }

                    Spacer(minLength: 28)

                    HStack(spacing: 12) {
                        if let onStartFocusTimer {
                            Button {
                                Task {
                                    _ = await model.startFocusTimerAndCompleteOnboarding(
                                        using: onStartFocusTimer
                                    )
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "timer")
                                        .accessibilityHidden(true)
                                    Text("Start 25-Minute Focus")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityHint("Starts a 25 minute Focus Timer and finishes setup. No permission is requested.")

                            Button("Continue to Settings") {
                                Task { await model.completeOnboarding() }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Continue to Settings") {
                                Task { await model.completeOnboarding() }
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .controlSize(.large)
                    .disabled(model.isWorking)

                    Text("Battery and Volume stay off until you enable them in Settings.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 9)

                    Spacer(minLength: 28)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 44)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func onboardingPromise(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .frame(height: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 3)
        .accessibilityLabel(TrustAccessibilityCopy.moduleLabel(module))
        .accessibilityValue(model.moduleAccessibilityValue(for: module))
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
            || statusMessage.localizedCaseInsensitiveContains("must be reset")
    }
}

/// A truthful first-run product moment: an illustrative compact signal using
/// the shipping timer color and top-edge hierarchy, without fake controls or
/// an always-running animation.
private struct OnboardingSurfacePreview: View {
    private static let focusTint = Color(
        red: 255 / 255,
        green: 180 / 255,
        blue: 84 / 255
    )

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    OnboardingTopEdgeSurfaceShape()
                        .fill(Color.black)

                    HStack(spacing: 0) {
                        Image(systemName: "timer")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Self.focusTint)
                            .frame(width: 66)
                            .accessibilityHidden(true)

                        Spacer(minLength: 142)

                        Text("24:59")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 66)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 43)

                    HStack(spacing: 0) {
                        Capsule(style: .continuous)
                            .fill(Self.focusTint)
                            .frame(width: 86, height: 2)
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 108, height: 2)
                    }
                    .padding(.bottom, 1)
                }
                .frame(width: 330, height: 44)

                Spacer(minLength: 22)

                Text("Focus stays visible. Your work stays frontmost.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text("Control-Command-E reveals the controls only when you ask.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Spacer(minLength: 20)
            }
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: Focus Timer, 24 minutes 59 seconds remaining. Control-Command-E reveals controls.")
    }
}

/// A preview of the shipping top-edge relationship, not a floating card. The
/// flat top is attached to the simulated display edge; only the lower corners
/// soften into the screen.
private struct OnboardingTopEdgeSurfaceShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(17, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
