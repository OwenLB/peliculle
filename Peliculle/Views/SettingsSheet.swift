import SwiftUI

/// Revue UX (UX5, point 10) — le menu ⚙️ devient une sheet « Réglages » en
/// liste groupée classique iOS : 8 entrées hétérogènes ne tiennent pas dans
/// un menu déroulant, et la liste a de la place pour les futurs réglages.
/// Les entrées qui ouvraient une sheet la présentent d'ici (sheet sur
/// sheet, natif) ; le seuil de rafales devient un picker en ligne. « Album
/// d'enregistrement » retrouve son nom complet : le libellé n'avait été
/// raccourci que parce qu'il passait sur deux lignes en menu.
struct SettingsSheet: View {
    let session: CullSession

    // Similaires (culling assisté) — réglages **globaux** partagés par le Tri
    // rapide (`QuickCullView`) et le repérage dans la grille (`GridView`).
    @AppStorage("similaritySensitivity") private var similaritySensitivity = SimilaritySensitivity.normal
    @AppStorage("similarityAutoDuel") private var similarityAutoDuel = false

    @State private var showAlbumSettings = false
    @State private var showTripSettings = false
    @State private var showNotificationSettings = false
    @State private var diagnostics: String?
    @State private var showAbout = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                sessionSection
                similaritySection
                applicationSection
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showAlbumSettings) {
            AlbumSettingsView(session: session, confirmLabel: String(localized: "OK")) {
                showAlbumSettings = false
            }
        }
        // Archivage implicite (même règle que la grille) : tout voyage actif
        // validé rejoint l'historique global — en configurer un nouveau
        // n'écrase plus le précédent.
        .sheet(isPresented: $showTripSettings, onDismiss: {
            var trips = SavedTrip.load()
            SavedTrip.record(session.trip, in: &trips)
        }) {
            TripSettingsView(session: session)
        }
        .sheet(isPresented: $showNotificationSettings) {
            NotificationSettingsView(session: session)
        }
        .sheet(isPresented: Binding(isPresenting: $diagnostics)) {
            diagnosticsSheet
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
    }

    // MARK: - Sections

    private var sessionSection: some View {
        // Monochrome (retour Owen) : icônes + libellés en `.primary` (blanc en
        // sombre, noir en clair) au lieu du bleu d'accent par défaut. Pour un
        // Button de liste, le libellé est teinté en bleu par le style bouton
        // automatique — `.buttonStyle(.plain)` retire cette teinte, puis
        // `.foregroundStyle(.primary)` fixe la couleur. Appliqué au niveau
        // section : ne touche ni l'en-tête gris ni les pieds.
        Section("Session") {
            Button {
                showAlbumSettings = true
            } label: {
                Label("Album d'enregistrement", systemImage: "photo.stack")
                    .foregroundStyle(.primary)
            }
            // Idée 15 — le voyage borne tout l'affichage à sa plage.
            Button {
                showTripSettings = true
            } label: {
                Group {
                    if session.trip.isActive {
                        let name = session.trip.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Label(
                            name.isEmpty
                                ? String(localized: "Voyage — actif")
                                : String(localized: "Voyage — \(name)"),
                            systemImage: "airplane.circle.fill"
                        )
                    } else {
                        Label("Voyage", systemImage: "airplane")
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Similaires (culling assisté) : sensibilité visuelle (partagée grille +
    /// Tri rapide) et auto-ouverture du tournoi.
    private var similaritySection: some View {
        Section {
            Picker("Sensibilité", systemImage: "slider.horizontal.3", selection: $similaritySensitivity) {
                ForEach(SimilaritySensitivity.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(.primary)
            Toggle(isOn: $similarityAutoDuel) {
                Label("Ouvrir le tournoi automatiquement", systemImage: "rectangle.split.2x1")
                    .foregroundStyle(.primary)
            }
        } header: {
            Text("Similaires")
        } footer: {
            Text("Les photos qui se ressemblent sont signalées d'un badge (grille et Tri rapide) et se départagent en tournoi. La sensibilité règle la tolérance visuelle — à affiner selon vos photos. Le repérage dans la grille s'active dans les Filtres.")
        }
    }

    private var applicationSection: some View {
        Section("Application") {
            Button {
                showNotificationSettings = true
            } label: {
                Label("Notifications", systemImage: "bell.badge")
                    .foregroundStyle(.primary)
            }
            // Idée 21 — remise à zéro de l'onboarding : les tips
            // redeviennent éligibles immédiatement.
            Button {
                OnboardingTips.reset()
            } label: {
                Label("Revoir les astuces", systemImage: "questionmark.circle")
                    .foregroundStyle(.primary)
            }
            Button {
                diagnostics = session.diagnosticsReport()
            } label: {
                Label("Diagnostic de session", systemImage: "stethoscope")
                    .foregroundStyle(.primary)
            }
            Button {
                showAbout = true
            } label: {
                Label("À propos", systemImage: "info.circle")
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Rapport de persistance (voir `SessionStore.diagnosticsReport`) :
    /// lisible sur device et partageable, pour déboguer la reprise de
    /// session sans brancher l'iPhone à Xcode.
    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                Text(diagnostics ?? "")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Diagnostic de session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { diagnostics = nil }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: diagnostics ?? "")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
