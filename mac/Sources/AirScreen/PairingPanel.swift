import SwiftUI
import AppKit

/// A floating panel for the pairing prompt.
///
/// AirScreen is an `LSUIElement` menu bar app, so the popover is only on screen
/// while the user is holding it open. A pairing request has to be seen whenever
/// it arrives, which means its own window.
///
/// Deliberately does **not** take focus, and sits under the menu bar rather
/// than at the centre of the screen. An earlier version called
/// `activate(ignoringOtherApps:)` and `makeKeyAndOrderFront`, which dropped a
/// live Allow button under the pointer of someone busy doing something else:
/// in testing it collected their next click and paired a TV nobody had looked
/// at. Ordering it in without activating means the first click only makes the
/// panel key — AppKit does not forward an activating click to a control — so
/// granting access always costs a second, deliberate click.
@MainActor
final class PairingPanel {
    private var panel: NSPanel?

    func show(request: AppModel.PairingRequest, macName: String,
              approve: @escaping () -> Void, deny: @escaping () -> Void) {
        dismiss()

        let view = PairingPanelView(
            request: request,
            macName: macName,
            approve: { [weak self] in self?.dismiss(); approve() },
            deny: { [weak self] in self?.dismiss(); deny() }
        )
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Pair with \(request.name)"
        panel.styleMask = [.titled, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        position(panel)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    /// Top trailing corner, clear of the menu bar and of wherever the pointer
    /// is likely to be.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 20,
            y: visible.maxY - size.height - 20
        ))
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct PairingPanelView: View {
    let request: AppModel.PairingRequest
    let macName: String
    let approve: () -> Void
    let deny: () -> Void

    /// Allow stays inert until the panel has been on screen long enough for a
    /// person to have read it. A window opening under the pointer picks up a
    /// stray click, and `AppModel` discards early approvals for the same
    /// reason — this is only the visible half of that rule.
    @State private var armed = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("\(request.name) wants to show \(macName)")
                    .font(.headline)
                Text("Check the code on your TV matches this one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(Pairing.grouped(request.code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(4)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            Text("If the codes differ, something on your network is intercepting the connection. Decline.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(role: .cancel, action: deny) {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                Button(action: approve) {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!armed)
            }
            .task {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                armed = true
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
