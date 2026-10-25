// Run with Tests/run-meter-visibility-tests.sh. Appended to ContentView.swift
// in the temporary build so the test exercises the actual private MeterView.

@main
struct MeterVisibilityTests {
    @MainActor
    static func main() {
        func expect(_ condition: Bool, _ message: String = "Unexpected initial visibility") {
            if !condition {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            }
        }
        _ = NSApplication.shared
        let center = NotificationCenter.default
        let notifications = [NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification]
        func drainCallbacks() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }

        weak var releasedView: MeterView?
        autoreleasepool {
            let first = makeWindow()
            let second = makeWindow()
            let model = MeterModel()
            var view: MeterView? = MeterView(frame: NSRect(x: 0, y: 0, width: 282, height: 38))
            releasedView = view
            view!.model = model
            first.contentView!.addSubview(view!)
            drainCallbacks()
            expect(!model.hasVisibleDisplay)

            // An ordered-out window must stop metering for every visibility event.
            // Repeat to exercise notification reentry and deferred main-queue work.
            for _ in 0..<100 {
                for name in notifications {
                    model.setDisplayVisible(view!, true)
                    center.post(name: name, object: first)
                    drainCallbacks()
                    expect(!model.hasVisibleDisplay, "Hidden window kept meters active: \(name)")
                }
            }

            model.setDisplayVisible(view!, true)
            center.post(name: NSWindow.willCloseNotification, object: first)
            drainCallbacks()
            expect(!model.hasVisibleDisplay, "Closing must stop meters")

            // Queue an old-window callback, then move before it runs.
            center.post(name: NSWindow.willCloseNotification, object: first)
            view!.removeFromSuperview()
            second.contentView!.addSubview(view!)
            model.setDisplayVisible(view!, true)
            drainCallbacks()
            expect(model.hasVisibleDisplay, "Stale callback affected the new window")

            // Observers from the first window must have been removed.
            for name in notifications + [NSWindow.willCloseNotification] {
                center.post(name: name, object: first)
            }
            drainCallbacks()
            expect(model.hasVisibleDisplay, "Old window still has active observers")

            let replacement = MeterModel()
            view!.model = replacement
            expect(!model.hasVisibleDisplay, "Replacing the model leaked visibility")
            replacement.setDisplayVisible(view!, true)
            view!.removeFromSuperview()
            expect(!replacement.hasVisibleDisplay, "Detaching must stop meters")
            second.contentView!.addSubview(view!)
            center.post(name: NSWindow.didChangeOcclusionStateNotification, object: second)
            view!.removeFromSuperview()
            view = nil
            drainCallbacks()
            first.close()
            second.close()
        }
        drainCallbacks()
        expect(releasedView == nil, "Queued callbacks retained the view")
        print("Meter visibility tests passed (300 visibility events, close, reparent, detach, release)")
    }
}
