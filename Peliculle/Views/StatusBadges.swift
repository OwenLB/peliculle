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

// Pas de badge « référence » ici : la **couronne** du gagnant d'un tournoi
// est un marqueur du tournoi et de son récap (`DuelView`, qui la dessine
// lui-même), pas un statut de photo à porter partout. `isReference` reste un
// axe du modèle (persisté, annulable) ; il ne se lit simplement plus dans la
// grille ni dans le viewer, où une référence est une photo gardée comme une
// autre.

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

/// Palette cyclique du badge ≈ des similaires, partagée entre la grille (où
/// elle sépare des lots voisins) et le viewer (où elle reprend la teinte du
/// **même** lot plutôt qu'une couleur fixe) — un lot garde ainsi la même
/// couleur d'un écran à l'autre. Six teintes système, en alternance
/// chaude/froide pour que deux voisines ne se confondent jamais : suffisamment
/// séparées à l'œil, jamais du rouge ni du vert (déjà pris par
/// Rejeter/Garder), jamais de jaune (contraste trop faible sous le glyphe
/// blanc du badge).
enum SimilarBadgeStyle {
    static let palette: [Color] = [.blue, .orange, .purple, .pink, .indigo, .mint]

    static func tint(forRank rank: Int) -> Color {
        palette[rank % palette.count]
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
