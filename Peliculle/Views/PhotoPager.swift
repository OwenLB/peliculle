import SwiftUI
import UIKit

/// Pager horizontal du viewer plein écran (F3), bâti sur
/// `UIPageViewController` — le composant natif des visionneuses photo.
///
/// **Pourquoi UIKit ici.** Le défilement entre photos doit être *à la fois*
/// continu au doigt (la photo suit la main, rubber-band aux extrémités, snap
/// à la vélocité, geste annulable) **et** pilotable par code avec la même
/// animation, pour que « Garder » fasse glisser la page exactement comme un
/// swipe. Aucune des deux approches précédentes ne donnait les deux :
/// `TabView(.page)` offrait le geste natif mais son animation est une boîte
/// noire qu'on ne peut pas déclencher par code (d'où l'avance « instantanée »
/// qui remplaçait la photo) ; des `UISwipeGestureRecognizer` directionnels
/// donnaient la main sur l'animation mais sont des gestes **discrets** —
/// tout-ou-rien, sans suivi du doigt, sourds à un swipe lent.
/// `setViewControllers(direction:animated:)` réunit les deux : c'est le
/// **même** défilement pour le geste et pour le bouton.
///
/// **Paresseux par construction** : seules la page courante et, pendant un
/// geste, ses voisines immédiates sont vivantes — plus de fenêtre de pages à
/// maintenir à la main. Les contrôleurs restent en cache dans un rayon
/// étroit (`hostWindowRadius`), donc l'état d'une page (aperçu déjà décodé,
/// niveau de zoom) survit à un aller-retour, mais la mémoire reste bornée.
///
/// **Cohabitation avec le zoom** : au zoom minimal, `ZoomableScrollView`
/// coupe son propre défilement (`isScrollEnabled = false`), le pan revient
/// donc naturellement au pager ; dès qu'on zoome, le viewer passe
/// `pagingEnabled: false` et le pan sert exclusivement au recadrage — plus
/// aucun arbitrage ambigu entre les deux scroll views.
struct PhotoPager<Page: View>: UIViewControllerRepresentable {
    let items: [PhotoItem]
    /// Photo affichée. Piloté dans les **deux** sens : le geste écrit
    /// l'index atteint, un changement venu du code (bouton de tri, tap dans
    /// le filmstrip) fait défiler le pager.
    @Binding var index: Int
    /// Faux pendant le zoom d'inspection : le pan appartient alors à la vue
    /// zoomable, pas au pager (sinon un pan jusqu'au bord de l'image fait
    /// tourner la page).
    var pagingEnabled: Bool = true
    @ViewBuilder var page: (PhotoItem) -> Page

    /// Gouttière entre deux pages, visible seulement pendant le glissement —
    /// le fond du viewer la traverse (vue du pager transparente).
    private static var interPageSpacing: CGFloat { 20 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: Self.interPageSpacing]
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        // Transparent : le fond adaptatif du viewer (clair/sombre) traverse
        // la gouttière inter-pages, qui ne doit jamais flasher en noir.
        pager.view.backgroundColor = .clear
        context.coordinator.attach(to: pager)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.update(with: self)
    }

    static func dismantleUIViewController(_ pager: UIPageViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        /// Rayon du cache de contrôleurs autour de la page courante. 2 suffit :
        /// le pager ne matérialise jamais plus que la page ± 1, le troisième
        /// cran absorbe un aller-retour sans re-décoder.
        private static var hostWindowRadius: Int { 2 }

        /// Une page vivante : son contrôleur et la photo qu'elle affiche. La
        /// photo est **gardée avec** le contrôleur pour que le rafraîchissement
        /// n'ait jamais à la rechercher dans `items` — sur une session de 1 000
        /// photos, un balayage par passe de `body` est exactement le genre de
        /// coût O(n) que la passe de perf a chassé partout ailleurs.
        private struct Host {
            let item: PhotoItem
            let controller: UIHostingController<Page>
        }

        private var parent: PhotoPager
        private weak var pager: UIPageViewController?
        private var hosts: [PhotoItem.ID: Host] = [:]
        /// Chemin inverse contrôleur → photo : le pager nous rend des
        /// `UIViewController` bruts, il faut savoir à quelle photo ils
        /// correspondent pour calculer les voisines.
        private var hostIDs: [ObjectIdentifier: PhotoItem.ID] = [:]
        /// Photo **réellement** à l'écran (ou destination d'une transition en
        /// cours). Distingue « le binding a changé, il faut défiler » de
        /// « le geste vient de nous signaler son arrivée » — sans ce miroir,
        /// les deux sens se déclencheraient l'un l'autre en boucle.
        private var displayedID: PhotoItem.ID?
        /// Vrai pendant **toute** transition, gestuelle comme programmée.
        /// Enchaîner un `setViewControllers` par-dessus une transition en cours
        /// est la façon classique de mettre un `UIPageViewController` dans un
        /// état incohérent (page blanche, voisines fausses) : on attend.
        private var isTransitioning = false
        /// Une synchronisation a été demandée pendant qu'une transition jouait
        /// (martèlement de « Garder ») : rejouée à la fin plutôt que perdue.
        private var needsSync = false
        /// Index affiché juste avant qu'un geste ne commence, pour pouvoir le
        /// restaurer si ce geste est finalement abandonné (voir
        /// `willTransitionTo`).
        private var indexBeforeTransition: Int?

        init(_ parent: PhotoPager) {
            self.parent = parent
        }

        func attach(to pager: UIPageViewController) {
            self.pager = pager
            applyPagingEnabled()
            show(index: parent.index, animated: false)
        }

        func detach() {
            hosts.removeAll()
            hostIDs.removeAll()
            pager = nil
        }

        // MARK: - Synchronisation SwiftUI → pager

        func update(with parent: PhotoPager) {
            self.parent = parent
            // Rafraîchir **avant** de défiler : la page qui entre doit porter
            // l'état courant (chrome masqué, liseré de décision…), sinon elle
            // glisse avec un rendu d'un cycle de retard.
            refreshHosts()
            applyPagingEnabled()
            show(index: parent.index, animated: true)
            pruneHosts()
        }

        /// Le contenu SwiftUI d'une page dépend de l'état du viewer (mode
        /// immersif, hauteur de la pilule, flash de décision) : chaque passe
        /// de `body` en repose une version fraîche sur les pages vivantes.
        /// Réassigner `rootView` **préserve** le `@State` de la page (aperçu
        /// chargé, pleine résolution) — c'est tout l'intérêt d'un contrôleur
        /// stable par rapport à l'ancien `.id()` qui reconstruisait tout.
        private func refreshHosts() {
            for host in hosts.values {
                host.controller.rootView = parent.page(host.item)
            }
        }

        /// Le défilement du pager vit dans un `UIScrollView` interne, non
        /// exposé par l'API — on le retrouve parmi les sous-vues. Introuvable
        /// (implémentation qui changerait), on ne fait rien : le pire cas est
        /// un pager qui reste actif au zoom, jamais un crash.
        private func applyPagingEnabled() {
            guard let pager,
                  let scrollView = pager.view.subviews.first(where: { $0 is UIScrollView })
                    as? UIScrollView
            else { return }
            scrollView.isScrollEnabled = parent.pagingEnabled
        }

        /// Fait défiler jusqu'à `index` si ce n'est pas déjà la page affichée.
        /// La direction se déduit de la position relative à la page courante :
        /// un saut depuis le filmstrip anime donc du bon côté, en arrière
        /// comme en avant (le pager ne traverse pas les pages intermédiaires,
        /// un saut de 200 photos coûte la même chose qu'un saut de 1).
        private func show(index: Int, animated: Bool) {
            guard let pager, parent.items.indices.contains(index) else { return }
            let target = parent.items[index]
            guard target.id != displayedID else { return }
            guard !isTransitioning else {
                needsSync = true
                return
            }

            let currentOffset = displayedID.flatMap { id in
                parent.items.firstIndex { $0.id == id }
            }
            // Page précédente disparue (photo supprimée) : on se repose
            // sèchement, sans animation — il n'y a plus de « depuis où ».
            let shouldAnimate = animated && currentOffset != nil
            let direction: UIPageViewController.NavigationDirection =
                (currentOffset.map { index >= $0 } ?? true) ? .forward : .reverse

            displayedID = target.id
            isTransitioning = shouldAnimate
            pager.setViewControllers(
                [host(for: target)],
                direction: direction,
                animated: shouldAnimate
            ) { [weak self] _ in
                guard let self else { return }
                self.isTransitioning = false
                self.flushPending()
            }
        }

        /// Rejoue la synchronisation différée en relisant l'index **courant**,
        /// pas celui qui avait été demandé : entre-temps le geste de
        /// l'utilisateur a pu emmener le pager ailleurs et remonter son propre
        /// index. Viser la valeur du moment fait toujours converger ; viser la
        /// valeur périmée ferait osciller les deux sources l'une contre
        /// l'autre.
        private func flushPending() {
            guard needsSync else { return }
            needsSync = false
            show(index: parent.index, animated: true)
        }

        // MARK: - Contrôleurs de page

        private func host(for item: PhotoItem) -> UIHostingController<Page> {
            if let existing = hosts[item.id] {
                existing.controller.rootView = parent.page(item)
                return existing.controller
            }
            let controller = UIHostingController(rootView: parent.page(item))
            // Le fond est porté par le viewer, pas par la page : une page
            // opaque masquerait la gouttière pendant le glissement.
            controller.view.backgroundColor = .clear
            hosts[item.id] = Host(item: item, controller: controller)
            hostIDs[ObjectIdentifier(controller)] = item.id
            return controller
        }

        /// Libère les pages sorties du voisinage (leurs aperçus 2048 px avec
        /// elles). On épargne toujours ce que le pager tient à l'écran : une
        /// page relâchée en plein geste laisserait un trou blanc.
        private func pruneHosts() {
            guard parent.items.indices.contains(parent.index) else { return }
            let lower = max(0, parent.index - Self.hostWindowRadius)
            let upper = min(parent.items.count - 1, parent.index + Self.hostWindowRadius)
            guard lower <= upper else { return }

            var kept = Set(parent.items[lower...upper].map(\.id))
            // Ce que le pager tient à l'écran est intouchable : relâcher une
            // page en plein geste laisserait un trou à la place de la photo.
            for visible in pager?.viewControllers ?? [] {
                if let id = hostIDs[ObjectIdentifier(visible)] { kept.insert(id) }
            }
            if let displayedID { kept.insert(displayedID) }

            // Clés figées avant la boucle : on mute `hosts` en la parcourant.
            for id in Array(hosts.keys) where !kept.contains(id) {
                guard let host = hosts.removeValue(forKey: id) else { continue }
                hostIDs.removeValue(forKey: ObjectIdentifier(host.controller))
            }
        }

        private func offset(of controller: UIViewController) -> Int? {
            guard let id = hostIDs[ObjectIdentifier(controller)] else { return nil }
            return parent.items.firstIndex { $0.id == id }
        }

        // MARK: - UIPageViewControllerDataSource

        /// Renvoyer `nil` aux extrémités donne le **rebond** natif : on sent
        /// qu'on est sur la première ou la dernière photo, sans blocage sec.
        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let offset = offset(of: viewController), offset > 0 else { return nil }
            return host(for: parent.items[offset - 1])
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let offset = offset(of: viewController),
                  offset < parent.items.count - 1 else { return nil }
            return host(for: parent.items[offset + 1])
        }

        // MARK: - UIPageViewControllerDelegate

        /// Un geste vient de démarrer : on s'interdit de lui passer par-dessus
        /// avec une transition programmée jusqu'à ce qu'il ait abouti (ou été
        /// abandonné).
        ///
        /// On en profite pour remonter l'index **dès le début du geste**,
        /// pas seulement à son arrivée (`didFinishAnimating`) : sinon la bande
        /// de miniatures ne démarrait son recentrage qu'une fois la photo déjà
        /// arrivée, et se voyait courir après le swipe. La page candidate
        /// (`pendingViewControllers`) est déjà connue à cet instant ; si le
        /// geste est finalement abandonné, `didFinishAnimating` restaure
        /// l'index d'avant.
        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
            guard let pending = pendingViewControllers.first,
                  let offset = offset(of: pending) else { return }
            indexBeforeTransition = parent.index
            if parent.index != offset {
                parent.index = offset
            }
        }

        /// Fin d'un geste (une transition programmée, elle, passe par sa
        /// `completion`) : on remonte l'index atteint à SwiftUI. Un geste
        /// **abandonné** en route repasse ici avec `completed == false` — la
        /// page n'a pas changé, mais l'index a déjà été avancé de façon
        /// optimiste dans `willTransitionTo` : on le restaure.
        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isTransitioning = false
            defer {
                indexBeforeTransition = nil
                flushPending()
            }
            guard completed,
                  let visible = pageViewController.viewControllers?.first,
                  let offset = offset(of: visible) else {
                if let indexBeforeTransition, parent.index != indexBeforeTransition {
                    parent.index = indexBeforeTransition
                }
                return
            }
            displayedID = parent.items[offset].id
            if parent.index != offset {
                parent.index = offset
            }
        }
    }
}
