import SwiftUI
import UIKit

/// F4 — vue d'inspection zoomable. On s'appuie sur `UIScrollView` (le pattern
/// natif le plus fiable pour le zoom photo) plutôt que sur des gestes SwiftUI :
/// pinch, double-tap et pan sont gérés par le système.
///
/// Astuce clé pour cohabiter avec le pager SwiftUI (`TabView`) : au zoom
/// minimal, on **désactive le scroll** (`isScrollEnabled = false`) ; les swipes
/// horizontaux retombent alors sur le pager pour changer de photo. Dès qu'on
/// zoome, le scroll reprend pour permettre le pan, et le pager est neutralisé.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    var onZoomChange: (Bool) -> Void
    var onSingleTap: () -> Void
    var onSwipeUp: () -> Void
    /// Navigation horizontale par swipe **directionnel** (UIKit) : gauche =
    /// suivante, droite = précédente. Directionnel exprès — un `DragGesture`
    /// SwiftUI captait tout le geste et bloquait le pull-to-dismiss vertical.
    var onSwipeLeft: () -> Void
    var onSwipeRight: () -> Void

    func makeUIView(context: Context) -> ZoomableScrollView {
        let view = ZoomableScrollView()
        view.onZoomChange = onZoomChange
        view.onSingleTap = onSingleTap
        view.onSwipeUp = onSwipeUp
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        view.displayImage = image
        return view
    }

    func updateUIView(_ view: ZoomableScrollView, context: Context) {
        view.onZoomChange = onZoomChange
        view.onSingleTap = onSingleTap
        view.onSwipeUp = onSwipeUp
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        // Ne remplace l'image (ex. aperçu → pleine résolution) que si elle a
        // réellement changé, pour ne pas réinitialiser le zoom en cours.
        if view.displayImage !== image {
            view.displayImage = image
        }
    }
}

/// `UIScrollView` autonome qui centre son image, gère le double-tap et signale
/// les transitions zoomé / non-zoomé.
final class ZoomableScrollView: UIScrollView, UIScrollViewDelegate {

    private let imageView = UIImageView()
    private let swipeUpGesture = UISwipeGestureRecognizer()
    private let swipeLeftGesture = UISwipeGestureRecognizer()
    private let swipeRightGesture = UISwipeGestureRecognizer()
    private var lastZoomedState = false

    var onZoomChange: ((Bool) -> Void)?
    var onSingleTap: (() -> Void)?
    var onSwipeUp: (() -> Void)?
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    var displayImage: UIImage? {
        didSet {
            imageView.image = displayImage
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        isScrollEnabled = false // au zoom min : laisser le pager gérer les swipes

        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        // Tap simple = bascule du HUD (chrome) : la photo passe plein écran,
        // un second tap le ramène (façon Photos.app). `require(toFail:)` : un
        // double-tap ne déclenche pas d'abord un tap simple.
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        swipeUpGesture.direction = .up
        swipeUpGesture.addTarget(self, action: #selector(handleSwipeUp))
        addGestureRecognizer(swipeUpGesture)

        // Navigation horizontale : swipes directionnels, ils laissent le
        // pull-to-dismiss vertical et le swipe-haut « garder » tranquilles.
        swipeLeftGesture.direction = .left
        swipeLeftGesture.addTarget(self, action: #selector(handleSwipeLeft))
        addGestureRecognizer(swipeLeftGesture)

        swipeRightGesture.direction = .right
        swipeRightGesture.addTarget(self, action: #selector(handleSwipeRight))
        addGestureRecognizer(swipeRightGesture)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }
        centerImage()
    }

    /// Garde l'image centrée quand elle est plus petite que la zone visible.
    private func centerImage() {
        var frame = imageView.frame
        frame.origin.x = frame.width < bounds.width ? (bounds.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < bounds.height ? (bounds.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    private func updateZoomedState() {
        let zoomed = zoomScale > minimumZoomScale + 0.01
        isScrollEnabled = zoomed
        swipeUpGesture.isEnabled = !zoomed
        // Au zoom, le pan sert à recadrer : pas de navigation horizontale.
        swipeLeftGesture.isEnabled = !zoomed
        swipeRightGesture.isEnabled = !zoomed
        if zoomed != lastZoomedState {
            lastZoomedState = zoomed
            onZoomChange?(zoomed)
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        updateZoomedState()
    }

    // MARK: - Gestures

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let target = min(maximumZoomScale, minimumZoomScale * 3)
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            zoom(to: rect, animated: true)
        }
        updateZoomedState()
    }

    /// Uniquement au zoom minimal : zoomé, un tap sert à recadrer/panner, pas
    /// à masquer le HUD (déjà masqué de toute façon).
    @objc private func handleSingleTap() {
        if zoomScale <= minimumZoomScale + 0.01 {
            onSingleTap?()
        }
    }

    @objc private func handleSwipeUp() {
        if zoomScale <= minimumZoomScale + 0.01 {
            onSwipeUp?()
        }
    }

    @objc private func handleSwipeLeft() {
        if zoomScale <= minimumZoomScale + 0.01 {
            onSwipeLeft?()
        }
    }

    @objc private func handleSwipeRight() {
        if zoomScale <= minimumZoomScale + 0.01 {
            onSwipeRight?()
        }
    }
}
