import CoreGraphics
import Darwin
import EryloCore
import EryloIntegrations

@main
enum FoundationHarnessMain {
    static func main() async {
        var harness = FoundationHarness()
        harness.verifyPanelStateMachine()
        harness.verifyPanelGeometry()
        await harness.verifyDisabledProvider()
        harness.finish()
    }
}

private struct FoundationHarness {
    private var checkCount = 0
    private var failures: [String] = []

    mutating func verifyPanelStateMachine() {
        var machine = PanelStateMachine()
        check(machine.send(.show) == .compact, "show reveals compact state")
        check(machine.send(.hoverBegan) == .peek, "hover reveals peek state")
        check(machine.send(.primaryAction) == .expanded, "one action expands peek state")
        check(machine.send(.primaryAction) == .compact, "one action collapses expanded state")

        var hidden = PanelStateMachine()
        check(hidden.send(.hoverBegan) == .hidden, "hidden state ignores hover")
        check(hidden.send(.primaryAction) == .hidden, "hidden state ignores primary action")
        check(hidden.send(.dragEntered) == .hidden, "hidden state ignores drag entry")

        var dropTarget = PanelStateMachine(initialState: .expanded)
        check(dropTarget.send(.dragEntered) == .dropTarget, "drag enters drop-target state")
        check(dropTarget.send(.dragExited) == .compact, "drag cancellation returns to compact")
        check(dropTarget.send(.dragEntered) == .dropTarget, "drop target can be re-entered")
        check(dropTarget.send(.dropCompleted) == .expanded, "drop completion has an explicit route")

        for state in PanelPresentationState.allCases {
            var candidate = PanelStateMachine(initialState: state)
            check(candidate.send(.hide) == .hidden, "hide wins from \(state.rawValue)")
        }
    }

    mutating func verifyPanelGeometry() {
        let display = DisplayGeometry(
            frame: CGRect(x: 100, y: 50, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 100, y: 50, width: 1_440, height: 875),
            backingScaleFactor: 2,
            topEdgeOcclusion: nil
        )
        let layouts = PanelPresentationState.allCases.map {
            PanelLayout(display: display, state: $0)
        }
        let fixedFrame = layouts[0].fixedFrame
        check(layouts.allSatisfy { $0.fixedFrame == fixedFrame }, "maximum frame is fixed across states")
        check(fixedFrame.maxY == display.frame.maxY, "fixed frame is top-edge anchored")

        let hidden = PanelLayout(display: display, state: .hidden)
        check(!hidden.hitRegion.contains(hidden.surfaceFrame.center), "hidden state has no hit region")

        let compact = PanelLayout(display: display, state: .compact)
        check(compact.hitRegion.contains(compact.surfaceFrame.center), "compact center is interactive")
        check(
            !compact.hitRegion.contains(CGPoint(x: compact.surfaceFrame.minX, y: compact.surfaceFrame.minY)),
            "transparent rounded corner is not interactive"
        )
        check(
            compact.hitRegion.contains(CGPoint(x: compact.surfaceFrame.midX, y: compact.surfaceFrame.maxY)),
            "rounded-region boundary is interactive"
        )

        let notchedDisplay = DisplayGeometry(
            frame: display.frame,
            visibleFrame: display.visibleFrame,
            backingScaleFactor: display.backingScaleFactor,
            topEdgeOcclusion: TopEdgeOcclusion(
                frame: CGRect(x: 720, y: 876, width: 220, height: 74)
            )
        )
        let notched = PanelLayout(display: notchedDisplay, state: .compact)
        check(notched.fixedFrame == compact.fixedFrame, "notch does not change the maximum frame")
        check(notched.surfaceFrame.width == 268, "notch width and padding expand compact surface")
        check(notched.surfaceFrame.height == 74, "notch height expands compact surface")

        let constrainedMetrics = PanelMetrics(
            maximumSize: CGSize(width: 100, height: 80),
            compactSize: CGSize(width: 500, height: 400),
            peekSize: .zero,
            expandedSize: .zero,
            dropTargetSize: .zero,
            notchHorizontalPadding: 0
        )
        let constrained = PanelLayout(
            display: display,
            state: .compact,
            metrics: constrainedMetrics
        )
        check(constrained.surfaceFrame.size == constrainedMetrics.maximumSize, "surface is clamped to maximum frame")
    }

    mutating func verifyDisabledProvider() async {
        let provider = DisabledActivityProvider(identifier: "disabled-test")
        var events: [ActivityEvent] = []
        for await event in provider.events() {
            events.append(event)
        }
        check(events.isEmpty, "disabled provider finishes without events")
    }

    private mutating func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checkCount += 1
        if !condition() {
            failures.append(name)
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Foundation harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Foundation harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
