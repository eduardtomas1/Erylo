public enum DisplaySurfaceScope: String, Codable, Equatable, Sendable {
    /// One deterministic display: the current main display when available.
    case automatic
    /// Every available non-mirrored display. This is always an explicit opt-in.
    case allAvailable = "all-available"
    /// Only the stable display UUIDs in `enabledDisplayUUIDs`.
    case custom
}

public struct DisplayPolicy: Equatable, Sendable {
    public var surfaceScope: DisplaySurfaceScope
    /// Used only by custom scope. An empty set enables none. Explicit stable UUIDs
    /// that are not currently available remain unavailable; Erylo never substitutes
    /// a different physical display.
    public var enabledDisplayUUIDs: Set<DisplayUUID>?
    /// Stable preferred target for one-at-a-time menu and shortcut interactions.
    /// `nil` chooses the main enabled display automatically. An explicit UUID that
    /// is unavailable or disabled resolves to no target rather than the wrong screen.
    public var preferredDisplayUUID: DisplayUUID?
    /// Public AppKit fullscreen-Space participation. `false` is the safe default;
    /// `true` maps only to `NSWindow.CollectionBehavior.fullScreenAuxiliary`.
    public var allowsFullscreenAuxiliary: Bool
    public var isEnabled: Bool

    public init(
        isEnabled: Bool = true,
        surfaceScope: DisplaySurfaceScope = .automatic,
        enabledDisplayUUIDs: Set<DisplayUUID>? = nil,
        preferredDisplayUUID: DisplayUUID? = nil,
        allowsFullscreenAuxiliary: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.surfaceScope = surfaceScope
        self.enabledDisplayUUIDs = enabledDisplayUUIDs
        self.preferredDisplayUUID = preferredDisplayUUID
        self.allowsFullscreenAuxiliary = allowsFullscreenAuxiliary
    }

    public static let safeDefault = DisplayPolicy()

    public func resolve(_ availableDisplays: [DisplaySnapshot]) -> DisplayResolution {
        guard isEnabled else { return DisplayResolution(enabledDisplays: [], selectedDisplayIdentity: nil) }

        var seen: Set<DisplayUUID> = []
        let eligibleDisplays = availableDisplays.filter { display in
            !display.isMirrored && seen.insert(display.uuid).inserted
        }
        let enabledDisplays: [DisplaySnapshot] = switch surfaceScope {
        case .automatic:
            Self.stableFallback(in: eligibleDisplays).map { [$0] } ?? []
        case .allAvailable:
            eligibleDisplays
        case .custom:
            eligibleDisplays.filter { enabledDisplayUUIDs?.contains($0.uuid) == true }
        }

        let selectedDisplayIdentity: DisplayIdentity?
        if let preferredDisplayUUID {
            selectedDisplayIdentity = enabledDisplays.first {
                $0.uuid == preferredDisplayUUID
            }?.identity
        } else {
            selectedDisplayIdentity = enabledDisplays.first(where: \.isMain)?.identity
                ?? Self.stableFallback(in: enabledDisplays)?.identity
        }

        return DisplayResolution(
            enabledDisplays: enabledDisplays,
            selectedDisplayIdentity: selectedDisplayIdentity
        )
    }

    private static func stableFallback(
        in displays: [DisplaySnapshot]
    ) -> DisplaySnapshot? {
        displays.first(where: \.isMain) ?? displays.min {
            if $0.uuid == $1.uuid {
                return $0.identity.rawValue < $1.identity.rawValue
            }
            return $0.uuid < $1.uuid
        }
    }
}

public struct DisplayResolution: Equatable, Sendable {
    public let enabledDisplays: [DisplaySnapshot]
    public let selectedDisplayIdentity: DisplayIdentity?

    public init(
        enabledDisplays: [DisplaySnapshot],
        selectedDisplayIdentity: DisplayIdentity?
    ) {
        self.enabledDisplays = enabledDisplays
        self.selectedDisplayIdentity = selectedDisplayIdentity
    }
}
