import SwiftUI

/// F10 — contrôle de notation 0–5 étoiles. Taper une étoile fixe la note ;
/// retaper l'étoile courante remet à zéro. Retour au parent via `onRate`.
///
/// Lisibilité sur photo : étoiles vides en `.primary` (s'adaptent au thème
/// clair/sombre) + légère ombre, et cible tactile de 44 pt par étoile
/// (minimum HIG, Revue UX UX2) — la capsule hôte en verre porte le fond.
struct StarRatingView: View {
    let rating: Int
    var onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onRate(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.title3.weight(.medium))
                        // Étoile pleine en jaune ; vide en `.primary` pour
                        // s'adapter au thème (blanc en sombre, noir en clair),
                        // comme les autres contrôles du viewer.
                        .foregroundStyle(star <= rating ? Color.yellow : .primary.opacity(0.85))
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // Clé plurielle du catalogue (« %lld étoile(s) », variations
                // one/other par langue) plutôt qu'un « s » conditionnel maison.
                .accessibilityLabel(String(localized: "\(star) étoile(s)"))
            }
        }
    }
}
