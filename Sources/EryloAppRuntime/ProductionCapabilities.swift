import EryloTrust

package enum ProductionUtility: String, CaseIterable, Sendable {
    case appleMusic = "apple-music"
    case battery
    case calendar
    case fileHold = "file-hold"
    case focusTimer = "focus-timer"
    case localIntegrations = "local-integrations"
    case spotify
    case volume

    fileprivate var settingsModule: EryloModule? {
        switch self {
        case .appleMusic: .appleMusic
        case .battery: .battery
        case .calendar: .calendar
        case .fileHold: .fileHold
        case .focusTimer: nil
        case .localIntegrations: .localIntegrations
        case .spotify: .spotify
        case .volume: .volume
        }
    }
}

package enum ProductionCapabilities {
    // This one typed declaration is consumed by production composition and the
    // release validator. Keep it on one line so ambiguous edits fail closed.
    package static let mountedUtilities: Set<ProductionUtility> = [.battery, .focusTimer, .volume]

    package static func mounts(_ utility: ProductionUtility) -> Bool {
        mountedUtilities.contains(utility)
    }

    package static var settingsModules: Set<EryloModule> {
        Set(mountedUtilities.compactMap(\.settingsModule))
    }
}
