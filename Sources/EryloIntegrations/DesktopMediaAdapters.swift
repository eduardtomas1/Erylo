import AppKit
import EryloCore
import Foundation

public protocol MediaApplicationStatusChecking: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
}

public struct SystemMediaApplicationStatus: MediaApplicationStatusChecking {
    public init() {}

    public func isRunning(bundleIdentifier: String) async -> Bool {
        await MainActor.run {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty
        }
    }
}

public enum MediaScriptRoute: String, Equatable, Sendable {
    case appleMusicSnapshot
    case appleMusicPlay
    case appleMusicPause
    case appleMusicNext
    case appleMusicPrevious
    case appleMusicSeek
    case appleMusicVolume
    case spotifySnapshot
    case spotifyPlay
    case spotifyPause
    case spotifyNext
    case spotifyPrevious
    case spotifySeek
    case spotifyVolume
}

/// The script body is selected internally from a closed route; values are only separate argv entries.
public struct MediaScriptRequest: Equatable, Sendable {
    public let route: MediaScriptRoute
    public let arguments: [String]

    public init(route: MediaScriptRoute, arguments: [String] = []) {
        self.route = route
        self.arguments = arguments
    }
}

public enum MediaScriptExecutionError: Error, Equatable, Sendable {
    case permissionDenied
    case applicationUnavailable
    case failed(exitCode: Int32?)
    case cancelled
}

public protocol MediaScriptExecuting: Sendable {
    func execute(_ request: MediaScriptRequest) async throws -> String
    func cancelAll() async
}

/// A killable, no-shell subprocess boundary around the documented `osascript` tool.
public actor ProcessMediaScriptExecutor: MediaScriptExecuting {
    private struct CompletedProcess: Sendable {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
    }

    private var processes: [UUID: Process] = [:]
    private var cancelledProcesses: Set<UUID> = []

    public init() {}

    public func execute(_ request: MediaScriptRequest) async throws -> String {
        try Task.checkCancellation()

        let identifier = UUID()
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", MediaAppleScripts.source(for: request.route), "--"]
            + request.arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        let completed: CompletedProcess
        do {
            completed = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { completedProcess in
                        continuation.resume(
                            returning: CompletedProcess(
                                status: completedProcess.terminationStatus,
                                standardOutput: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                                standardError: standardError.fileHandleForReading.readDataToEndOfFile()
                            )
                        )
                    }

                    do {
                        try process.run()
                        processes[identifier] = process
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                Task { [weak self] in
                    await self?.cancel(identifier)
                }
            }
        } catch is CancellationError {
            processes.removeValue(forKey: identifier)
            cancelledProcesses.remove(identifier)
            throw MediaScriptExecutionError.cancelled
        } catch {
            processes.removeValue(forKey: identifier)
            cancelledProcesses.remove(identifier)
            throw MediaScriptExecutionError.failed(exitCode: nil)
        }

        processes.removeValue(forKey: identifier)
        if cancelledProcesses.remove(identifier) != nil || Task.isCancelled {
            throw MediaScriptExecutionError.cancelled
        }

        guard completed.status == 0 else {
            let errorText = String(decoding: completed.standardError, as: UTF8.self)
            if errorText.contains("-1743")
                || errorText.localizedCaseInsensitiveContains("not authorized to send apple events") {
                throw MediaScriptExecutionError.permissionDenied
            }
            if errorText.contains("-600")
                || errorText.localizedCaseInsensitiveContains("isn't running") {
                throw MediaScriptExecutionError.applicationUnavailable
            }
            throw MediaScriptExecutionError.failed(exitCode: completed.status)
        }

        return String(decoding: completed.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    public func cancelAll() {
        for identifier in processes.keys {
            cancelledProcesses.insert(identifier)
        }
        for process in processes.values where process.isRunning {
            process.terminate()
        }
    }

    private func cancel(_ identifier: UUID) {
        cancelledProcesses.insert(identifier)
        if let process = processes[identifier], process.isRunning {
            process.terminate()
        }
    }
}

public actor AppleMusicDesktopAdapter: MediaAdapter {
    public let source = MediaSource.appleMusic
    private let implementation: ScriptedDesktopMediaAdapter

    public init(
        applicationStatus: any MediaApplicationStatusChecking = SystemMediaApplicationStatus(),
        scriptExecutor: any MediaScriptExecuting = ProcessMediaScriptExecutor()
    ) {
        implementation = ScriptedDesktopMediaAdapter(
            source: .appleMusic,
            applicationStatus: applicationStatus,
            scriptExecutor: scriptExecutor
        )
    }

    public func activate() async { await implementation.activate() }
    public func deactivate() async { await implementation.deactivate() }
    public func updates() async -> AsyncStream<MediaAdapterUpdate> { await implementation.updates() }
    public func refresh() async throws -> MediaAdapterUpdate { try await implementation.refresh() }
    public func perform(_ command: MediaCommand) async throws { try await implementation.perform(command) }
    public func cancelPendingWork() async { await implementation.cancelPendingWork() }
}

public actor SpotifyDesktopAdapter: MediaAdapter {
    public let source = MediaSource.spotify
    private let implementation: ScriptedDesktopMediaAdapter

    public init(
        applicationStatus: any MediaApplicationStatusChecking = SystemMediaApplicationStatus(),
        scriptExecutor: any MediaScriptExecuting = ProcessMediaScriptExecutor()
    ) {
        implementation = ScriptedDesktopMediaAdapter(
            source: .spotify,
            applicationStatus: applicationStatus,
            scriptExecutor: scriptExecutor
        )
    }

    public func activate() async { await implementation.activate() }
    public func deactivate() async { await implementation.deactivate() }
    public func updates() async -> AsyncStream<MediaAdapterUpdate> { await implementation.updates() }
    public func refresh() async throws -> MediaAdapterUpdate { try await implementation.refresh() }
    public func perform(_ command: MediaCommand) async throws { try await implementation.perform(command) }
    public func cancelPendingWork() async { await implementation.cancelPendingWork() }
}

private actor ScriptedDesktopMediaAdapter {
    let source: MediaSource
    private let applicationStatus: any MediaApplicationStatusChecking
    private let scriptExecutor: any MediaScriptExecuting
    private var isActive = false
    private var sequence: UInt64 = 0
    private var latestSnapshot: NowPlayingSnapshot?

    init(
        source: MediaSource,
        applicationStatus: any MediaApplicationStatusChecking,
        scriptExecutor: any MediaScriptExecuting
    ) {
        self.source = source
        self.applicationStatus = applicationStatus
        self.scriptExecutor = scriptExecutor
    }

    func activate() {
        isActive = true
    }

    func deactivate() async {
        isActive = false
        latestSnapshot = nil
        await scriptExecutor.cancelAll()
    }

    /// The public desktop scripting dictionaries expose no reliable change notification seam.
    func updates() -> AsyncStream<MediaAdapterUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func refresh() async throws -> MediaAdapterUpdate {
        guard isActive else { throw MediaError.disabled(source: source) }
        guard await applicationStatus.isRunning(bundleIdentifier: source.bundleIdentifier) else {
            latestSnapshot = nil
            return .sourceDisappeared(source: source, stamp: nextStamp())
        }

        do {
            let output = try await scriptExecutor.execute(snapshotRequest)
            let snapshot = try MediaSnapshotParser.parse(
                output,
                source: source,
                stamp: nextStamp()
            )
            latestSnapshot = snapshot
            return .snapshot(snapshot)
        } catch MediaScriptExecutionError.applicationUnavailable {
            latestSnapshot = nil
            return .sourceDisappeared(source: source, stamp: nextStamp())
        } catch {
            throw map(error)
        }
    }

    func perform(_ command: MediaCommand) async throws {
        guard isActive else { throw MediaError.disabled(source: source) }

        let snapshot: NowPlayingSnapshot
        if let latestSnapshot {
            snapshot = latestSnapshot
        } else {
            let update = try await refresh()
            guard case let .snapshot(refreshedSnapshot) = update else {
                throw MediaError.sourceUnavailable(source: source)
            }
            snapshot = refreshedSnapshot
        }

        let normalized = try command.normalized(for: snapshot)
        guard await applicationStatus.isRunning(bundleIdentifier: source.bundleIdentifier) else {
            latestSnapshot = nil
            throw MediaError.sourceUnavailable(source: source)
        }

        do {
            try await scriptExecutor.execute(commandRequest(for: normalized))
        } catch {
            throw map(error)
        }
    }

    func cancelPendingWork() async {
        await scriptExecutor.cancelAll()
    }

    private var snapshotRequest: MediaScriptRequest {
        MediaScriptRequest(
            route: source == .appleMusic ? .appleMusicSnapshot : .spotifySnapshot
        )
    }

    private func commandRequest(for command: MediaCommand) -> MediaScriptRequest {
        let route: MediaScriptRoute
        let arguments: [String]

        switch (source, command) {
        case (.appleMusic, .play):
            route = .appleMusicPlay
            arguments = []
        case (.appleMusic, .pause):
            route = .appleMusicPause
            arguments = []
        case (.appleMusic, .next):
            route = .appleMusicNext
            arguments = []
        case (.appleMusic, .previous):
            route = .appleMusicPrevious
            arguments = []
        case let (.appleMusic, .seek(position)):
            route = .appleMusicSeek
            arguments = [String(position)]
        case let (.appleMusic, .setVolume(volume)):
            route = .appleMusicVolume
            arguments = [String(Int((volume * 100).rounded()))]
        case (.spotify, .play):
            route = .spotifyPlay
            arguments = []
        case (.spotify, .pause):
            route = .spotifyPause
            arguments = []
        case (.spotify, .next):
            route = .spotifyNext
            arguments = []
        case (.spotify, .previous):
            route = .spotifyPrevious
            arguments = []
        case let (.spotify, .seek(position)):
            route = .spotifySeek
            arguments = [String(position)]
        case let (.spotify, .setVolume(volume)):
            route = .spotifyVolume
            arguments = [String(Int((volume * 100).rounded()))]
        }

        return MediaScriptRequest(route: route, arguments: arguments)
    }

    private func nextStamp() -> MediaUpdateStamp {
        sequence &+= 1
        return MediaUpdateStamp(sequence: sequence)
    }

    private func map(_ error: Error) -> MediaError {
        if let mediaError = error as? MediaError {
            return mediaError
        }
        guard let scriptError = error as? MediaScriptExecutionError else {
            return .automationFailed(source: source, exitCode: nil)
        }

        return switch scriptError {
        case .permissionDenied:
            .permissionDenied(source: source)
        case .applicationUnavailable:
            .sourceUnavailable(source: source)
        case let .failed(exitCode):
            .automationFailed(source: source, exitCode: exitCode)
        case .cancelled:
            .cancelled(source: source)
        }
    }
}

private enum MediaSnapshotParser {
    private static let expectedFieldCount = 10

    static func parse(
        _ output: String,
        source: MediaSource,
        stamp: MediaUpdateStamp
    ) throws -> NowPlayingSnapshot {
        let rawFields = output.split(separator: "\t", omittingEmptySubsequences: false)
        guard rawFields.count == expectedFieldCount else {
            throw MediaError.malformedResponse(source: source)
        }
        let fields = rawFields.map { unescape(String($0)) }

        let playbackState: MediaPlaybackState = switch fields[0].lowercased() {
        case "playing", "fast forwarding", "rewinding":
            .playing
        case "paused":
            .paused
        case "stopped":
            .stopped
        default:
            throw MediaError.malformedResponse(source: source)
        }

        let durationScale = source == .spotify ? 0.001 : 1.0
        let rawDuration = Double(fields[5]).map { $0 * durationScale }
        let duration = rawDuration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let rawPosition = Double(fields[6]) ?? 0
        let rawVolume = Double(fields[7]).map { $0 / 100 }
        guard rawPosition.isFinite, rawVolume?.isFinite != false else {
            throw MediaError.malformedResponse(source: source)
        }

        var capabilities: MediaCapabilities = [.transport, .volume]
        if let duration, duration > 0 {
            capabilities.insert(.seek)
        }

        let trackIdentifier = nilIfEmpty(fields[4])
        let artwork = artworkReference(
            kind: fields[8],
            value: fields[9],
            trackIdentifier: trackIdentifier,
            source: source
        )

        return try NowPlayingSnapshot(
            source: source,
            stamp: stamp,
            trackIdentifier: trackIdentifier,
            title: nilIfEmpty(fields[1]),
            artist: nilIfEmpty(fields[2]),
            album: nilIfEmpty(fields[3]),
            duration: duration,
            position: rawPosition,
            playbackState: playbackState,
            volume: rawVolume,
            capabilities: capabilities,
            artwork: artwork
        )
    }

    private static func artworkReference(
        kind: String,
        value: String,
        trackIdentifier: String?,
        source: MediaSource
    ) -> MediaArtworkReference? {
        guard !value.isEmpty else { return nil }
        let stableIdentifier = trackIdentifier ?? value
        guard let cacheKey = try? MediaArtworkCacheKey(
            "\(source.rawValue):\(stableIdentifier)"
        ) else { return nil }

        switch kind {
        case "sourceAsset":
            return try? MediaArtworkReference(
                sourceAssetIdentifier: value,
                cacheKey: cacheKey
            )
        case "remoteURL":
            guard let url = URL(string: value) else {
                return nil
            }
            return try? MediaArtworkReference(remoteURL: url, cacheKey: cacheKey)
        default:
            return nil
        }
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                switch character {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        if isEscaped {
            result.append("\\")
        }
        return result
    }
}

private enum MediaAppleScripts {
    static func source(for route: MediaScriptRoute) -> String {
        switch route {
        case .appleMusicSnapshot:
            appleMusicSnapshot
        case .spotifySnapshot:
            spotifySnapshot
        case .appleMusicPlay:
            guardedCommand(applicationID: "com.apple.Music", command: "play")
        case .appleMusicPause:
            guardedCommand(applicationID: "com.apple.Music", command: "pause")
        case .appleMusicNext:
            guardedCommand(applicationID: "com.apple.Music", command: "next track")
        case .appleMusicPrevious:
            guardedCommand(applicationID: "com.apple.Music", command: "previous track")
        case .spotifyPlay:
            guardedCommand(applicationID: "com.spotify.client", command: "play")
        case .spotifyPause:
            guardedCommand(applicationID: "com.spotify.client", command: "pause")
        case .spotifyNext:
            guardedCommand(applicationID: "com.spotify.client", command: "next track")
        case .spotifyPrevious:
            guardedCommand(applicationID: "com.spotify.client", command: "previous track")
        case .appleMusicSeek:
            guardedNumericCommand(
                applicationID: "com.apple.Music",
                variable: "player position",
                maximum: nil
            )
        case .spotifySeek:
            guardedNumericCommand(
                applicationID: "com.spotify.client",
                variable: "player position",
                maximum: nil
            )
        case .appleMusicVolume:
            guardedNumericCommand(
                applicationID: "com.apple.Music",
                variable: "sound volume",
                maximum: 100
            )
        case .spotifyVolume:
            guardedNumericCommand(
                applicationID: "com.spotify.client",
                variable: "sound volume",
                maximum: 100
            )
        }
    }

    private static func guardedCommand(applicationID: String, command: String) -> String {
        // Both values come exclusively from the closed route switch above.
        """
        if application id "\(applicationID)" is not running then error number -600
        tell application id "\(applicationID)" to \(command)
        """
    }

    private static func guardedNumericCommand(
        applicationID: String,
        variable: String,
        maximum: Int?
    ) -> String {
        let upperBound = maximum.map {
            "if requestedValue > \($0) then error number -1700"
        } ?? ""
        // Dynamic media values remain in argv and are parsed as numbers by AppleScript.
        return """
        on run argv
            if (count of argv) is not 1 then error number -1700
            set requestedValue to item 1 of argv as real
            if requestedValue < 0 then error number -1700
            \(upperBound)
            if application id "\(applicationID)" is not running then error number -600
            tell application id "\(applicationID)" to set \(variable) to requestedValue
        end run
        """
    }

    private static let handlers = #"""
    on replaceText(findText, replacementText, sourceText)
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to findText
        set sourceItems to text items of sourceText
        set AppleScript's text item delimiters to replacementText
        set joinedText to sourceItems as text
        set AppleScript's text item delimiters to previousDelimiters
        return joinedText
    end replaceText

    on escaped(sourceValue)
        set valueText to sourceValue as text
        if (count characters of valueText) > 2048 then set valueText to text 1 thru 2048 of valueText
        set valueText to my replaceText("\\", "\\\\", valueText)
        set valueText to my replaceText(tab, "\\t", valueText)
        set valueText to my replaceText(linefeed, "\\n", valueText)
        set valueText to my replaceText(return, "\\r", valueText)
        return valueText
    end escaped

    on joinFields(fieldValues)
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to tab
        set joinedText to fieldValues as text
        set AppleScript's text item delimiters to previousDelimiters
        return joinedText
    end joinFields
    """#

    private static let appleMusicSnapshot = handlers + #"""

    if application id "com.apple.Music" is not running then error number -600
    tell application id "com.apple.Music"
        set stateText to (get player state) as text
        set titleText to ""
        set artistText to ""
        set albumText to ""
        set identifierText to ""
        set durationText to "0"
        set positionText to "0"
        set volumeText to (get sound volume) as text
        set artworkKindText to ""
        set artworkValueText to ""
        try
            set selectedTrack to current track
            set titleText to name of selectedTrack as text
            set artistText to artist of selectedTrack as text
            set albumText to album of selectedTrack as text
            set identifierText to persistent ID of selectedTrack as text
            set durationText to duration of selectedTrack as text
            set positionText to (get player position) as text
            if identifierText is not "" and (count of artworks of selectedTrack) > 0 then
                set artworkKindText to "sourceAsset"
                set artworkValueText to identifierText
            end if
        end try
        return my joinFields({my escaped(stateText), my escaped(titleText), my escaped(artistText), my escaped(albumText), my escaped(identifierText), my escaped(durationText), my escaped(positionText), my escaped(volumeText), my escaped(artworkKindText), my escaped(artworkValueText)})
    end tell
    """#

    private static let spotifySnapshot = handlers + #"""

    if application id "com.spotify.client" is not running then error number -600
    tell application id "com.spotify.client"
        set stateText to (get player state) as text
        set titleText to ""
        set artistText to ""
        set albumText to ""
        set identifierText to ""
        set durationText to "0"
        set positionText to "0"
        set volumeText to (get sound volume) as text
        set artworkKindText to ""
        set artworkValueText to ""
        try
            set selectedTrack to current track
            set titleText to name of selectedTrack as text
            set artistText to artist of selectedTrack as text
            set albumText to album of selectedTrack as text
            set identifierText to spotify url of selectedTrack as text
            set durationText to duration of selectedTrack as text
            set positionText to (get player position) as text
            set artworkValueText to artwork url of selectedTrack as text
            if artworkValueText is not "" then set artworkKindText to "remoteURL"
        end try
        return my joinFields({my escaped(stateText), my escaped(titleText), my escaped(artistText), my escaped(albumText), my escaped(identifierText), my escaped(durationText), my escaped(positionText), my escaped(volumeText), my escaped(artworkKindText), my escaped(artworkValueText)})
    end tell
    """#
}
