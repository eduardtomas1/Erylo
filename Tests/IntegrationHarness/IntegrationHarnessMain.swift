@main
enum IntegrationHarnessMain {
    static func main() async {
        let harness = IntegrationHarness()
        await harness.verifyStrictSchemaAndSharedBroker()
        await harness.verifyURLRoute()
        await harness.verifyCommandLineRoute()
        harness.verifyFraming()
        await harness.verifyDisabledState()
        await harness.verifyPermissionsRacesCleanupAndDeinit()
        await harness.verifyACLAndDescriptorRejection()
        await harness.verifyPublicationRacesAndWakeRetry()
        await harness.verifyPeerRejectionAndAcceptFailure()
        await harness.verifyConnectFloodStop()
        await harness.verifySocketFramingCapacityAndTimeouts()
        await harness.verifySuspendedHandlerStopAndGenerationGate()
        await harness.verifySuspendedHandlerDeinitFailSafe()
        harness.finish()
    }
}
