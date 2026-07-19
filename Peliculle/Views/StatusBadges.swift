import SwiftUI

/// Badges de **statut** d'une photo, partagés entre la grille (miniatures) et
/// le viewer (barre de navigation) pour une lecture identique partout :
/// enregistrée = flèche de téléchargement bleue, gardée = coche verte,
/// rejetée = croix rouge, note = étoile jaune sur capsule sombre.
/// Pur statut, jamais des actions.

/// « Déjà enregistrée dans la pellicule » (cette session).
struct SavedBadge: View {
    var font: Font = .body

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(font)
            .foregroundStyle(.white, .blue)
            .shadow(radius: 2)
            .accessibilityLabel("Déjà enregistrée dans la pellicule")
    }
}

/// Décision de tri (F5) ; rien tant que la photo n'est pas triée.
struct DecisionBadge: View {
    let decision: CullDecision
    var font: Font = .body

    var body: some View {
        switch decision {
        case .keep:
            badge("checkmark.circle.fill", .green, "Gardée")
        case .reject:
            badge("xmark.circle.fill", .red, "Rejetée")
        case .undecided:
            EmptyView()
        }
    }

    private func badge(_ symbol: String, _ color: Color, _ label: LocalizedStringKey) -> some View {
        Image(systemName: symbol)
            .font(font)
            .foregroundStyle(.white, color)
            .shadow(radius: 2)
            .accessibilityLabel(label)
    }
}

/// Note 0–5 (F10) ; rien tant que la photo n'est pas notée.
struct RatingBadge: View {
    let rating: Int

    var body: some View {
        if rating > 0 {
            HStack(spacing: 2) {
                Image(systemName: "star.fill")
                Text("\(rating)")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.yellow)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: .capsule)
            .accessibilityLabel("Note \(rating) sur 5")
        }
    }
}
