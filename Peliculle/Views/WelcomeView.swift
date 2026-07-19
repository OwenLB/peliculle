import SwiftUI

/// Écran d'accueil. La carte SD reste l'action **primaire**
/// (`.glassProminent`) ; les sources photothèque (Jalon 10) en actions
/// secondaires. SF Symbols, materials système, Dynamic Type. `notice` affiche
/// un message contextuel (carte non retrouvée, carte déconnectée…).
///
/// Revue UX (UX4) — section « Reprendre » : une carte par source récente
/// (dossiers et albums déjà mémorisés pour le menu Source de la grille),
/// un tap rouvre la session. Le cas « je rebranche la carte d'hier » ne
/// repasse plus par le sélecteur de fichiers.
struct WelcomeView: View {
    var notice: String?
    var recentFolders: [RecentFolder] = []
    var recentAlbums: [RecentAlbum] = []
    var onPick: () -> Void
    var onPickAlbum: () -> Void
    var onPickLibrary: () -> Void
    /// Ouverture d'une source récente — même requête que le menu Source de
    /// la grille, résolue par `ContentView`.
    var onOpenRecent: (SourceRequest) -> Void = { _ in }
    /// Retrait d'une entrée de l'historique (bouton « Modifier » ou swipe).
    var onDeleteRecentFolder: (RecentFolder) -> Void = { _ in }
    var onDeleteRecentAlbum: (RecentAlbum) -> Void = { _ in }

    @State private var isEditingRecents = false

    var body: some View {
        VStack(spacing: 24) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .clipShape(.rect(cornerRadius: 21))

            VStack(spacing: 8) {
                Text("Pelicull(e)")
                    .font(.largeTitle.bold())
                Text("Triez vos photos directement depuis la carte SD, sans import préalable.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            // Trois boutons empilés, même gabarit (`maxWidth` dans le label
            // + `controlSize` commun) ; la carte SD reste l'action primaire
            // par son style prominent, pas par sa taille.
            VStack(spacing: 12) {
                Button(action: onPick) {
                    Label("Choisir un dossier", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                // Jalon 10 — même workflow de tri sur la photothèque : une
                // source à la fois, jamais de fusion.
                Button(action: onPickAlbum) {
                    Label("Album Photos", systemImage: "photo.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                Button(action: onPickLibrary) {
                    Label("Toutes mes photos", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .frame(maxWidth: 320)
            .padding(.top, 8)

            if !recentFolders.isEmpty || !recentAlbums.isEmpty {
                resumeSection
            }

            // Seul écran « à propos » à ce jour : la version vit ici (et en
            // tête du diagnostic de session), discrète, hors du flux.
            Text("Version \(AppVersion.display)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Reprendre (Revue UX, UX4)

    /// Sources récentes en **lignes** (icône + nom sur la même ligne, retour
    /// Owen : pas de cartes), dossiers d'abord (le flux carte SD est le cœur
    /// de l'app) puis albums — mêmes listes, même ordre que le menu Source.
    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Reprendre")
                    .font(.headline)
                Spacer(minLength: 8)
                // « Modifier » révèle un bouton de suppression par ligne ; le
                // swipe reste disponible hors édition. Symétrique du hub Sources.
                Button(isEditingRecents ? "OK" : "Modifier") {
                    withAnimation(.snappy) { isEditingRecents.toggle() }
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            ForEach(recentFolders) { folder in
                ResumeRow(
                    name: folder.name,
                    icon: folder.kind.icon,
                    isEditing: isEditingRecents,
                    onOpen: { onOpenRecent(.recentFolder(folder)) },
                    onDelete: { onDeleteRecentFolder(folder) }
                )
            }
            ForEach(recentAlbums) { album in
                ResumeRow(
                    name: album.title,
                    icon: "photo.stack",
                    isEditing: isEditingRecents,
                    onOpen: { onOpenRecent(.album(id: album.id, title: album.title)) },
                    onDelete: { onDeleteRecentAlbum(album) }
                )
            }
        }
        .frame(maxWidth: 360)
        // Plus rien à éditer : on sort du mode pour ne pas rouvrir « OK » à vide.
        .onChange(of: recentFolders.count + recentAlbums.count) { _, total in
            if total == 0 { isEditingRecents = false }
        }
    }
}

/// Une ligne de la section « Reprendre ». Hors d'une `List` (l'accueil est un
/// `VStack` centré), le swipe et le mode édition sont faits main : glissement
/// vers la gauche pour révéler « Supprimer », ou bouton rouge permanent quand
/// « Modifier » est actif.
private struct ResumeRow: View {
    let name: String
    let icon: String
    let isEditing: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0

    private let revealWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            // Affordance de suppression révélée par le balayage.
            Button {
                delete()
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
            }
            .opacity(offset < 0 ? 1 : 0)

            rowContent
                .background(Color(.systemBackground))
                .offset(x: offset)
                .gesture(isEditing ? nil : swipe)
        }
        .clipShape(.rect(cornerRadius: 12))
        .onChange(of: isEditing) { _, editing in
            // Entrer/sortir d'édition remet toute ligne demi-balayée à plat.
            if editing { withAnimation(.snappy) { offset = 0 } }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if isEditing {
                Button(action: delete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                // Largeur fixe : les noms s'alignent quelle que soit l'icône
                // (carte SD, album, iCloud…).
                .frame(width: 26)
            Text(name)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if !isEditing {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .onTapGesture {
            // Une ligne balayée se referme au tap ; sinon le tap ouvre.
            if offset < 0 {
                withAnimation(.snappy) { offset = 0 }
            } else if !isEditing {
                onOpen()
            }
        }
    }

    /// Balayage horizontal vers la gauche uniquement — révèle « Supprimer »
    /// sans jamais dépasser sa largeur.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = value.translation.width
                if dx < 0 {
                    offset = max(dx, -revealWidth)
                } else if offset < 0 {
                    offset = min(0, -revealWidth + dx)
                }
            }
            .onEnded { value in
                withAnimation(.snappy) {
                    offset = value.translation.width < -revealWidth / 2 ? -revealWidth : 0
                }
            }
    }

    private func delete() {
        withAnimation(.snappy) { offset = 0 }
        onDelete()
    }
}

#Preview {
    NavigationStack {
        WelcomeView(notice: nil, onPick: {}, onPickAlbum: {}, onPickLibrary: {})
    }
}
