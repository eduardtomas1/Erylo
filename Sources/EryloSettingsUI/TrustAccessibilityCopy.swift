import EryloTrust

public enum TrustAccessibilityCopy {
    // Retained for clients compiled against the original contained settings UI.
    public static let productPromiseLabel = "Erylo product promise"
    public static let productPromiseHint = "Explains what Erylo does and how it protects focus and privacy."
    public static let onboardingLabel = "Erylo introduction"
    public static let onboardingHint = "Summarizes the quiet top-edge signal surface."
    @available(*, deprecated, message: "The shipping first-run screen no longer starts a timer.")
    public static let onboardingStartFocusHint = "Starts a 25 minute Focus Timer and finishes setup only when the timer is accepted."
    public static let onboardingSurfaceExplanation = "A quiet signal surface at the top of your display, visible only when something deserves your attention."
    public static let onboardingControlExplanation = "Start Focus Timer from the menu bar. Battery and Volume stay off until you enable them in Settings."

    // These longer descriptions remain available to source clients but are no longer repeated
    // in the first-run screen.
    public static let onboardingInteractionExplanation = "Activities with useful secondary detail can preview on hover. Clicking an actionable surface or using the Erylo keyboard shortcut expands it."
    public static let onboardingSafetyExplanation = "Browsing Settings starts no module and requests no permission."
    public static let moduleGroupLabel = "Utilities"
    public static let focusTimerLabel = "Focus Timer"
    public static let focusTimerHint = "Start a 25 minute timer here, or choose another duration from the Erylo menu."
    public static let displayGroupLabel = "Display preferences"
    public static let displayScopePickerLabel = "Surface displays"
    public static let preferredDisplayPickerLabel = "Menu and shortcut display"
    public static let displayScopePickerHint = "Automatic uses one main display. All Displays is an explicit opt-in."
    public static let preferredDisplayPickerHint = "Targets only menu and keyboard shortcut actions, not passive activities."
    public static let motionPickerLabel = "Motion behavior"
    public static let fullscreenPickerLabel = "Fullscreen apps"
    public static let fullscreenPickerHint = "Hide is the default. Remain available explicitly lets Erylo join fullscreen Spaces."
    public static let launchAtLoginLabel = "Launch Erylo at login"
    public static let launchAtLoginHint = "Uses the macOS Login Items service. Erylo reports when approval is still required."
    // The persisted consent field remains compatible, but no consent control is presented while
    // Erylo has no sharing transport.
    public static let diagnosticsConsentLabel = "Allow crash and diagnostic sharing"
    public static let diagnosticsConsentHint = "Records consent only. Erylo has no analytics SDK or report upload transport."
    public static let diagnosticsExportLabel = "Export Diagnostics…"
    public static let diagnosticsExportHint = "Asks where to save a bounded, redacted JSON report. Nothing is uploaded."
    public static let resetLabel = "Reset Settings…"
    public static let resetHint = "Restores Battery, Volume, displays, launch at login, and saved preferences. A running Focus Timer is not affected."
    public static let unavailableMotionHint = "Unavailable in this build. The control does not change the Erylo surface."
    public static let unavailableFullscreenHint = "Unavailable in this build. The control does not change fullscreen behavior."

    public static func moduleLabel(_ module: EryloModule) -> String {
        "Enable \(ModuleCopy.title(for: module))"
    }

    public static func moduleHint(_ module: EryloModule) -> String {
        if module.permissionRequirement != nil {
            return "Starts only after you enable it. Access is requested contextually and stops when disabled."
        }
        if module == .fileHold {
            return "No permission is requested on enable. Access comes only from files you drop or choose."
        }
        if module == .localIntegrations {
            return "No system permission is requested. The validated local listener runs only while enabled."
        }
        return "Starts only after you enable it and stops immediately when disabled."
    }

    public static func unavailableModuleLabel(_ module: EryloModule) -> String {
        "\(ModuleCopy.title(for: module)) unavailable"
    }

    public static func unavailableModuleHint(_ module: EryloModule) -> String {
        "\(ModuleCopy.title(for: module)) is not connected in this build and cannot start work."
    }

    public static var fixedLabels: [String] {
        [
            onboardingLabel,
            moduleGroupLabel,
            focusTimerLabel,
            displayGroupLabel,
            displayScopePickerLabel,
            preferredDisplayPickerLabel,
            motionPickerLabel,
            fullscreenPickerLabel,
            launchAtLoginLabel,
            diagnosticsExportLabel,
            resetLabel,
        ]
    }
}

public enum ModuleCopy {
    public static func title(for module: EryloModule) -> String {
        switch module {
        case .fileHold: "File Hold"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .battery: "Battery and charging"
        case .timer: "Timers"
        case .calendar: "Next meeting"
        case .volume: "Volume HUD"
        case .localIntegrations: "Local integrations"
        }
    }

    public static func explanation(for module: EryloModule) -> String {
        switch module {
        case .fileHold:
            "Future file handoff utility; not included in this build."
        case .appleMusic:
            "Future media utility; Apple Music support is not included in this build."
        case .spotify:
            "Future media utility; Spotify support is not included in this build."
        case .battery:
            "Shows charging and battery changes from local system events."
        case .timer:
            "Shows timers you start in Erylo."
        case .calendar:
            "Future meeting utility; Calendar access is not included in this build."
        case .volume:
            "Shows local volume changes without a network connection."
        case .localIntegrations:
            "Future extension utility; local integrations are not included in this build."
        }
    }
}
