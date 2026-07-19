import SwiftUI

/// Idée 13 — confirmation **transitoire et non bloquante** d'une décision de
/// tri : liseré teinté sur les bords de l'écran + pastille éphémère, qui
/// s'estompent d'eux-mêmes. Indépendant de la page du pager (jamais
/// d'animation de défilement) ; le viewer laisse le flash se jouer sur la
/// photo décidée **avant** d'avancer (retour Owen). L'appelant désactive le
/// hit-testing et retire la vue après ~0,35 s ; l'haptique différenciée
/// garder/rejeter est aussi à sa charge (`.sensoryFeedback`).
struct DecisionFlashOverlay: View {
    let decision: CullDecision

    @State private var faded = false

    private var color: Color { decision == .keep ? .green : .red }

    var body: some View {
        ZStack {
            Rectangle()
                .strokeBorder(color.opacity(0.8), lineWidth: 6)
                .blur(radius: 3)
                .ignoresSafeArea()
            VStack {
                Label(
                    decision == .keep ? "Gardée" : "Rejetée",
                    systemImage: decision == .keep ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(color.opacity(0.85), in: .capsule)
                Spacer()
            }
            .padding(.top, 8)
        }
        .opacity(faded ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(0.05)) {
                faded = true
            }
        }
    }
}
