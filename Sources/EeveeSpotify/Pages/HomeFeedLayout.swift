import UIKit

enum HomeFeedLayout {
    enum SectionKind {
        case shortcuts, recommendations, pending
    }

    static func sectionKind(in root: UIView) -> SectionKind {
        var queue = [root]
        var index = 0
        var recommendation = false
        while index < queue.count && index < 160 {
            let view = queue[index]
            index += 1
            let name = NSStringFromClass(type(of: view))
            if view.accessibilityIdentifier == "Shortcut.Card.Home"
                || name.contains("Home_AnchorsAndShortcutsKit") {
                return .shortcuts
            }
            recommendation = recommendation
                || view.accessibilityIdentifier == "ActionCardCarouselElement"
                || name.contains("Home_CarouselKit")
                || name.contains("Discovery_PreviewElement")
                || name.contains("Discovery_MediumDensityCardKit")
                || name.contains("Discovery_PromoElement")
                || name.contains("Discovery_DJElement")
            // Collection contents load independently. Classify their container without laying out their cells.
            if !(view is UICollectionView) { queue += view.subviews }
        }
        return recommendation ? .recommendations : .pending
    }

    private final class CollapsedContent {
        let autoresizing: UIView.AutoresizingMask
        let wasHidden: Bool
        let clipped: Bool
        let accessibilityHidden: Bool
        let height: CGFloat

        init(cell: UICollectionViewCell, height: CGFloat) {
            autoresizing = cell.contentView.autoresizingMask
            wasHidden = cell.contentView.isHidden
            clipped = cell.clipsToBounds
            accessibilityHidden = cell.accessibilityElementsHidden
            self.height = max(1, height)
        }
    }

    private static var collapsedKey: UInt8 = 0

    static func isCollapsed(_ cell: UICollectionViewCell) -> Bool {
        objc_getAssociatedObject(cell, &collapsedKey) != nil
    }

    static func collapse(_ cell: UICollectionViewCell, attributes: UICollectionViewLayoutAttributes) {
        if !isCollapsed(cell) {
            let state = CollapsedContent(cell: cell, height: max(attributes.size.height, cell.contentView.bounds.height))
            objc_setAssociatedObject(cell, &collapsedKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        maintain(cell)
        attributes.size.height = 0
        // Keep the cell in the collection's layout lifecycle while its content is hidden.
        attributes.isHidden = false
    }

    static func maintain(_ cell: UICollectionViewCell) {
        guard let state = objc_getAssociatedObject(cell, &collapsedKey) as? CollapsedContent else { return }
        let content = cell.contentView
        content.autoresizingMask.remove(.flexibleHeight)
        let frame = CGRect(x: 0, y: 0, width: cell.bounds.width, height: state.height)
        if content.frame != frame { content.frame = frame }
        if !content.isHidden { content.isHidden = true }
        if !cell.clipsToBounds { cell.clipsToBounds = true }
        cell.accessibilityElementsHidden = true
    }

    static func restore(_ cell: UICollectionViewCell) {
        guard let state = objc_getAssociatedObject(cell, &collapsedKey) as? CollapsedContent else { return }
        let content = cell.contentView
        content.autoresizingMask = state.autoresizing
        content.isHidden = state.wasHidden
        content.frame = CGRect(x: 0, y: 0, width: cell.bounds.width, height: state.height)
        cell.clipsToBounds = state.clipped
        cell.accessibilityElementsHidden = state.accessibilityHidden
        objc_setAssociatedObject(cell, &collapsedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
