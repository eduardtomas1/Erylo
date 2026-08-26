import EryloCore

/// The AppKit implementation is isolated outside the domain and can be replaced in tests.
@MainActor
public protocol EnabledDisplayProviding: AnyObject {
    func enabledDisplays() -> [DisplaySnapshot]
}
