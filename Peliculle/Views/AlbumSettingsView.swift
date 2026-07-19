import SwiftUI

/// Réglage de l'album de destination (idée 8bis), en sheet demi-hauteur.
/// Deux portes d'entrée :
/// - le bouton album de la grille ou le menu ⋯ du viewer (modification
///   rapide, CTA « OK ») ;
/// - le **premier enregistrement** de la session (confirmation, CTA
///   « Enregistrer n photo(s) ») — ensuite le choix est mémorisé et on
///   n'interrompt plus jamais le flux d'enregistrement.
///
/// Les bindings écrivent directement dans `session.albumDestination` : le
/// réglage est appliqué (et persisté) même si la sheet est balayée sans CTA ;
/// seul l'enregistrement en attente exige la confirmation explicite.
struct AlbumSettingsView: View {
    @Bindable var session: CullSession
    /// Libellé du bouton de validation (« OK », ou l'action d'enregistrement
    /// en attente).
    let confirmLabel: String
    let onConfirm: () -> Void

    /// Derniers noms d'albums utilisés, tous dossiers confondus : retomber
    /// sur « Portugal » d'une carte à l'autre sans le retaper.
    @State private var recentNames =
        UserDefaults.standard.stringArray(forKey: Self.recentNamesKey) ?? []

    private static let recentNamesKey = "peliculle.recentAlbumNames"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type d'album", selection: $session.albumDestination.mode) {
                        ForEach(AlbumDestination.Mode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(destinationSummary)
                }

                if session.albumDestination.mode == .named {
                    Section {
                        TextField(
                            "Nom de l'album (Portugal, Lisbonne…)",
                            text: $session.albumDestination.customName
                        )
                        .textInputAutocapitalization(.words)
                        Toggle("Ajouter la date", isOn: $session.albumDestination.appendDate)
                    } footer: {
                        Text("Avec la date : un album par jour dans le contexte du voyage (« Portugal — 8 juil. 2026 »).")
                    }

                    if !recentNames.isEmpty {
                        Section("Récents") {
                            ForEach(recentNames, id: \.self) { name in
                                Button(name) {
                                    session.albumDestination.customName = name
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }

                    // Jalon 8 (bonus GPS) — lieux des photos de la session
                    // comme noms d'album (idée 15). Opportuniste : seuls les
                    // lieux déjà résolus par `PlaceResolver` apparaissent,
                    // aucune requête réseau déclenchée d'ici.
                    if !suggestedPlaces.isEmpty {
                        Section("Lieux du dossier") {
                            ForEach(suggestedPlaces, id: \.self) { name in
                                Button {
                                    session.albumDestination.customName = name
                                } label: {
                                    Label(name, systemImage: "mappin.and.ellipse")
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Album d'enregistrement")
            .navigationBarTitleDisplayMode(.inline)
            // Revue UX (UX1) — le CTA vivait en `ToolbarItem` en haut de la
            // sheet : discret, loin du pouce, et confondu avec un « OK » de
            // réglage alors qu'au premier enregistrement il déclenche la
            // sauvegarde. Épinglé **sous les destinations**, pleine largeur,
            // proéminent : le flux de lecture (choisir la destination) se
            // termine sur le flux d'action (valider), dans la zone du pouce.
            // `safeAreaInset` : le formulaire défile dessous, le CTA reste.
            .safeAreaInset(edge: .bottom) {
                Button {
                    rememberName()
                    session.confirmAlbum()
                    onConfirm()
                } label: {
                    Text(confirmLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .presentationDetents([.medium])
    }

    /// Lieux déjà géocodés des photos de la session, du plus fréquent au
    /// moins fréquent, hors doublons avec les récents. Trois suffisent.
    private var suggestedPlaces: [String] {
        var counts: [String: Int] = [:]
        for item in session.items {
            if let place = item.place {
                counts[place, default: 0] += 1
            }
        }
        return Array(
            counts.sorted { $0.value > $1.value }
                .map(\.key)
                .filter { !recentNames.contains($0) }
                .prefix(3)
        )
    }

    private var destinationSummary: String {
        // Batch H5 — session combinée (carte + photothèque) : un album est
        // requis pour les assets (rien à copier, ajout à l'album), tandis que
        // les fichiers de la carte sont copiés dans la pellicule.
        if !session.isLibraryOnly && session.hasLibrarySource {
            if let title = session.albumDestination.resolvedTitle {
                return String(localized: "Album « \(title) » : les photos de la photothèque y sont ajoutées, les fichiers de la carte copiés dans la pellicule.")
            }
            return String(localized: "Choisissez un album : les photos de la photothèque s'y rangent (rien à copier), les fichiers de la carte vont dans la pellicule.")
        }
        // Jalon 10 — sur une source photothèque, les photos sont déjà sur
        // place : la destination est un **ajout à l'album**, jamais une copie.
        if session.isLibraryOnly {
            if let title = session.albumDestination.resolvedTitle {
                return String(localized: "Garder = ajouter à l'album « \(title) ». Les photos restent où elles sont, rien n'est copié.")
            }
            return String(localized: "Sans album de destination, il n'y a rien à ranger sur cette source : choisissez un album.")
        }
        if let title = session.albumDestination.resolvedTitle {
            return String(localized: "Les photos enregistrées iront dans l'album « \(title) ». Nécessite l'accès complet à la photothèque ; sinon elles sont enregistrées sans album.")
        }
        return String(localized: "Les photos seront enregistrées dans la pellicule, sans album.")
    }

    private func rememberName() {
        guard session.albumDestination.mode == .named else { return }
        let name = session.albumDestination.customName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var names = recentNames.filter { $0 != name }
        names.insert(name, at: 0)
        recentNames = Array(names.prefix(5))
        UserDefaults.standard.set(recentNames, forKey: Self.recentNamesKey)
    }
}
