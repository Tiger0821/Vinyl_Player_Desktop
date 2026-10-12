import SwiftUI

/// A brass medal for a milestone: struck and bright once earned, an empty ring until then.
struct MilestoneMedal: View {
    let milestone: DeskStore.Milestone
    let isEarned: Bool
    var size: CGFloat = 30

    private static let brass: [Color] = [
        Color(red: 0.98, green: 0.86, blue: 0.52), Color(red: 0.74, green: 0.52, blue: 0.2),
        Color(red: 0.99, green: 0.9, blue: 0.62), Color(red: 0.66, green: 0.44, blue: 0.16),
        Color(red: 0.98, green: 0.86, blue: 0.52),
    ]

    var body: some View {
        ZStack {
            if isEarned {
                Circle().fill(AngularGradient(gradient: Gradient(colors: Self.brass), center: .center))
                Circle()
                    .strokeBorder(Theme.ink.opacity(0.35), lineWidth: size * 0.035)
                    .padding(size * 0.1)
            } else {
                Circle().strokeBorder(Theme.cream.opacity(0.26), lineWidth: 1.2)
            }
            Text("\(milestone.count)")
                .font(.system(size: size * (milestone.count >= 100 ? 0.34 : 0.4), weight: .bold, design: .serif))
                .foregroundStyle(isEarned ? Theme.ink : Theme.cream.opacity(0.42))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(isEarned ? 0.35 : 0), radius: size * 0.08, y: size * 0.04)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(milestone.name), \(milestone.count) records, \(isEarned ? "earned" : "not yet earned")")
        .help("\(milestone.name) — \(milestone.count) records")
    }
}

/// The window's account of the desk: how many records are piled up, what's next to reach,
/// the medals so far, and the way to clear it.
struct DeskStrip: View {
    @EnvironmentObject private var desk: DeskStore
    @State private var isConfirmingClear = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 20))
                .foregroundStyle(desk.celebration == nil ? Theme.cream.opacity(0.7) : Theme.ember)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(desk.celebration == nil ? Theme.cream : Theme.ember)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.cream.opacity(0.62))
            }
            .lineLimit(1)

            Spacer(minLength: 10)

            HStack(spacing: 7) {
                ForEach(DeskStore.milestones) { milestone in
                    MilestoneMedal(milestone: milestone, isEarned: desk.earned.contains(milestone.count))
                        .scaleEffect(desk.celebration == milestone ? 1.22 : 1)
                }
            }

            Button("Clear the desk") {
                isConfirmingClear = true
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(desk.count == 0)
            .confirmationDialog("Clear the desk?", isPresented: $isConfirmingClear) {
                Button("Clear", role: .destructive) { desk.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The pile of records goes back to none. Medals you've earned stay.")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well))
        .animation(.spring(duration: 0.5, bounce: 0.4), value: desk.celebration)
    }

    private var headline: String {
        if let celebration = desk.celebration { return "\(celebration.name) unlocked" }
        switch desk.count {
        case 0: return "The desk is clear"
        case 1: return "1 record on the desk"
        default: return "\(desk.count) records on the desk"
        }
    }

    private var detail: String {
        if let celebration = desk.celebration { return celebration.cheer }
        guard let next = desk.nextMilestone else { return "Every medal earned. Keep it spinning." }
        let left = next.count - desk.count
        return desk.count == 0
            ? "Each song you play through lays a record on the pile."
            : "\(left) more to \(next.name)"
    }
}

/// The cheer that rises over the desktop when a milestone is reached.
struct CelebrationToast: View {
    let milestone: DeskStore.Milestone
    let unit: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shine: CGFloat = -1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20 * unit, style: .continuous)

        HStack(spacing: 18 * unit) {
            MilestoneMedal(milestone: milestone, isEarned: true, size: 62 * unit)
                .overlay {
                    // A glint passing over the brass.
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)],
                        startPoint: UnitPoint(x: shine - 0.3, y: 0), endPoint: UnitPoint(x: shine + 0.3, y: 1)
                    )
                    .blendMode(.plusLighter)
                    .clipShape(Circle())
                }

            VStack(alignment: .leading, spacing: 5 * unit) {
                Text(milestone.name)
                    .font(.system(size: 24 * unit, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.cream)
                Text(milestone.cheer)
                    .font(.system(size: 14 * unit))
                    .foregroundStyle(Theme.cream.opacity(0.8))
            }
        }
        .padding(.leading, 20 * unit)
        .padding(.trailing, 28 * unit)
        .padding(.vertical, 18 * unit)
        .background(shape.fill(Color(red: 0.1, green: 0.065, blue: 0.045).opacity(0.93)))
        .overlay(shape.strokeBorder(Theme.cream.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24 * unit, y: 12 * unit)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).delay(0.5).repeatCount(3, autoreverses: false)) {
                shine = 2
            }
        }
        .accessibilityElement(children: .combine)
    }
}
