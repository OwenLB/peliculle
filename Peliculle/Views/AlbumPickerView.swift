import Photos
import SwiftUI

/// Jalon 10 — sheet de choix d'un album de la photothèque comme **source de
/// tri** : vignette de couverture, nom, compte de photos. Liste native
/// (`List`), état vide dédié. L'autorisation a été obtenue par l'appelant.
struct AlbumPickerView: View {
    var onPick: (PhotoLibrarySource.AlbumInfo) -> Void

    @State private var albums: [PhotoLibrarySource.AlbumInfo]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let albums {
                    if albums.isEmpty {
                        ContentUnavailableView(
                            "Aucun album",
                            systemImage: "photo.stack",
                            description: Text("Votre photothèque ne contient pas d'album.")
                        )
                    } else {
                        List(albums) { album in
                            Button {
                                onPick(album)
                            } label: {
                                AlbumRow(album: album)
                            }
                            .foregroundStyle(.primary)
                        }
                        .listStyle(.plain)
                    }
                } else {
                    ProgressView("Lecture des albums…")
                }
            }
            .navigationTitle("Choisir un album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .task {
                albums = await PhotoLibrarySource.userAlbums()
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Une rangée d'album : vignette carrée (chargée paresseusement via le cache
/// d'aperçus partagé), titre, compte.
private struct AlbumRow: View {
    let album: PhotoLibrarySource.AlbumInfo

    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                Text(photoCountText(album.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: album.id) {
            guard cover == nil, let asset = album.coverAsset else { return }
            cover = await ThumbnailLoader.load(.asset(asset), maxPixel: 160)
        }
    }
}
