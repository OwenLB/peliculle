import SwiftUI

/// Idée 13 — confirmation **transitoire et non bloquante** d'une décision de
/// tri : une **pastille éphémère** (« Gardée » / « Rejetée ») qui s'estompe
/// d'elle-même. Le liseré teinté, lui, vit désormais **autour de la carte
/// photo** (`DecisionFlashBorder`, posé dans la page) et non des bords de
/// l'écran. Indépendant de la page du pager ; le viewer laisse le flash se
/// jouer sur la photo décidée **avant** d'avancer (retour Owen). L'appelant
/// désactive le hit-testing et retire la vue après ~0,35 s ; l'haptique
/// différenciée garder/rejeter est aussi à sa charge (`.sensoryFeedback`).
struct DecisionFlashOverlay: View {
    let decision: CullDecision

    @State private var faded = false

    private var color: Color { decision == .keep ? .green : .red }

    var body: some View {
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
        .opacity(faded ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(0.05)) {
                faded = true
            }
        }
    }
}

/// Liseré teinté **autour de la carte photo** : dessiné dans la page (donc
/// cadré comme la photo), il épouse ses bords et son arrondi plutôt que ceux
/// de l'écran. S'estompe seul (`onAppear`) ; l'identité `flashID` côté page le
/// rejoue à chaque décision. Jamais interactif.
struct DecisionFlashBorder: View {
    let decision: CullDecision
    var cornerRadius: CGFloat = 0

    @State private var faded = false

    private var color: Color { decision == .keep ? .green : .red }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 10)
            .opacity(faded ? 0 : 1)
            .allowsHitTesting(false)
            .onAppear {
                // Tenu **franc** un instant avant de s'estomper (pas de flou
                // qui l'affadit) : avec le pager natif, la photo décidée glisse
                // hors de l'écran quasi aussitôt — un liseré trop fin ou trop
                // pressé s'y noyait complètement, lu comme « disparu ».
                withAnimation(.easeOut(duration: 0.45).delay(0.15)) {
                    faded = true
                }
            }
    }
}
