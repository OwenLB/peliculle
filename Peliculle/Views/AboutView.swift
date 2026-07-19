import SwiftUI

/// ⚙️ › À propos — la carte d'identité de l'app : version, engagement de
/// confidentialité et lien vers la politique complète (section Privacy de la
/// landing). Attendu par la review App Store pour une app photo — et
/// l'argument « 100 % on-device » mérite d'être affiché dans l'app, pas
/// seulement sur le site.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// La politique vit sur la landing ; la version anglaise a son chemin.
    private var privacyURL: URL {
        let french = Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
        return URL(string: french
            ? "https://peliculle.com/#privacy"
            : "https://peliculle.com/en/#privacy")!
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        // Marque, jamais traduite.
                        Text(verbatim: "Peliculle")
                            .font(.title2.bold())
                        Text("Version \(AppVersion.display)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Label {
                        Text("Tout se passe sur votre appareil : le tri, les aperçus et les signaux d'analyse ne quittent jamais l'iPhone.")
                    } icon: {
                        Image(systemName: "iphone")
                    }
                    Label {
                        Text("Aucun compte, aucune collecte de données, aucune publicité.")
                    } icon: {
                        Image(systemName: "hand.raised")
                    }
                    Label {
                        Text("Votre carte SD est lue en lecture seule — vos originaux ne sont jamais modifiés.")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    Link(destination: privacyURL) {
                        Label("Politique de confidentialité", systemImage: "safari")
                    }
                } header: {
                    Text("Confidentialité")
                }
            }
            .navigationTitle("À propos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    AboutView()
}
