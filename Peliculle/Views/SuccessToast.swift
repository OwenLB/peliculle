import SwiftUI

/// Revue UX (UX4) — toast de succès : capsule Liquid Glass qui descend du
/// haut de l'écran et s'efface toute seule. Pour les issues heureuses
/// (« 12 photos enregistrées · carte intacte ») une alerte centrée avec OK
/// interrompt pour rien — on continue à trier sans s'arrêter. Les erreurs
/// et confirmations destructives restent en alertes.
///
/// Usage : `.successToast(message: $toastMessage)` — poser le texte affiche
/// la capsule, qui se retire d'elle-même après quelques secondes (ou est
/// remplacée si un nouveau succès arrive entre-temps).
extension View {
    func successToast(message: Binding<String?>) -> some View {
        modifier(SuccessToastModifier(message: message))
    }
}

private struct SuccessToastModifier: ViewModifier {
    @Binding var message: String?

    /// Compteur d'affichages : relance la minuterie (`task(id:)`) quand un
    /// nouveau succès remplace le toast courant avant son extinction.
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    SuccessToastView(message: message)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.3), value: message)
            .onChange(of: message) { _, newValue in
                if newValue != nil { generation += 1 }
            }
            .task(id: generation) {
                guard message != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                message = nil
            }
    }
}

private struct SuccessToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect()
        .padding(.horizontal, 24)
        .padding(.top, 8)
        // Purement informatif : les taps passent à travers vers la grille —
        // un toast n'est pas un contrôle, et il disparaît de lui-même.
        .allowsHitTesting(false)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
