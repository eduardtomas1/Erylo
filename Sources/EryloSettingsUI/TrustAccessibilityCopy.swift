import EryloTrust

public enum TrustAccessibilityCopy {
    public static let productPromiseLabel = "Erylo product promise"
    public static let productPromiseHint = "Explains what Erylo does and how it protects focus and privacy."
    public static let onboardingLabel = "How to use Erylo"
    public static let onboardingHint = "Explains the top-edge surface, deliberate interaction, safe defaults, settings, quitting, and relaunching."
    public static let onboardingSurfaceExplanation = "Erylo lives in a small surface at the top edge of your display, around the camera notch when one is present. It stays passive until you deliberately use it."
    public static let onboardingInteractionExplanation = "Click the visible Erylo surface, or press Control–Option–Command–E, when you deliberately want to interact. The passive panel does not become a normal app window."
    public static let onboardingSafetyExplanation = "Browsing Settings cannot start a Focus Timer, request permissions, open sockets or files, control media, or perform network work. Battery and Volume start only when you turn on their switches."
    public static let onboardingControlExplanation = "Use the Erylo menu bar item to start or cancel a Focus Timer, reopen Settings to control Battery and Volume, or quit. After quitting, launch Erylo again the same way you opened it."
    public static let moduleGroupLabel = "Activity modules"
    public static let displayGroupLabel = "Display preferences"
    public static let motionPickerLabel = "Motion behavior"
    public static let fullscreenPickerLabel = "Fullscreen behavior"
    public static let launchAtLoginLabel = "Launch Erylo at login"
    public static let launchAtLoginHint = "Uses the macOS Login Items service. Erylo reports when approval is still required."
    public static let diagnosticsConsentLabel = "Allow crash and diagnostic sharing"
    public static let diagnosticsConsentHint = "Records consent only. This build has no analytics SDK or automatic report upload."
    public static let diagnosticsExportLabel = "Export diagnostics"
    public static let diagnosticsExportHint = "Asks where to save a bounded, redacted JSON report. Nothing is uploaded."
    public static let resetLabel = "Reset to safe defaults"
    public static let resetHint = "Turns off modules, login launch, diagnostic consent, and custom behavior."
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
            productPromiseLabel,
            onboardingLabel,
            moduleGroupLabel,
            displayGroupLabel,
            motionPickerLabel,
            fullscreenPickerLabel,
            launchAtLoginLabel,
            diagnosticsConsentLabel,
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
