import MapKit
import SwiftUI

/// Idée 16 (bonus GPS) — carte des photos géolocalisées de la session.
/// Clustering « maison » : le `Map` SwiftUI n'expose pas
/// `MKClusterAnnotation`, on regroupe donc par case de grille
/// proportionnelle au zoom, recalculée quand la caméra bouge. Tap sur un
/// groupe → viewer paginé sur ses photos. Les photos sans GPS sont comptées
/// dans un bandeau, jamais perdues de vue.
struct PhotoMapView: View {
    let session: CullSession

    @Environment(\.dismiss) private var dismiss

    /// Empan courant de la caméra (nil avant le premier mouvement).
    @State private var span: MKCoordinateSpan?
    @State private var viewerContext: ViewerContext?
    @State private var isIndexing = true

    private struct Located {
        let item: PhotoItem
        let coordinate: CLLocationCoordinate2D
    }

    private struct Cluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let items: [PhotoItem]
    }

    private var locatedItems: [Located] {
        session.items.compactMap { item in
            guard let latitude = item.exif?.latitude,
                  let longitude = item.exif?.longitude else { return nil }
            return Located(
                item: item,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
    }

    /// Regroupement par case d'environ 1/8 de la hauteur visible ; avant le
    /// premier mouvement de caméra, une case fixe (~1 km).
    private var clusters: [Cluster] {
        let located = locatedItems
        guard !located.isEmpty else { return [] }
        let cell = max((span?.latitudeDelta ?? 0.1) / 8, 0.0001)
        var order: [String] = []
        var groups: [String: [Located]] = [:]
        for entry in located {
            let key = "\(Int((entry.coordinate.latitude / cell).rounded()))|"
                + "\(Int((entry.coordinate.longitude / cell).rounded()))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { key in
            let members = groups[key] ?? []
            let latitude = members.map { $0.coordinate.latitude }
                .reduce(0, +) / Double(members.count)
            let longitude = members.map { $0.coordinate.longitude }
                .reduce(0, +) / Double(members.count)
            return Cluster(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                items: members.map(\.item)
            )
        }
    }

    private var unlocatedCount: Int {
        session.items.count - locatedItems.count
    }

    var body: some View {
        NavigationStack {
            Map {
                ForEach(clusters) { cluster in
                    Annotation("", coordinate: cluster.coordinate) {
                        Button {
                            viewerContext = ViewerContext(
                                start: cluster.items[0],
                                items: cluster.items
                            )
                        } label: {
                            clusterBadge(count: cluster.items.count)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onMapCameraChange { context in
                span = context.region.span
            }
            .navigationTitle("Carte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                footer
            }
            .navigationDestination(item: $viewerContext) { context in
                FullScreenViewer(
                    session: session,
                    items: context.items,
                    startIndex: context.items.firstIndex(of: context.start) ?? 0
                )
            }
            // La carte se remplit au fil de l'indexation des photos jamais
            // affichées en grille (cache partagé avec le reste de l'app).
            .task {
                // Idée 18 — pas d'EXIF image sur un clip : inutile de tenter.
                for item in session.items where item.exif == nil && !item.isVideo {
                    guard !Task.isCancelled else { return }
                    item.exif = await ExifIndexer.shared.exif(for: item.backing)
                }
                isIndexing = false
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let parts: [String] = [
            isIndexing ? String(localized: "Lecture des positions…") : nil,
            unlocatedCount > 0
                ? String(localized: "\(unlocatedCount) photo(s) sans localisation")
                : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 8)
        }
    }

    private func clusterBadge(count: Int) -> some View {
        Text("\(count)")
            .font(.callout.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 22)
            .padding(8)
            .background(.blue.gradient, in: .circle)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(radius: 3)
            .accessibilityLabel("\(count) photo(s) ici")
    }
}
