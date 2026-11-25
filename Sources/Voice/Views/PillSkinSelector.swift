// Pill skin picker in Flow's settings. Lists every skin in `PillSkin.all` and previews each
// with the real pill (hands-free, bars moving) drawn in that skin. Stored as `pillSkin`.

import SwiftUI

struct PillSkinSelector: View {
    @AppStorage("pillSkin") private var stored = "glass"
    private static let levels: [Float] = (0..<32).map { Float(0.2 + 0.4 * abs(sin(Double($0) * 0.5))) }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(PillSkin.all) { skin in thumb(skin) }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func thumb(_ skin: PillSkin) -> some View {
        let selected = PillSkin.named(stored) == skin
        return Button { stored = skin.id } label: {
            VStack(spacing: 8) {
                let look = PillLookBuilder.look(PillLookInput(phase: .locked), skin: skin)
                PillBlobView(geometry: PillLayoutEngine.geometry(look, dock: .bottom, in: CGSize(width: 180, height: 46), skin: skin),
                             look: look, shownLead: look.lead, shownTrail: look.trail, shownTip: nil,
                             live: PillLiveValues(levels: Self.levels, barLevel: 0.4), actions: PillActions(), pointer: PillPointer())
                    .frame(width: 180, height: 46)
                    .allowsHitTesting(false)
                    .environment(\.pillSkin, skin)
                    .frame(width: 196, height: 64)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.7 : 0.1), lineWidth: selected ? 1.5 : 0.5))
                Text(skin.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(skin.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
