import SwiftUI

/// The inspector's memory and CPU line for one session. Observes the steward on its own so a
/// change redraws this row, not the whole inspector.
struct ResourceRow: View {
    @ObservedObject var steward: Steward
    let sessionID: UUID

    var body: some View {
        if let readout = steward.readouts[sessionID] {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("Resources").foregroundStyle(Tone.muted).frame(width: 72, alignment: .leading)
                Text(readout.text).monospacedDigit()
                Spacer(minLength: 0)
            }
            .help(readout.lowered ? "Running at background priority while off screen" : "Memory footprint and CPU of the session's processes")
        }
    }
}
