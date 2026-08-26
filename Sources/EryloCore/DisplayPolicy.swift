public struct DisplayPolicy: Equatable, Sendable {
    /// A nil set means every available non-mirrored display is enabled.
    public var enabledDisplayIdentities: Set<DisplayIdentity>?
    /// The preferred target for one-at-a-time interactions such as the shortcut.
    public var selectedDisplayIdentity: DisplayIdentity?
    public var isEnabled: Bool

    public init(
        isEnabled: Bool = true,
        enabledDisplayIdentities: Set<DisplayIdentity>? = nil,
        selectedDisplayIdentity: DisplayIdentity? = nil
    ) {
        self.isEnabled = isEnabled
        self.enabledDisplayIdentities = enabledDisplayIdentities
        self.selectedDisplayIdentity = selectedDisplayIdentity
    }

    public static let safeDefault = DisplayPolicy()

    public func resolve(_ availableDisplays: [DisplaySnapshot]) -> DisplayResolution {
        guard isEnabled else { return DisplayResolution(enabledDisplays: [], selectedDisplayIdentity: nil) }

        var seen: Set<DisplayIdentity> = []
        let enabledDisplays = availableDisplays.filter { display in
            guard !display.isMirrored, seen.insert(display.identity).inserted else { return false }
            return enabledDisplayIdentities?.contains(display.identity) ?? true
        }

        let selectedDisplayIdentity = selectedDisplayIdentity.flatMap { preferredIdentity in
            enabledDisplays.first { $0.identity == preferredIdentity }?.identity
        } ?? enabledDisplays.first(where: \.isMain)?.identity
            ?? enabledDisplays.first?.identity

        return DisplayResolution(
            enabledDisplays: enabledDisplays,
            selectedDisplayIdentity: selectedDisplayIdentity
        )
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
