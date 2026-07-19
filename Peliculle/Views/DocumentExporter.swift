import SwiftUI
import UIKit

/// « Exporter vers Fichiers » : copie des fichiers de la carte vers une
/// destination choisie (iCloud Drive, stockage local…) via le sélecteur
/// d'export du système. `asCopy: true` — les originaux de la carte ne bougent
/// pas, cohérent avec le principe carte-intacte.
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    var onDone: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onDone()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDone()
        }
    }
}
