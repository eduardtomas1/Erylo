import EryloTrust

public enum TrustAccessibilityCopy {
    public static let productPromiseLabel = "Erylo product promise"
    public static let productPromiseHint = "Explains what Erylo does and how it protects focus and privacy."
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

    public static var fixedLabels: [String] {
        [
            productPromiseLabel,
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
            "Keeps files available for a short handoff. Access comes only from files you drop or choose."
        case .appleMusic:
            "Shows and controls playback. macOS may ask to control Music when you enable it."
        case .spotify:
            "Shows and controls playback. macOS may ask to control Spotify when you enable it."
        case .battery:
            "Shows charging and battery changes from local system events."
        case .timer:
            "Shows timers you start in Erylo."
        case .calendar:
            "Reads the next meeting only after you grant Calendar access."
        case .volume:
            "Shows local volume changes without a network connection."
        case .localIntegrations:
            "Runs a validated local listener only while enabled. It requests no system permission."
        }
    }
}
