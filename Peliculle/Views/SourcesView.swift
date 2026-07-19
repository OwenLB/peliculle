import SwiftUI

/// Batch H5 — hub **unique** des sources d'une session. Seul point d'entrée
/// (icône de toolbar ou pilule de la grille) pour tout ce qui touche à la
/// provenance des photos :
/// - **voir** les sources qui alimentent la grille (et leur nombre de photos) ;
/// - **retirer** l'une d'elles (balayage) sans clore la session tant qu'il en
///   reste une (garde-fou de `CullSession`) ;
/// - **ouvrir** une source, en mode **Ajouter** (composer une grille combinée)
///   ou **Remplacer** (nouvelle session) — une seule liste, une bascule décide
///   de l'action, pas de doublon.
///
/// Toutes les actions d'ouverture referment d'abord le hub : le picker (dossier,
/// album, période) se présente proprement au premier plan, sans empiler deux
/// sheets. Le routage passe par `onRequest` (le `handle` de `ContentView`).
struct SourcesView: View {
    let session: CullSession
    var recentFolders: [RecentFolder] = []
    var recentAlbums: [RecentAlbum] = []
    /// Route unique : `.add(...)` (composer), une demande nue (remplacer),
    /// `.remove(...)` (retrait) ou `.welcome` (fermer la session).
    var onRequest: (SourceRequest) -> Void
    /// Retrait d'une entrée de l'**historique** des récents (≠ retirer une
    /// source de la grille) — swipe ou bouton « Modifier ».
    var onDeleteRecentFolder: (RecentFolder) -> Void = { _ in }
    var onDeleteRecentAlbum: (RecentAlbum) -> Void = { _ in }

    /// Ajouter (composer) vs Remplacer (nouvelle session). Défaut **Remplacer** :
    /// c'est l'action historique — ouvrir une source la remplace ; composer une
    /// grille combinée devient un geste volontaire.
    private enum Mode { case replace, add }
    @State private var mode: Mode = .replace

    @Environment(\.dismiss) private var dismiss

    /// On ne retire pas la dernière source (ce serait clore la session).
    private var canRemove: Bool { session.sources.count > 1 }

    var body: some View {
        // Comptage par source en **une** passe (O(items)) plutôt qu'un scan
        // complet par rangée : la grille combinée peut compter des milliers
        // de photos.
        let counts = Dictionary(grouping: session.items.compactMap(\.origin), by: { $0 })
            .mapValues(\.count)

        return NavigationStack {
            List {
                Section("Dans cette grille") {
                    ForEach(session.sources, id: \.self) { source in
                        row(for: source, count: counts[source] ?? 0)
                            // Retrait par balayage. **Pas** `.onDelete` : sur un
                            // tableau calculé d'un observable, le coordinateur
                            // de liste plante quand la suppression fait basculer
                            // `canRemove` (retrait de l'affordance en pleine
                            // animation). Un bouton de swipe explicite n'a pas
                            // cette machinerie d'index.
                            .swipeActions(edge: .trailing) {
                                if canRemove {
                                    Button(role: .destructive) {
                                        onRequest(.remove(source))
                                    } label: {
                                        Label("Retirer", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }

                Section("Nouvelle source") {
                    Picker("Action", selection: $mode) {
                        Text("Remplacer").tag(Mode.replace)
                        Text("Ajouter").tag(Mode.add)
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)

                    Button { open(.folder) } label: {
                        Label("Dossier / carte SD", systemImage: "folder")
                    }
                    Button { open(.albumPicker) } label: {
                        Label("Album Photos", systemImage: "photo.stack")
                    }
                    Button { open(.library) } label: {
                        Label("Toutes les photos", systemImage: "photo.on.rectangle.angled")
                    }

                    // Récents (historique), dans la même liste. Dossiers **et**
                    // albums déjà utilisés portent la même icône « historique »
                    // pour l'homogénéité — le nom les distingue. La bascule
                    // Remplacer/Ajouter ci-dessus s'y applique aussi.
                    // Récents éditables : swipe ou mode « Modifier » suppriment
                    // l'entrée de l'historique (via `.onDelete`, sûr ici car la
                    // liste est un tableau stocké passé en valeur — pas le
                    // tableau calculé d'un observable qui plante le coordinateur,
                    // cf. la section « Dans cette grille »).
                    ForEach(recentFolders) { folder in
                        Button { open(.recentFolder(folder)) } label: {
                            // Nom dynamique : verbatim, pas de localisation.
                            Label {
                                Text(folder.name)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { onDeleteRecentFolder(recentFolders[index]) }
                    }
                    ForEach(recentAlbums) { album in
                        Button { open(.album(id: album.id, title: album.title)) } label: {
                            Label {
                                Text(album.title)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { onDeleteRecentAlbum(recentAlbums[index]) }
                    }
                }

                Section {
                    Text(mode == .add
                        ? "« Ajouter » compose la source choisie avec celles déjà dans la grille."
                        : "« Remplacer » ouvre une nouvelle session sur la source choisie.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        dismiss()
                        onRequest(.welcome)
                    } label: {
                        Label("Accueil", systemImage: "house")
                    }
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // « Modifier » n'a de prise que sur l'historique des récents ;
                // on ne le propose donc que s'il y en a.
                if !recentFolders.isEmpty || !recentAlbums.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(for source: PhotoSource, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .lineLimit(1)
                Text(photoCountText(count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Ouvre un type de source (ou un récent) : la bascule décide s'il
    /// **remplace** la session (demande nue) ou s'y **ajoute** (`.add`). On
    /// referme le hub d'abord pour ne pas empiler le picker sur la sheet.
    private func open(_ inner: SourceRequest) {
        dismiss()
        onRequest(mode == .add ? .add(inner) : inner)
    }
}
