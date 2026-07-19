import SwiftUI

/// Revue UX (UX5, point 9) — les filtres sortent du menu de toolbar : un
/// menu iOS est fait pour 3-6 actions, pas pour 4 sections, ~10 entrées et
/// des sous-menus imbriqués. Bottom sheet (`medium`/`large`) : tout est
/// visible d'un coup, les bindings écrivent directement dans l'état de la
/// grille (l'effet se voit derrière la sheet en détente medium), et le CTA
/// « Voir n photos » — mis à jour en direct — dit l'effet des filtres avant
/// de fermer. La plage de dates vit enfin au même endroit que le reste :
/// l'ancienne `DateFilterView` séparée n'existait que parce que les
/// DatePicker ne vivent pas dans un Menu.
struct FilterSheet: View {
    let session: CullSession

    // Tri et affichage (réglages persistants de la grille).
    @Binding var sort: PhotoSort
    @Binding var sortAscending: Bool
    @Binding var groupBursts: Bool
    @Binding var groupByDay: Bool

    /// Les filtres, en **une seule valeur** (revue qualité) : les dix
    /// dimensions arrivaient en autant de bindings séparés.
    @Binding var filters: GridFilters

    /// Photographie du rendu de la grille — listes des pickers (peuplées au
    /// fil de l'indexation paresseuse) et compteur du CTA. Recalculée par
    /// `GridView` à chaque changement de filtre : le CTA vit tout seul.
    let availableFormats: [FormatFilter]
    let cameras: [String]
    let lenses: [String]
    let hasGeolocated: Bool
    let matchCount: Int
    let isFiltering: Bool
    let onReset: () -> Void

    /// Même clé que la grille et la sheet Réglages : le seuil de rafale
    /// conditionne le toggle de groupement.
    @AppStorage("burstThreshold") private var burstThreshold = 1.0

    @State private var showMap = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                filterSection
                dateSection
                exifSection
                ratingSection
                if isFiltering {
                    Section {
                        Button("Effacer tous les filtres", role: .destructive) {
                            onReset()
                        }
                    }
                }
            }
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            // CTA vivant (Revue UX) : l'effet des filtres se lit avant de
            // valider. Zéro résultat → bouton inerte, la grille vide n'a
            // rien à montrer (la section « Effacer » est alors affichée).
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text(ctaLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .disabled(matchCount == 0)
            }
        }
        .presentationDetents([.medium, .large])
        // Idée 16 — la carte reste une entrée de cette surface : présentée
        // par-dessus la sheet, elle revient ici à la fermeture.
        .fullScreenCover(isPresented: $showMap) {
            PhotoMapView(session: session)
        }
        // Nouveau critère choisi : repartir de son sens naturel (l'inversion
        // se fait via le picker d'ordre).
        .onChange(of: sort) { _, newSort in
            sortAscending = newSort.defaultAscending
        }
    }

    private var ctaLabel: String {
        switch matchCount {
        case 0: return String(localized: "Aucune photo pour ces filtres")
        case 1: return String(localized: "Voir 1 photo")
        default: return String(localized: "Voir \(matchCount) photos")
        }
    }

    // MARK: - Filtre « déjà rangée ? » (Batch H5)

    /// Affiché seulement là où « rangée » a un sens : source externe
    /// (téléchargement), ou photothèque avec un album de destination réel
    /// (appartenance). Une photothèque en destination « aucun album » le masque.
    private var showsSavedFilter: Bool {
        session.hasFileSource
            || (session.hasLibrarySource && session.albumDestination.resolvedTitle != nil)
    }

    /// Titre du picker : appartenance à l'album pour une photothèque pure,
    /// téléchargement dès qu'une source fichier est en jeu (dont le combiné).
    private var savedFilterTitle: String {
        session.isLibraryOnly
            ? String(localized: "Album de destination")
            : String(localized: "Téléchargement")
    }

    /// Icône distincte selon le sens (retour Owen : pas la même que la carte).
    private var savedFilterIcon: String {
        session.isLibraryOnly ? "rectangle.stack" : "icloud.and.arrow.down"
    }

    // MARK: - Affichage

    private var displaySection: some View {
        // Icônes de tête en `.primary` (retour Owen) : blanc en mode sombre,
        // noir en clair — monochrome propre plutôt que l'accent bleu par
        // défaut des Label de liste. La bascule verte des Toggle et la valeur
        // choisie (grise) des pickers gardent leur couleur.
        Section("Affichage") {
            Picker("Trier par", systemImage: "arrow.up.arrow.down", selection: $sort) {
                ForEach(PhotoSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(.primary)
            Picker("Ordre", systemImage: sortAscending ? "arrow.up" : "arrow.down", selection: $sortAscending) {
                Text("Croissant").tag(true)
                Text("Décroissant").tag(false)
            }
            .pickerStyle(.segmented)
            if burstThreshold > 0 {
                Toggle(isOn: $groupBursts) {
                    Label("Grouper les rafales", systemImage: "square.stack")
                        .foregroundStyle(.primary)
                }
            }
            Toggle(isOn: $groupByDay) {
                Label("Grouper par jour", systemImage: "calendar")
                    .foregroundStyle(.primary)
            }
            if hasGeolocated {
                Button {
                    showMap = true
                } label: {
                    Label("Carte des photos", systemImage: "map")
                        .foregroundStyle(.primary)
                }
                // `.plain` : sans ça, le style bouton automatique reteinte le
                // libellé en bleu d'accent par-dessus le foregroundStyle.
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Filtres

    private var filterSection: some View {
        Section("Filtres") {
            Picker("État de tri", systemImage: "checkmark.circle", selection: $filters.decision) {
                ForEach(DecisionFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(.primary)
            // Batch H5 — filtre « déjà rangée ? », au sens de la source :
            // téléchargement pour une carte, appartenance à l'album de
            // destination pour une photothèque. Masqué là où il n'a pas d'objet
            // (photothèque sans album de destination).
            if showsSavedFilter {
                Picker(savedFilterTitle, systemImage: savedFilterIcon, selection: $filters.saved) {
                    ForEach(SavedFilter.allCases) { option in
                        Text(option.label(isLibrary: session.isLibraryOnly)).tag(option)
                    }
                }
                .foregroundStyle(.primary)
            }
            if availableFormats.count > 2 {
                Picker("Format", systemImage: "doc", selection: $filters.format) {
                    ForEach(availableFormats) { option in
                        Text(option.label).tag(option)
                    }
                }
                .foregroundStyle(.primary)
            }
            Picker("Orientation", systemImage: "rectangle.on.rectangle.angled", selection: $filters.orientation) {
                ForEach(OrientationFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    // MARK: - Dates

    /// La plage Du/Au, enfin avec les autres filtres (ex-`DateFilterView`).
    /// En Mode Voyage, la plage du voyage fait autorité : affichée
    /// verrouillée, elle se modifie dans le drawer Voyage (Réglages).
    @ViewBuilder
    private var dateSection: some View {
        if session.trip.isActive {
            // Forme `header:footer:content:` (arguments, pas closures multiples) :
            // SourceKit résout mal les trailing closures multiples de Section
            // (faux positif « Cannot convert String to () -> Content » dans
            // l'éditeur, alors que la compilation passe) — cette forme lève
            // l'ambiguïté.
            Section(
                header: Text("Dates"),
                footer: Text("Le Mode Voyage borne déjà l'affichage — la plage se règle dans le drawer Voyage.")
            ) {
                Label(
                    rangeSummary(
                        start: session.trip.startDate,
                        end: session.trip.endDate,
                        fallback: String(localized: "Voyage")
                    ),
                    systemImage: "airplane"
                )
                .foregroundStyle(.secondary)
            }
        } else {
            Section(
                header: Text("Dates"),
                footer: Text("Sur la date de prise de vue (à défaut, la date du fichier). Les photos sans date sont masquées quand une borne est active.")
            ) {
                Toggle("À partir du", isOn: hasStart)
                if filters.dateRange.start != nil {
                    DatePicker(
                        "Début",
                        selection: startDate,
                        in: ...(filters.dateRange.end ?? .distantFuture),
                        displayedComponents: .date
                    )
                }
                Toggle("Jusqu'au", isOn: hasEnd)
                if filters.dateRange.end != nil {
                    DatePicker(
                        "Fin",
                        selection: endDate,
                        in: (filters.dateRange.start ?? .distantPast)...,
                        displayedComponents: .date
                    )
                }
            }
        }
    }

    // MARK: - EXIF

    private var exifSection: some View {
        Section("EXIF") {
            Picker("ISO", systemImage: "dial.medium", selection: $filters.iso) {
                ForEach(ISOFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(.primary)
            Picker("Focale", systemImage: "camera.viewfinder", selection: $filters.focal) {
                ForEach(FocalFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .foregroundStyle(.primary)
            if cameras.count > 1 {
                Picker("Boîtier", systemImage: "camera", selection: $filters.camera) {
                    Text("Tous").tag(String?.none)
                    ForEach(cameras, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .foregroundStyle(.primary)
            }
            if lenses.count > 1 {
                Picker("Objectif", systemImage: "camera.aperture", selection: $filters.lens) {
                    Text("Tous").tag(String?.none)
                    ForEach(lenses, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Note minimale

    private var ratingSection: some View {
        Section("Note minimale") {
            Picker("Note minimale", systemImage: filters.minRating > 0 ? "star.fill" : "star", selection: $filters.minRating) {
                Text("Toutes").tag(0)
                ForEach(1...5, id: \.self) { rating in
                    Text(String(localized: "\(rating) étoile(s) et plus")).tag(rating)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    // MARK: - Bindings dates (ex-DateFilterView)

    /// Proposition d'ouverture de la borne basse : la plus ancienne date
    /// connue de la session (proposer aujourd'hui masquerait presque tout).
    private var earliestDate: Date {
        session.items.compactMap(\.captureDate).min()
            ?? Calendar.current.startOfDay(for: .now)
    }

    private var hasStart: Binding<Bool> {
        Binding(
            get: { filters.dateRange.start != nil },
            set: { on in
                filters.dateRange.start = on ? Calendar.current.startOfDay(for: earliestDate) : nil
            }
        )
    }

    private var startDate: Binding<Date> {
        Binding(
            get: { filters.dateRange.start ?? earliestDate },
            set: { filters.dateRange.start = $0 }
        )
    }

    /// L'ouvrir propose aujourd'hui (jamais avant la borne basse).
    private var hasEnd: Binding<Bool> {
        Binding(
            get: { filters.dateRange.end != nil },
            set: { on in
                filters.dateRange.end = on
                    ? max(Calendar.current.startOfDay(for: .now), filters.dateRange.start ?? .distantPast)
                    : nil
            }
        )
    }

    private var endDate: Binding<Date> {
        Binding(
            get: { filters.dateRange.end ?? .now },
            set: { filters.dateRange.end = $0 }
        )
    }

    private func rangeSummary(start: Date?, end: Date?, fallback: String) -> String {
        let day = { (date: Date) in date.formatted(date: .abbreviated, time: .omitted) }
        switch (start, end) {
        case let (start?, end?):
            return String(localized: "Du \(day(start)) au \(day(end))")
        case let (start?, nil):
            return String(localized: "Depuis le \(day(start))")
        case let (nil, end?):
            return String(localized: "Jusqu'au \(day(end))")
        case (nil, nil):
            return fallback
        }
    }
}
