import Darwin
import EryloActivity
@_spi(Testing) import EryloLocalIntegrations
import Foundation

extension IntegrationHarness {
    func verifyDisabledState() async {
        let root = temporaryRoot("disabled")
        removeIfPresent(root)
        let service = UnixSocketActivityIntegrationService(
            handler: ActivityIntegrationController(),
            configuration: UnixSocketIntegrationConfiguration(
                enabled: false,
                directoryURL: root.appendingPathComponent("ipc", isDirectory: true)
            )
        )
        do {
            check(try await service.start() == .disabled, "Unix socket is opt-in and disabled by default")
            let state = await service.workState()
            check(
                !state.listenerActive && state.activeClientCount == 0 && state.socketURL == nil,
                "disabled service owns zero work"
            )
            check(!FileManager.default.fileExists(atPath: root.path), "disabled service performs no filesystem work")
        } catch {
            recordUnexpected(error, context: "disabled service")
        }
    }

    func verifyPermissionsRacesCleanupAndDeinit() async {
        let root = temporaryRoot("safety")
        removeIfPresent(root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let directory = root.appendingPathComponent("ipc", isDirectory: true)
            let service = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: directory)
            )
            guard case let .started(socketURL) = try await service.start() else {
                check(false, "enabled service returns its socket path")
                return
            }
            check(mode(at: directory) == 0o700, "per-user socket directory is 0700")
            check(mode(at: socketURL) == 0o600, "Unix socket file is 0600")
            check(owner(at: directory) == geteuid(), "socket directory is owned by the effective user")
            check(owner(at: socketURL) == geteuid(), "socket file is owned by the effective user")
            check(
                await completesWithin(milliseconds: 1_000) { await service.stop() },
                "idle listener stop completes within a hard wall-clock deadline"
            )
            check(!FileManager.default.fileExists(atPath: socketURL.path), "stop removes the exact socket file")
            check((await service.workState()).activeClientCount == 0, "stop drains socket ownership")

            let realDirectory = root.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
            _ = chmod(realDirectory.path, 0o700)
            let link = root.appendingPathComponent("link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDirectory)
            await expectUnsafeStart(
                UnixSocketActivityIntegrationService(
                    handler: ActivityIntegrationController(),
                    configuration: testConfiguration(directory: link)
                ),
                name: "symlink socket directory is rejected"
            )

            let openDirectory = root.appendingPathComponent("open", isDirectory: true)
            try FileManager.default.createDirectory(at: openDirectory, withIntermediateDirectories: false)
            _ = chmod(openDirectory.path, 0o755)
            await expectUnsafeStart(
                UnixSocketActivityIntegrationService(
                    handler: ActivityIntegrationController(),
                    configuration: testConfiguration(directory: openDirectory)
                ),
                name: "non-0700 final directory is rejected"
            )

            let embeddedNULDirectory = URL(
                fileURLWithPath: root.path + "/nul\u{0000}suffix",
                isDirectory: true
            )
            await expectUnsafeStart(
                UnixSocketActivityIntegrationService(
                    handler: ActivityIntegrationController(),
                    configuration: testConfiguration(directory: embeddedNULDirectory)
                ),
                name: "configured socket path containing an embedded NUL is rejected"
            )

            let raceDirectory = root.appendingPathComponent("race", isDirectory: true)
            let movedDirectory = root.appendingPathComponent("race-moved", isDirectory: true)
            let raceService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: raceDirectory),
                testingHooks: UnixSocketIntegrationTestingHooks { socketURL in
                    let original = socketURL.deletingLastPathComponent()
                    try? FileManager.default.moveItem(at: original, to: movedDirectory)
                    try? FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
                    _ = chmod(original.path, 0o700)
                }
            )
            await expectUnsafeStart(raceService, name: "parent swap after prepare is rejected by identity")

            let replacementDirectory = root.appendingPathComponent("replacement", isDirectory: true)
            let replacementBody = Data("replacement".utf8)
            let replacementService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: replacementDirectory),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    beforeSocketCleanup: { socketURL in
                        _ = Darwin.unlink(socketURL.path)
                        try? replacementBody.write(to: socketURL, options: .withoutOverwriting)
                    }
                )
            )
            guard case let .started(replacementSocket) = try await replacementService.start() else {
                check(false, "replacement cleanup service starts")
                return
            }
            await replacementService.stop()
            check(
                (try? Data(contentsOf: replacementSocket)) == replacementBody,
                "quarantine cleanup preserves a replacement injected at teardown"
            )

            let staleDirectory = root.appendingPathComponent("stale-replacement", isDirectory: true)
            try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: false)
            _ = chmod(staleDirectory.path, 0o700)
            let staleSocket = staleDirectory.appendingPathComponent(
                UnixSocketActivityIntegrationService.socketFileName
            )
            try createStaleSocketNode(at: staleSocket)
            let staleReplacementBody = Data("stale replacement".utf8)
            let staleReplacementService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: staleDirectory),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    beforeStaleSocketCleanup: { socketURL in
                        _ = Darwin.unlink(socketURL.path)
                        try? staleReplacementBody.write(to: socketURL, options: .withoutOverwriting)
                    }
                )
            )
            await expectUnsafeStart(
                staleReplacementService,
                name: "stale-socket quarantine rejects a replacement injected after identity capture"
            )
            check(
                (try? Data(contentsOf: staleSocket)) == staleReplacementBody,
                "stale-socket quarantine preserves the injected replacement"
            )

            let deinitDirectory = root.appendingPathComponent("deinit", isDirectory: true)
            var deinitService: UnixSocketActivityIntegrationService? = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: deinitDirectory)
            )
            guard case let .started(deinitSocket) = try await deinitService?.start() else {
                check(false, "deinit fail-safe service starts")
                return
            }
            deinitService = nil
            check(
                await waitUntil(milliseconds: 1_000) {
                    !FileManager.default.fileExists(atPath: deinitSocket.path)
                },
                "deinit fail-safe completes cleanup within a hard wall-clock deadline"
            )
        } catch {
            recordUnexpected(error, context: "permissions, races, cleanup, and deinit")
        }
        removeIfPresent(root)
    }

    func verifyACLAndDescriptorRejection() async {
        let root = temporaryRoot("acl-fd")
        removeIfPresent(root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

            let directoryAllowPermissions: [(name: String, permission: acl_perm_t)] = [
                ("list-directory", ACL_LIST_DIRECTORY),
                ("add-file", ACL_ADD_FILE),
                ("search", ACL_SEARCH),
                ("delete", ACL_DELETE),
                ("add-subdirectory", ACL_ADD_SUBDIRECTORY),
                ("delete-child", ACL_DELETE_CHILD),
                ("read-attributes", ACL_READ_ATTRIBUTES),
                ("write-attributes", ACL_WRITE_ATTRIBUTES),
                ("read-extended-attributes", ACL_READ_EXTATTRIBUTES),
                ("write-extended-attributes", ACL_WRITE_EXTATTRIBUTES),
                ("read-security", ACL_READ_SECURITY),
                ("write-security", ACL_WRITE_SECURITY),
                ("change-owner", ACL_CHANGE_OWNER),
                ("synchronize", ACL_SYNCHRONIZE),
            ]

            let finalACLDirectory = root.appendingPathComponent("final-acl", isDirectory: true)
            try FileManager.default.createDirectory(at: finalACLDirectory, withIntermediateDirectories: false)
            _ = chmod(finalACLDirectory.path, 0o700)
            for testCase in directoryAllowPermissions {
                try applyEveryoneACL(
                    to: finalACLDirectory,
                    tag: ACL_EXTENDED_ALLOW,
                    permissions: [testCase.permission]
                )
                _ = chmod(finalACLDirectory.path, 0o700)
                check(
                    mode(at: finalACLDirectory) == 0o700,
                    "\(testCase.name) allow ACL leaves final directory mode at 0700"
                )
                await expectUnsafeStart(
                    UnixSocketActivityIntegrationService(
                        handler: ActivityIntegrationController(),
                        configuration: testConfiguration(directory: finalACLDirectory)
                    ),
                    name: "\(testCase.name) allow ACL on the final directory is rejected"
                )
                clearACL(at: finalACLDirectory)
            }

            let safeBase = root.appendingPathComponent("safe-base", isDirectory: true)
            let unsafeAncestor = safeBase.appendingPathComponent("acl-ancestor", isDirectory: true)
            try FileManager.default.createDirectory(at: unsafeAncestor, withIntermediateDirectories: true)
            _ = chmod(safeBase.path, 0o700)
            _ = chmod(unsafeAncestor.path, 0o700)
            let ancestorTarget = unsafeAncestor.appendingPathComponent("target", isDirectory: true)
            for testCase in directoryAllowPermissions {
                try applyEveryoneACL(
                    to: unsafeAncestor,
                    tag: ACL_EXTENDED_ALLOW,
                    permissions: [testCase.permission]
                )
                _ = chmod(unsafeAncestor.path, 0o700)
                check(
                    mode(at: unsafeAncestor) == 0o700,
                    "\(testCase.name) allow ACL leaves intermediate ancestor mode at 0700"
                )
                await expectUnsafeStart(
                    UnixSocketActivityIntegrationService(
                        handler: ActivityIntegrationController(),
                        configuration: testConfiguration(directory: ancestorTarget)
                    ),
                    name: "\(testCase.name) allow ACL on an intermediate ancestor is rejected"
                )
                clearACL(at: unsafeAncestor)
            }

            try applyEveryoneACL(
                to: unsafeAncestor,
                tag: ACL_EXTENDED_DENY,
                permissions: [ACL_DELETE]
            )
            _ = chmod(unsafeAncestor.path, 0o700)
            let ancestorDenyService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: unsafeAncestor.appendingPathComponent("deny-target", isDirectory: true)
                )
            )
            guard case .started = try await ancestorDenyService.start() else {
                check(false, "deny-delete ACL on an intermediate ancestor remains permitted")
                return
            }
            check(true, "deny-delete ACL on an intermediate ancestor remains permitted")
            await ancestorDenyService.stop()
            clearACL(at: unsafeAncestor)

            for (permissionIndex, testCase) in privateObjectACLAllowPermissions.enumerated() {
                let lockACLDirectory = root.appendingPathComponent(
                    "la\(permissionIndex)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: lockACLDirectory,
                    withIntermediateDirectories: false
                )
                _ = chmod(lockACLDirectory.path, 0o700)
                let unsafeLock = lockACLDirectory.appendingPathComponent(".erylo-v1.lock")
                try Data().write(to: unsafeLock, options: .withoutOverwriting)
                _ = chmod(unsafeLock.path, 0o600)
                try applyEveryoneACL(
                    to: unsafeLock,
                    tag: ACL_EXTENDED_ALLOW,
                    permissions: [testCase.permission]
                )
                _ = chmod(unsafeLock.path, 0o600)
                let sentinel = lockACLDirectory.appendingPathComponent("sentinel")
                let sentinelBody = Data("lock \(testCase.name) sentinel".utf8)
                try sentinelBody.write(to: sentinel, options: .withoutOverwriting)
                check(
                    mode(at: unsafeLock) == 0o600 && aclAllows(testCase.permission, at: unsafeLock),
                    "\(testCase.name) real allow ACL leaves lock mode at 0600"
                )
                let descriptorsBefore = openDescriptorCount()
                let service = UnixSocketActivityIntegrationService(
                    handler: ActivityIntegrationController(),
                    configuration: testConfiguration(directory: lockACLDirectory)
                )
                await expectUnsafeStart(
                    service,
                    name: "\(testCase.name) allow ACL on the lock file is rejected"
                )
                check(
                    FileManager.default.fileExists(atPath: unsafeLock.path)
                        && aclAllows(testCase.permission, at: unsafeLock),
                    "\(testCase.name) rejected lock ACL preserves the unsafe lock for inspection"
                )
                let state = await service.workState()
                check(
                    !state.listenerActive && state.activeClientCount == 0 && state.socketURL == nil,
                    "\(testCase.name) rejected lock ACL leaves no listener or client work"
                )
                check(
                    openDescriptorCount() == descriptorsBefore,
                    "\(testCase.name) rejected lock ACL leaves descriptor count flat"
                )
                check(
                    (try? Data(contentsOf: sentinel)) == sentinelBody,
                    "\(testCase.name) rejected lock ACL preserves an unrelated path"
                )
                clearACL(at: unsafeLock)
            }

            for (permissionIndex, testCase) in privateObjectACLAllowPermissions.enumerated() {
                let staleACLDirectory = root.appendingPathComponent(
                    "sa\(permissionIndex)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: staleACLDirectory,
                    withIntermediateDirectories: false
                )
                _ = chmod(staleACLDirectory.path, 0o700)
                // Metadata/bootstrap ACEs cannot be applied directly to a
                // filesystem socket on Darwin. File inheritance installs the
                // exact real permission when its vnode is created.
                try applyEveryoneACL(
                    to: staleACLDirectory,
                    tag: ACL_EXTENDED_ALLOW,
                    permissions: [testCase.permission],
                    flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_ONLY_INHERIT]
                )
                let staleACLSocket = staleACLDirectory.appendingPathComponent(
                    UnixSocketActivityIntegrationService.socketFileName
                )
                try createStaleSocketNode(at: staleACLSocket)
                clearACL(at: staleACLDirectory)
                _ = chmod(staleACLSocket.path, 0o600)
                let sentinel = staleACLDirectory.appendingPathComponent("sentinel")
                let sentinelBody = Data("stale \(testCase.name) sentinel".utf8)
                try sentinelBody.write(to: sentinel, options: .withoutOverwriting)
                check(
                    mode(at: staleACLSocket) == 0o600
                        && aclAllows(testCase.permission, at: staleACLSocket),
                    "\(testCase.name) real inherited allow ACL exists on the stale socket"
                )
                let descriptorsBefore = openDescriptorCount()
                let service = UnixSocketActivityIntegrationService(
                    handler: ActivityIntegrationController(),
                    configuration: testConfiguration(directory: staleACLDirectory)
                )
                await expectUnsafeStart(
                    service,
                    name: "\(testCase.name) allow ACL on a stale socket is rejected"
                )
                check(
                    FileManager.default.fileExists(atPath: staleACLSocket.path)
                        && aclAllows(testCase.permission, at: staleACLSocket),
                    "\(testCase.name) rejected stale ACL preserves the unsafe socket"
                )
                let state = await service.workState()
                check(
                    !state.listenerActive && state.activeClientCount == 0 && state.socketURL == nil,
                    "\(testCase.name) rejected stale ACL leaves no listener or client work"
                )
                check(
                    openDescriptorCount() == descriptorsBefore,
                    "\(testCase.name) rejected stale ACL leaves descriptor count flat"
                )
                check(
                    (try? Data(contentsOf: sentinel)) == sentinelBody,
                    "\(testCase.name) rejected stale ACL preserves an unrelated path"
                )
                clearACL(at: staleACLSocket)
                _ = Darwin.unlink(staleACLSocket.path)
            }

            let denyDirectory = root.appendingPathComponent("deny-acl", isDirectory: true)
            try FileManager.default.createDirectory(at: denyDirectory, withIntermediateDirectories: false)
            _ = chmod(denyDirectory.path, 0o700)
            try applyEveryoneACL(
                to: denyDirectory,
                tag: ACL_EXTENDED_DENY,
                permissions: [ACL_DELETE]
            )
            let denyLock = denyDirectory.appendingPathComponent(".erylo-v1.lock")
            try Data().write(to: denyLock, options: .withoutOverwriting)
            _ = chmod(denyLock.path, 0o600)
            try applyEveryoneACL(
                to: denyLock,
                tag: ACL_EXTENDED_DENY,
                permissions: [ACL_DELETE]
            )
            let denySentinel = denyDirectory.appendingPathComponent("sentinel")
            let denySentinelBody = Data("lock deny sentinel".utf8)
            try denySentinelBody.write(to: denySentinel, options: .withoutOverwriting)
            let denyDescriptorsBefore = openDescriptorCount()
            let denyService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: denyDirectory)
            )
            guard case .started = try await denyService.start() else {
                check(false, "deny-delete ACL service starts")
                return
            }
            check(
                testACLContains(tag: ACL_EXTENDED_DENY, permission: ACL_DELETE, at: denyLock),
                "real deny-delete ACL on the lock remains permitted"
            )
            await denyService.stop()
            check(
                openDescriptorCount() == denyDescriptorsBefore,
                "deny-only lock lifecycle leaves descriptor count flat"
            )
            check(
                (try? Data(contentsOf: denySentinel)) == denySentinelBody,
                "deny-only lock lifecycle preserves an unrelated path"
            )
            clearACL(at: denyDirectory)
            clearACL(at: denyLock)

            let staleDenyDirectory = root.appendingPathComponent("stale-deny", isDirectory: true)
            try FileManager.default.createDirectory(
                at: staleDenyDirectory,
                withIntermediateDirectories: false
            )
            _ = chmod(staleDenyDirectory.path, 0o700)
            try applyEveryoneACL(
                to: staleDenyDirectory,
                tag: ACL_EXTENDED_DENY,
                permissions: [ACL_READ_DATA],
                flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_ONLY_INHERIT]
            )
            let staleDenySocket = staleDenyDirectory.appendingPathComponent(
                UnixSocketActivityIntegrationService.socketFileName
            )
            try createStaleSocketNode(at: staleDenySocket)
            clearACL(at: staleDenyDirectory)
            _ = chmod(staleDenySocket.path, 0o600)
            check(
                testACLContains(
                    tag: ACL_EXTENDED_DENY,
                    permission: ACL_READ_DATA,
                    at: staleDenySocket
                ),
                "real deny-only ACL is inherited by the stale socket"
            )
            let staleDenyDescriptorsBefore = openDescriptorCount()
            let staleDenyService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: staleDenyDirectory)
            )
            guard case .started = try await staleDenyService.start() else {
                check(false, "deny-only stale socket ACL remains permitted")
                return
            }
            check(true, "deny-only stale socket ACL permits identity-safe stale cleanup")
            await staleDenyService.stop()
            check(
                openDescriptorCount() == staleDenyDescriptorsBefore,
                "deny-only stale socket lifecycle leaves descriptor count flat"
            )

            let descriptorBase = root.appendingPathComponent("descriptor-base", isDirectory: true)
            let unsafeOpenable = descriptorBase.appendingPathComponent("unsafe-openable", isDirectory: true)
            try FileManager.default.createDirectory(at: unsafeOpenable, withIntermediateDirectories: true)
            _ = chmod(descriptorBase.path, 0o700)
            _ = chmod(unsafeOpenable.path, 0o777)
            let rejectedTarget = unsafeOpenable.appendingPathComponent("target", isDirectory: true)
            // Warm actor/runtime paths before establishing the descriptor baseline.
            _ = try? await UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: rejectedTarget)
            ).start()
            let descriptorsBefore = openDescriptorCount()
            var everyStartRejected = true
            for _ in 0..<128 {
                do {
                    _ = try await UnixSocketActivityIntegrationService(
                        handler: ActivityIntegrationController(),
                        configuration: testConfiguration(directory: rejectedTarget)
                    ).start()
                    everyStartRejected = false
                } catch let error as UnixSocketIntegrationError {
                    if error != .unsafeDirectory { everyStartRejected = false }
                } catch {
                    everyStartRejected = false
                }
            }
            let descriptorsAfter = openDescriptorCount()
            check(everyStartRejected, "openable unsafe intermediate ancestor always fails closed")
            check(
                descriptorsAfter == descriptorsBefore,
                "repeated unsafe intermediate validation keeps descriptor count flat"
            )
        } catch {
            recordUnexpected(error, context: "ACL and descriptor rejection")
        }
        removeIfPresent(root)
    }

    func verifyPublicationRacesAndWakeRetry() async {
        let root = temporaryRoot("publication-wake")
        removeIfPresent(root)
        var stage = "create root"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

            stage = "bind identity race"
            let preIdentityReplacement = Data("pre-identity replacement".utf8)
            let boundStagingURL = CapturedURL()
            let bindIdentityRace = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("bind-identity-race", isDirectory: true)
                ),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    duringSocketPublication: { stage, stagingURL, _ in
                        guard stage == .boundBeforeIdentity else { return }
                        boundStagingURL.capture(stagingURL)
                        _ = Darwin.unlink(stagingURL.path)
                        try? preIdentityReplacement.write(to: stagingURL, options: .withoutOverwriting)
                    }
                )
            )
            await expectUnsafeStart(
                bindIdentityRace,
                name: "staging replacement between bind and identity capture fails closed"
            )
            check(
                boundStagingURL.value.flatMap { try? Data(contentsOf: $0) } == preIdentityReplacement,
                "pre-identity staging replacement is preserved"
            )

            for (permissionIndex, testCase) in privateObjectACLAllowPermissions.enumerated() {
                stage = "staged socket \(testCase.name) ACL"
                let directory = root.appendingPathComponent("sta\(permissionIndex)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
                _ = chmod(directory.path, 0o700)
                let sentinel = directory.appendingPathComponent("sentinel")
                let sentinelBody = Data("staged \(testCase.name) sentinel".utf8)
                try sentinelBody.write(to: sentinel, options: .withoutOverwriting)
                let stagedURL = CapturedURL()
                let aclApplied = CapturedFlag()
                let service = UnixSocketActivityIntegrationService(
                    handler: ActivityIntegrationController(),
                    configuration: testConfiguration(directory: directory),
                    testingHooks: UnixSocketIntegrationTestingHooks(
                        duringSocketPublication: { publicationStage, stagingURL, finalURL in
                            switch publicationStage {
                            case .beforeBind:
                                do {
                                    try applyTestEveryoneACL(
                                        to: finalURL.deletingLastPathComponent(),
                                        tag: ACL_EXTENDED_ALLOW,
                                        permissions: [testCase.permission],
                                        flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_ONLY_INHERIT]
                                    )
                                } catch {
                                    aclApplied.capture(false)
                                }
                            case .boundBeforeIdentity:
                                stagedURL.capture(stagingURL)
                                aclApplied.capture(testACLAllows(testCase.permission, at: stagingURL))
                                clearTestACL(at: finalURL.deletingLastPathComponent())
                            default:
                                break
                            }
                        }
                    )
                )
                let descriptorsBefore = openDescriptorCount()
                await expectUnsafeStart(
                    service,
                    name: "\(testCase.name) allow ACL on the staged socket is rejected"
                )
                check(
                    aclApplied.value,
                    "\(testCase.name) real allow ACL is inherited by the staged socket"
                )
                check(
                    stagedURL.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true
                        && !FileManager.default.fileExists(
                            atPath: directory.appendingPathComponent(
                                UnixSocketActivityIntegrationService.socketFileName
                            ).path
                        ),
                    "\(testCase.name) staged ACL failure removes only the expected staged identity"
                )
                let state = await service.workState()
                check(
                    !state.listenerActive && state.activeClientCount == 0 && state.socketURL == nil,
                    "\(testCase.name) staged ACL failure leaves no listener or client work"
                )
                check(
                    openDescriptorCount() == descriptorsBefore,
                    "\(testCase.name) staged ACL failure leaves descriptor count flat"
                )
                check(
                    (try? Data(contentsOf: sentinel)) == sentinelBody,
                    "\(testCase.name) staged ACL cleanup preserves an unrelated path"
                )
                clearACL(at: directory)
            }

            stage = "staged deny-only socket ACL"
            let stagedDenyDirectory = root.appendingPathComponent("staged-deny", isDirectory: true)
            try FileManager.default.createDirectory(
                at: stagedDenyDirectory,
                withIntermediateDirectories: false
            )
            _ = chmod(stagedDenyDirectory.path, 0o700)
            let stagedDenySentinel = stagedDenyDirectory.appendingPathComponent("sentinel")
            let stagedDenySentinelBody = Data("staged deny sentinel".utf8)
            try stagedDenySentinelBody.write(
                to: stagedDenySentinel,
                options: .withoutOverwriting
            )
            let stagedDenyApplied = CapturedFlag()
            let stagedDenyService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: stagedDenyDirectory),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    duringSocketPublication: { publicationStage, stagingURL, finalURL in
                        switch publicationStage {
                        case .beforeBind:
                            try? applyTestEveryoneACL(
                                to: finalURL.deletingLastPathComponent(),
                                tag: ACL_EXTENDED_DENY,
                                permissions: [ACL_READ_DATA],
                                flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_ONLY_INHERIT]
                            )
                        case .boundBeforeIdentity:
                            stagedDenyApplied.capture(
                                testACLContains(
                                    tag: ACL_EXTENDED_DENY,
                                    permission: ACL_READ_DATA,
                                    at: stagingURL
                                )
                            )
                            clearTestACL(at: finalURL.deletingLastPathComponent())
                        default:
                            break
                        }
                    }
                )
            )
            let stagedDenyDescriptorsBefore = openDescriptorCount()
            guard case let .started(stagedDenySocket) = try await stagedDenyService.start() else {
                check(false, "deny-only staged socket ACL remains permitted")
                return
            }
            check(
                stagedDenyApplied.value
                    && testACLContains(
                        tag: ACL_EXTENDED_DENY,
                        permission: ACL_READ_DATA,
                        at: stagedDenySocket
                    ),
                "real deny-only ACL survives staging and exclusive publication"
            )
            await stagedDenyService.stop()
            check(
                openDescriptorCount() == stagedDenyDescriptorsBefore,
                "deny-only staged socket lifecycle leaves descriptor count flat"
            )
            check(
                (try? Data(contentsOf: stagedDenySentinel)) == stagedDenySentinelBody,
                "deny-only staged socket cleanup preserves an unrelated path"
            )

            for (permissionIndex, testCase) in privateObjectACLAllowPermissions.enumerated() {
                stage = "published socket \(testCase.name) ACL"
                let directory = root.appendingPathComponent(
                    "pa\(permissionIndex)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                _ = chmod(directory.path, 0o700)
                let socketURL = directory.appendingPathComponent(
                    UnixSocketActivityIntegrationService.socketFileName
                )
                let sentinelURL = directory.appendingPathComponent("unrelated-sentinel")
                let sentinelBody = Data("unrelated \(testCase.name) sentinel".utf8)
                try sentinelBody.write(to: sentinelURL, options: .withoutOverwriting)
                let inheritedSocketURL: URL?
                if testCase.permission == ACL_WRITE_DATA {
                    inheritedSocketURL = nil
                } else {
                    // Darwin rejects direct installation of these metadata/
                    // ACL bootstrap rights on a filesystem socket. Inherit a
                    // real ACE at vnode creation, then publish that same-EUID
                    // socket as the adversarial replacement.
                    let carrierDirectory = root.appendingPathComponent(
                        "pc\(permissionIndex)",
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: carrierDirectory,
                        withIntermediateDirectories: false
                    )
                    _ = chmod(carrierDirectory.path, 0o700)
                    try applyEveryoneACL(
                        to: carrierDirectory,
                        tag: ACL_EXTENDED_ALLOW,
                        permissions: [testCase.permission],
                        flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_ONLY_INHERIT]
                    )
                    let carrierSocket = carrierDirectory.appendingPathComponent("carrier.sock")
                    try createStaleSocketNode(at: carrierSocket)
                    clearACL(at: carrierDirectory)
                    inheritedSocketURL = carrierSocket
                }
                let publishedURL = CapturedURL()
                let aclApplied = CapturedFlag()
                let service = UnixSocketActivityIntegrationService(
                    handler: ActivityIntegrationController(),
                    configuration: testConfiguration(directory: directory),
                    testingHooks: UnixSocketIntegrationTestingHooks(
                        duringSocketPublication: { stage, _, finalURL in
                            guard stage == .publishedBeforeIdentity else { return }
                            publishedURL.capture(finalURL)
                            do {
                                if let inheritedSocketURL {
                                    guard Darwin.unlink(finalURL.path) == 0,
                                          Darwin.rename(
                                            inheritedSocketURL.path,
                                            finalURL.path
                                          ) == 0 else {
                                        aclApplied.capture(false)
                                        return
                                    }
                                } else {
                                    try applyTestEveryoneACL(
                                        to: finalURL,
                                        tag: ACL_EXTENDED_ALLOW,
                                        permissions: [testCase.permission]
                                    )
                                    _ = chmod(finalURL.path, 0o600)
                                }
                                aclApplied.capture(testACLAllows(testCase.permission, at: finalURL))
                            } catch {
                                aclApplied.capture(false)
                            }
                        }
                    )
                )
                let descriptorsBefore = openDescriptorCount()
                await expectUnsafeStart(
                    service,
                    name: inheritedSocketURL == nil
                        ? "\(testCase.name) allow ACL on the bound published socket is rejected"
                        : "\(testCase.name) ACL-bearing published replacement fails closed"
                )
                check(
                    publishedURL.value == socketURL && aclApplied.value,
                    inheritedSocketURL == nil
                        ? "\(testCase.name) allow ACL is installed on the bound socket after publication"
                        : "\(testCase.name) real ACL-bearing replacement is installed after publication"
                )
                check(
                    inheritedSocketURL == nil
                        ? !FileManager.default.fileExists(atPath: socketURL.path)
                        : aclAllows(testCase.permission, at: socketURL),
                    inheritedSocketURL == nil
                        ? "\(testCase.name) published socket failure removes the expected socket identity"
                        : "\(testCase.name) published socket failure preserves the ACL-bearing replacement"
                )
                let state = await service.workState()
                check(
                    !state.listenerActive && state.activeClientCount == 0 && state.socketURL == nil,
                    "\(testCase.name) published socket failure leaves no listener or client work"
                )
                check(
                    openDescriptorCount() == descriptorsBefore,
                    "\(testCase.name) published socket failure leaves descriptor count flat"
                )
                check(
                    (try? Data(contentsOf: sentinelURL)) == sentinelBody,
                    "\(testCase.name) published socket cleanup preserves an unrelated path"
                )
                if inheritedSocketURL != nil {
                    clearACL(at: socketURL)
                    _ = Darwin.unlink(socketURL.path)
                }
            }

            stage = "published socket replacement cleanup"
            let publishedReplacementDirectory = root.appendingPathComponent(
                "published-replacement",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: publishedReplacementDirectory,
                withIntermediateDirectories: false
            )
            _ = chmod(publishedReplacementDirectory.path, 0o700)
            let publishedReplacementURL = publishedReplacementDirectory.appendingPathComponent(
                UnixSocketActivityIntegrationService.socketFileName
            )
            let publishedReplacementBody = Data("published replacement".utf8)
            let publishedReplacementSentinel = publishedReplacementDirectory.appendingPathComponent(
                "unrelated-sentinel"
            )
            let publishedReplacementSentinelBody = Data("unrelated replacement sentinel".utf8)
            try publishedReplacementSentinelBody.write(
                to: publishedReplacementSentinel,
                options: .withoutOverwriting
            )
            let replacementPublishedURL = CapturedURL()
            let publishedReplacementService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: publishedReplacementDirectory),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    duringSocketPublication: { stage, _, finalURL in
                        guard stage == .publishedBeforeIdentity else { return }
                        replacementPublishedURL.capture(finalURL)
                        _ = Darwin.unlink(finalURL.path)
                        try? publishedReplacementBody.write(
                            to: finalURL,
                            options: .withoutOverwriting
                        )
                    }
                )
            )
            let replacementDescriptorsBefore = openDescriptorCount()
            await expectUnsafeStart(
                publishedReplacementService,
                name: "replacement after exclusive socket publication fails closed"
            )
            check(
                replacementPublishedURL.value == publishedReplacementURL,
                "replacement race executes only after exclusive socket publication"
            )
            check(
                (try? Data(contentsOf: publishedReplacementURL)) == publishedReplacementBody,
                "failed published-socket cleanup restores the replacement instead of deleting it"
            )
            let publishedReplacementState = await publishedReplacementService.workState()
            check(
                !publishedReplacementState.listenerActive
                    && publishedReplacementState.activeClientCount == 0
                    && publishedReplacementState.socketURL == nil,
                "published replacement failure leaves no listener or client work"
            )
            check(
                openDescriptorCount() == replacementDescriptorsBefore,
                "published replacement failure leaves descriptor count flat"
            )
            check(
                (try? Data(contentsOf: publishedReplacementSentinel))
                    == publishedReplacementSentinelBody,
                "published replacement cleanup preserves an unrelated path"
            )

            stage = "deny socket ACL"
            let publishedDenyDirectory = root.appendingPathComponent(
                "socket-deny-acl",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: publishedDenyDirectory,
                withIntermediateDirectories: false
            )
            _ = chmod(publishedDenyDirectory.path, 0o700)
            let publishedDenySentinel = publishedDenyDirectory.appendingPathComponent("sentinel")
            let publishedDenySentinelBody = Data("published deny sentinel".utf8)
            try publishedDenySentinelBody.write(
                to: publishedDenySentinel,
                options: .withoutOverwriting
            )
            let publishedDenyApplied = CapturedFlag()
            let denySocketACL = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(directory: publishedDenyDirectory),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    duringSocketPublication: { stage, _, finalURL in
                        if stage == .publishedBeforeIdentity {
                            try? applyTestEveryoneACL(
                                to: finalURL,
                                tag: ACL_EXTENDED_DENY,
                                permissions: [ACL_DELETE]
                            )
                            _ = chmod(finalURL.path, 0o600)
                            publishedDenyApplied.capture(
                                testACLContains(
                                    tag: ACL_EXTENDED_DENY,
                                    permission: ACL_DELETE,
                                    at: finalURL
                                )
                            )
                        }
                    }
                )
            )
            let publishedDenyDescriptorsBefore = openDescriptorCount()
            guard case let .started(denySocketURL) = try await denySocketACL.start() else {
                check(false, "deny-delete ACL on the published socket remains permitted")
                return
            }
            check(
                publishedDenyApplied.value,
                "real deny-delete ACL on the published socket remains permitted"
            )
            clearACL(at: denySocketURL)
            await denySocketACL.stop()
            check(
                openDescriptorCount() == publishedDenyDescriptorsBefore,
                "deny-only published socket lifecycle leaves descriptor count flat"
            )
            check(
                (try? Data(contentsOf: publishedDenySentinel)) == publishedDenySentinelBody,
                "deny-only published socket cleanup preserves an unrelated path"
            )

            stage = "chmod race"
            let protectedTarget = root.appendingPathComponent("protected-target")
            try Data("protected".utf8).write(to: protectedTarget)
            _ = chmod(protectedTarget.path, 0o640)
            let chmodRace = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("chmod-race", isDirectory: true)
                ),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    duringSocketPublication: { stage, stagingURL, _ in
                        guard stage == .identityCaptured else { return }
                        _ = Darwin.unlink(stagingURL.path)
                        try? FileManager.default.createSymbolicLink(
                            at: stagingURL,
                            withDestinationURL: protectedTarget
                        )
                    }
                )
            )
            await expectUnsafeStart(chmodRace, name: "staging chmod symlink swap fails closed")
            check(mode(at: protectedTarget) == 0o640, "no-follow staging chmod never changes symlink target mode")

            stage = "identity race"
            let stagedReplacement = Data("staging replacement".utf8)
            let identityRace = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("identity-race", isDirectory: true)
                ),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    duringSocketPublication: { stage, stagingURL, _ in
                        guard stage == .permissionApplied else { return }
                        _ = Darwin.unlink(stagingURL.path)
                        try? stagedReplacement.write(to: stagingURL, options: .withoutOverwriting)
                    }
                )
            )
            await expectUnsafeStart(identityRace, name: "staging identity swap before publication fails closed")
            let identityFinal = root.appendingPathComponent(
                "identity-race/\(UnixSocketActivityIntegrationService.socketFileName)"
            )
            check(
                (try? Data(contentsOf: identityFinal)) == stagedReplacement,
                "failed publication preserves the injected staging replacement"
            )

            stage = "publication race"
            let finalReplacement = Data("final collision".utf8)
            let publicationRace = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("publish-race", isDirectory: true)
                ),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    duringSocketPublication: { stage, _, finalURL in
                        guard stage == .beforePublication else { return }
                        try? finalReplacement.write(to: finalURL, options: .withoutOverwriting)
                    }
                )
            )
            await expectUnsafeStart(publicationRace, name: "exclusive final publication rejects a collision")
            let publicationFinal = root.appendingPathComponent(
                "publish-race/\(UnixSocketActivityIntegrationService.socketFileName)"
            )
            check(
                (try? Data(contentsOf: publicationFinal)) == finalReplacement,
                "exclusive publication preserves the final-path replacement"
            )

            stage = "wake retry"
            let wakeScript = WakeWriteScript([.zero, .interrupted, .written])
            let wakeService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("wake", isDirectory: true)
                ),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    nextWakeWriteResult: wakeScript.next
                )
            )
            guard case let .started(wakeSocket) = try await wakeService.start() else {
                check(false, "wake retry service starts")
                return
            }
            check(
                await completesWithin(milliseconds: 1_000) { await wakeService.stop() },
                "zero/EINTR wake writes retry until a real byte wakes poll"
            )
            check(wakeScript.callCount == 3, "wake signal publishes state only after successful write proof")
            check(!FileManager.default.fileExists(atPath: wakeSocket.path), "wake retry teardown cleans the socket")

            stage = "wake failure"
            let failedWakeScript = WakeWriteScript([.failed])
            let failedWakeService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("wake-failure", isDirectory: true)
                ),
                testingHooks: UnixSocketIntegrationTestingHooks(
                    nextWakeWriteResult: failedWakeScript.next
                )
            )
            guard case let .started(failedWakeSocket) = try await failedWakeService.start() else {
                check(false, "failed-wake fallback service starts")
                return
            }
            check(
                await completesWithin(milliseconds: 1_000) { await failedWakeService.stop() },
                "fatal wake write closes the owned pipe end and wakes poll with HUP"
            )
            check(failedWakeScript.callCount == 1, "fatal wake write is not reported as a byte-write success")
            check(
                !FileManager.default.fileExists(atPath: failedWakeSocket.path),
                "fatal wake fallback teardown cleans the socket"
            )
        } catch {
            recordUnexpected(error, context: "publication races and wake retry (\(stage))")
        }
        removeIfPresent(root)
    }

    func verifyPeerRejectionAndAcceptFailure() async {
        let root = temporaryRoot("peer-fatal")
        removeIfPresent(root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let peerService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("peer", isDirectory: true)
                ),
                peerValidator: RejectAllPeers()
            )
            guard case let .started(peerSocket) = try await peerService.start() else {
                check(false, "peer rejection service starts")
                return
            }
            let rejectedClient = try connect(to: peerSocket)
            check(
                try readResponse(from: rejectedClient).error?.code == .peerRejected,
                "peer credential rejection seam closes admission"
            )
            _ = Darwin.close(rejectedClient)
            await peerService.stop()

            let fatalService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("fatal", isDirectory: true)
                )
            )
            guard case let .started(fatalSocket) = try await fatalService.start() else {
                check(false, "accept failure service starts")
                return
            }
            await fatalService.forceUnexpectedAcceptFailure()
            check(
                await waitUntil {
                    let state = await fatalService.workState()
                    return !state.listenerActive && state.lastAcceptError != nil
                },
                "unexpected accept failure becomes a fatal observable state"
            )
            check(!FileManager.default.fileExists(atPath: fatalSocket.path), "fatal accept cleanup removes the socket")
        } catch {
            recordUnexpected(error, context: "peer rejection and accept failure")
        }
        removeIfPresent(root)
    }

    func verifyConnectFloodStop() async {
        let root = temporaryRoot("connect-flood")
        removeIfPresent(root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let service = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("ipc", isDirectory: true),
                    maximumConcurrentClients: 2
                )
            )
            guard case let .started(socketURL) = try await service.start() else {
                check(false, "connect-flood service starts")
                return
            }
            let flood = SocketConnectFlood(socketURL: socketURL)
            let floodTask = Task.detached { flood.run() }
            check(
                await waitUntil(milliseconds: 1_000) { flood.attemptCount >= 100 },
                "nonblocking local connect flood is active"
            )
            check(
                await completesWithin(milliseconds: 2_000) { await service.stop() },
                "wake channel stops an accept loop under sustained connect flood"
            )
            flood.stop()
            floodTask.cancel()
            await floodTask.value
            check(
                !FileManager.default.fileExists(atPath: socketURL.path),
                "connect-flood teardown removes the exact socket"
            )
        } catch {
            recordUnexpected(error, context: "connect-flood stop")
        }
        removeIfPresent(root)
    }

    func verifySocketFramingCapacityAndTimeouts() async {
        let root = temporaryRoot("protocol")
        removeIfPresent(root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let service = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(),
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("ipc", isDirectory: true),
                    maximumConcurrentClients: 1,
                    maximumRequests: 4,
                    timeoutMilliseconds: 200
                )
            )
            guard case let .started(socketURL) = try await service.start() else {
                check(false, "protocol service starts")
                return
            }

            let firstClient = try connect(to: socketURL)
            check(
                await waitUntil { await service.workState().activeClientCount == 1 },
                "first client consumes the bounded capacity slot"
            )
            guard let firstConnection = await service.testingConnections().first else {
                check(false, "first tokenized connection is observable to the harness")
                return
            }
            let overflowClient = try connect(to: socketURL)
            check(
                try readResponse(from: overflowClient).error?.code == .serverBusy,
                "concurrent client overflow receives bounded backpressure"
            )
            _ = Darwin.close(overflowClient)

            let statusFrame = try requestFrame(#"{"version":1,"operation":"status"}"#)
            try writeAll(statusFrame.prefix(2), to: firstClient)
            var remainderAndSecond = Data(statusFrame.dropFirst(2))
            remainderAndSecond.append(statusFrame)
            try writeAll(remainderAndSecond, to: firstClient)
            check(try readResponse(from: firstClient).result?.operation == .status, "socket accepts a partial request frame")
            check(try readResponse(from: firstClient).result?.operation == .status, "socket accepts multiple request frames")

            try writeAll(try requestFrame("{"), to: firstClient)
            check(
                try readResponse(from: firstClient).error?.code == .invalidRequest,
                "malformed socket body receives deterministic error"
            )
            try writeAll(
                try requestFrame(#"{"version":1,"operation":"launch","command":"whoami"}"#),
                to: firstClient
            )
            check(
                try readResponse(from: firstClient).error?.code == .invalidRequest,
                "unknown socket operation never executes"
            )
            try writeAll(statusFrame, to: firstClient)
            check(
                try readResponse(from: firstClient).error?.code == .requestLimitExceeded,
                "per-connection request count is bounded"
            )
            _ = Darwin.close(firstClient)
            check(
                await waitUntil { await service.workState().activeClientCount == 0 },
                "closed client releases its tokenized capacity slot"
            )

            let reuseClient = try connect(to: socketURL)
            check(
                await waitUntil { await service.workState().activeClientCount == 1 },
                "replacement client is tracked"
            )
            guard let replacementConnection = await service.testingConnections().first else {
                check(false, "replacement tokenized connection is observable")
                return
            }
            check(
                replacementConnection.descriptor == firstConnection.descriptor,
                "harness deterministically exercises OS file-descriptor reuse"
            )
            await service.simulateStaleCompletion(token: firstConnection.token)
            check(
                await service.workState().activeClientCount == 1,
                "stale token completion cannot remove a reused descriptor"
            )
            _ = Darwin.close(reuseClient)
            _ = await waitUntil { await service.workState().activeClientCount == 0 }

            let oversizedClient = try connect(to: socketURL)
            try writeAll(
                framePrefix(UInt32(ActivityIntegrationAPI.maximumRequestBodyBytes + 1)),
                to: oversizedClient
            )
            check(
                try readResponse(from: oversizedClient).error?.code == .frameTooLarge,
                "oversized socket frame is rejected from its prefix"
            )
            _ = Darwin.close(oversizedClient)
            _ = await waitUntil { await service.workState().activeClientCount == 0 }

            let truncatedClient = try connect(to: socketURL)
            try writeAll(statusFrame.dropLast(), to: truncatedClient)
            _ = Darwin.shutdown(truncatedClient, SHUT_WR)
            check(
                try readResponse(from: truncatedClient).error?.message == "truncated length-prefixed frame",
                "EOF on a partial frame returns a deterministic truncation error"
            )
            _ = Darwin.close(truncatedClient)
            _ = await waitUntil { await service.workState().activeClientCount == 0 }

            let slowWriter = try connect(to: socketURL)
            try writeAll(statusFrame.prefix(2), to: slowWriter)
            check(
                try readResponse(from: slowWriter).error?.code == .requestTimeout,
                "partial-frame slow writer is released by the receive deadline"
            )
            _ = Darwin.close(slowWriter)

            check(
                await completesWithin(milliseconds: 1_000) { await service.stop() },
                "protocol service teardown completes within a hard wall-clock deadline"
            )
            check(!FileManager.default.fileExists(atPath: socketURL.path), "normal teardown removes the socket")

            try await verifySlowReaderDeadline(root: root)
        } catch {
            recordUnexpected(error, context: "socket framing, capacity, and timeouts")
        }
        removeIfPresent(root)
    }

    func verifySuspendedHandlerStopAndGenerationGate() async {
        let root = temporaryRoot("suspend")
        removeIfPresent(root)
        var stage = "create root"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let broker = ActivityBroker()
            let handler = SuspendingIntegrationHandler(
                downstream: ActivityIntegrationController(broker: broker)
            )
            let service = UnixSocketActivityIntegrationService(
                handler: handler,
                configuration: testConfiguration(
                    directory: root.appendingPathComponent("ipc", isDirectory: true),
                    timeoutMilliseconds: 500
                )
            )
            stage = "first start"
            guard case let .started(firstSocket) = try await service.start() else {
                check(false, "suspending handler service starts")
                return
            }
            let staleClient = try connect(to: firstSocket)
            try writeAll(
                try requestFrame(
                    #"{"version":1,"operation":"submit","activity":{"identifier":"stale","source":"external","kind":"generic","priority":50,"title":"Stale"}}"#
                ),
                to: staleClient
            )
            check(await waitUntil { await handler.isSuspended }, "handler suspends after dispatch")
            stage = "first stop"
            check(
                await completesWithin(milliseconds: 1_000) { await service.stop() },
                "stop completes within a hard deadline while a handler is suspended"
            )
            check((await service.workState()).activeClientCount == 0, "stop does not hang on a suspended handler")
            check(!FileManager.default.fileExists(atPath: firstSocket.path), "stop closes suspended-handler descriptors")
            check(mode(at: root.appendingPathComponent("ipc", isDirectory: true)) == 0o700, "restart directory remains 0700")
            check(
                mode(at: root.appendingPathComponent("ipc/.erylo-v1.lock")) == 0o600,
                "restart lock remains 0600"
            )

            await handler.useImmediateMode()
            stage = "second start"
            guard case let .started(secondSocket) = try await service.start() else {
                check(false, "service restarts with a new generation")
                return
            }
            await handler.resumeSuspendedRequest()
            check(
                await waitUntil(milliseconds: 1_000) { await handler.suspendedResponse != nil },
                "fresh uncancelled stale-lease task completes within a hard wall-clock deadline"
            )
            check(
                await handler.suspendedResponse?.error?.code == .cancelled,
                "invalidated mutation lease rejects the resumed stale request"
            )
            check(await broker.snapshot().ordered.isEmpty, "cancelled stale request cannot mutate the shared broker")

            let currentClient = try connect(to: secondSocket)
            try writeAll(try requestFrame(#"{"version":1,"operation":"status"}"#), to: currentClient)
            check(try readResponse(from: currentClient).result?.operation == .status, "new generation accepts fresh requests")
            _ = Darwin.close(currentClient)
            _ = Darwin.close(staleClient)
            await service.stop()
        } catch {
            recordUnexpected(error, context: "suspended handler cancellation and generation (\(stage))")
        }
        removeIfPresent(root)
    }

    func verifySuspendedHandlerDeinitFailSafe() async {
        let root = temporaryRoot("suspend-deinit")
        removeIfPresent(root)
        var stage = "create root"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let descriptorsBefore = openDescriptorCount()
            let broker = ActivityBroker()
            let handler = SuspendingIntegrationHandler(
                downstream: ActivityIntegrationController(broker: broker)
            )
            let directory = root.appendingPathComponent("ipc", isDirectory: true)
            var service: UnixSocketActivityIntegrationService? = UnixSocketActivityIntegrationService(
                handler: handler,
                configuration: testConfiguration(directory: directory, timeoutMilliseconds: 500)
            )
            guard service != nil else {
                check(false, "suspended deinit service is retained for startup")
                return
            }
            let weakService = WeakSocketServiceReference(service!)
            stage = "start"
            guard case let .started(socketURL) = try await service!.start() else {
                check(false, "suspended deinit service starts")
                return
            }

            let client = try connect(to: socketURL)
            try writeAll(
                try requestFrame(
                    #"{"version":1,"operation":"submit","activity":{"identifier":"deinit-stale","source":"external","kind":"generic","priority":50,"title":"Deinit stale"}}"#
                ),
                to: client
            )
            check(
                await waitUntil { await handler.isSuspended },
                "deinit regression handler suspends after dispatch"
            )
            check(
                await waitUntil {
                    guard let currentService = service else { return false }
                    return await currentService.testingDispatchCount() == 1
                },
                "deinit regression observes the registered suspended dispatch"
            )

            stage = "drop last service reference"
            service = nil
            let deinitializedWithinDeadline = await waitUntil(milliseconds: 1_000) {
                weakService.value == nil
                    && !FileManager.default.fileExists(atPath: socketURL.path)
            }
            check(
                deinitializedWithinDeadline,
                "dropping the last service reference deinitializes a suspended dispatch within a hard deadline"
            )
            _ = Darwin.close(client)

            stage = "resume stale handler"
            await handler.resumeSuspendedRequest()
            check(
                await waitUntil(milliseconds: 1_000) { await handler.suspendedResponse != nil },
                "deinit-invalidated handler releases within a hard deadline"
            )
            check(
                await handler.suspendedResponse?.error?.code == .cancelled,
                "deinit invalidates the suspended dispatch mutation lease"
            )
            check(
                !(await handler.isSuspended),
                "deinit-cancelled handler no longer owns a suspended continuation"
            )
            check(
                await broker.snapshot().ordered.isEmpty,
                "deinit-invalidated stale dispatch cannot mutate the broker"
            )

            stage = "verify released lock"
            check(
                await waitUntil(milliseconds: 1_000) {
                    weakService.value == nil
                        && !FileManager.default.fileExists(atPath: socketURL.path)
                },
                "deinit fail-safe removes the socket and releases service ownership"
            )
            let restartService = UnixSocketActivityIntegrationService(
                handler: ActivityIntegrationController(broker: broker),
                configuration: testConfiguration(directory: directory)
            )
            guard case .started = try await restartService.start() else {
                check(false, "a replacement service acquires the released directory lock")
                return
            }
            check(true, "a replacement service acquires the released directory lock")
            await restartService.stop()
            check(
                await waitUntil(milliseconds: 1_000) {
                    openDescriptorCount() == descriptorsBefore
                },
                "suspended-dispatch deinit restores the descriptor baseline"
            )
        } catch {
            recordUnexpected(error, context: "suspended handler deinit fail-safe (\(stage))")
        }
        removeIfPresent(root)
    }

    private func verifySlowReaderDeadline(root: URL) async throws {
        let broker = ActivityBroker()
        for index in 0..<ActivityLimits.maximumActivityCount {
            _ = try await broker.submit(
                ActivityRequest(
                    identifier: "slow-reader-\(index)-" + String(repeating: "x", count: 64),
                    source: "external",
                    kind: "generic",
                    priority: 50,
                    title: String(repeating: "T", count: ActivityLimits.titleBytes),
                    detail: String(repeating: "D", count: ActivityLimits.detailBytes)
                )
            )
        }
        let service = UnixSocketActivityIntegrationService(
            handler: ActivityIntegrationController(broker: broker),
            configuration: testConfiguration(
                directory: root.appendingPathComponent("slow-reader", isDirectory: true),
                timeoutMilliseconds: 100,
                bufferBytes: 4_096
            )
        )
        guard case let .started(socketURL) = try await service.start() else {
            check(false, "slow-reader service starts")
            return
        }
        var receiveBufferBeforeConnect = Int32.max
        let client = try connect(to: socketURL, receiveBufferBytes: 1_024) {
            receiveBufferBeforeConnect = $0
        }
        check(
            receiveBufferBeforeConnect <= 16 * 1_024,
            "slow-reader client verifies a small receive buffer before connect"
        )
        try writeAll(try requestFrame(#"{"version":1,"operation":"status"}"#), to: client)
        try await ContinuousClock().sleep(for: .milliseconds(300))
        check(
            await waitUntil { await service.workState().activeClientCount == 0 },
            "non-reading client is released by the send deadline"
        )
        _ = Darwin.close(client)
        await service.stop()
    }

    private func testConfiguration(
        directory: URL,
        maximumConcurrentClients: Int = 8,
        maximumRequests: Int = 16,
        timeoutMilliseconds: Int = 300,
        bufferBytes: Int = 64 * 1_024
    ) -> UnixSocketIntegrationConfiguration {
        UnixSocketIntegrationConfiguration(
            enabled: true,
            directoryURL: directory,
            maximumConcurrentClients: maximumConcurrentClients,
            maximumRequestsPerConnection: maximumRequests,
            clientIOTimeoutMilliseconds: timeoutMilliseconds,
            clientSocketBufferBytes: bufferBytes
        )
    }

    private func expectUnsafeStart(
        _ service: UnixSocketActivityIntegrationService,
        name: String
    ) async {
        do {
            _ = try await service.start()
            check(false, name)
            await service.stop()
        } catch let error as UnixSocketIntegrationError {
            check(error == .unsafeDirectory, name)
        } catch {
            recordUnexpected(error, context: name)
        }
    }
}

private actor SuspendingIntegrationHandler: ActivityIntegrationHandling {
    private let downstream: ActivityIntegrationController
    private var suspendedRequest: ActivityIntegrationRequest?
    private var suspendedLease: ActivityIntegrationLease?
    private var suspendedContinuation: CheckedContinuation<ActivityIntegrationResponse, Never>?
    private var immediateMode = false
    private(set) var suspendedResponse: ActivityIntegrationResponse?

    init(downstream: ActivityIntegrationController) {
        self.downstream = downstream
    }

    var isSuspended: Bool { suspendedContinuation != nil }

    func useImmediateMode() {
        immediateMode = true
    }

    func resumeSuspendedRequest() {
        guard let request = suspendedRequest,
              let lease = suspendedLease else { return }
        suspendedRequest = nil
        suspendedLease = nil
        let downstream = downstream
        // This fresh detached task does not inherit cancellation from the
        // transport task stopped in the previous service generation.
        Task.detached {
            let response = await downstream.handle(request, lease: lease)
            await self.finishSuspendedRequest(response)
        }
    }

    func handle(
        _ request: ActivityIntegrationRequest,
        lease: ActivityIntegrationLease
    ) async -> ActivityIntegrationResponse {
        if !immediateMode {
            suspendedRequest = request
            suspendedLease = lease
            return await withCheckedContinuation { suspendedContinuation = $0 }
        }
        return await downstream.handle(request, lease: lease)
    }

    private func finishSuspendedRequest(_ response: ActivityIntegrationResponse) {
        suspendedResponse = response
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume(returning: response)
    }
}
