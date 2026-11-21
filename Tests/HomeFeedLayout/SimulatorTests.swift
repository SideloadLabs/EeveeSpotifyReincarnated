import UIKit

@objc(Home_CarouselKit_TestShelf)
final class RecommendationShelf: UICollectionView {}

@objc(Home_AnchorsAndShortcutsKit_TestGrid)
final class ShortcutGrid: UIView {}

final class LayoutTestDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DispatchQueue.main.async {
            self.runTests()
            print("HOME_LAYOUT_TESTS_PASSED")
            fflush(stdout)
            exit(0)
        }
        return true
    }

    private func runTests() {
        let root = UIView()
        let wrapper = UIView()
        root.addSubview(wrapper)
        assert(HomeFeedLayout.sectionKind(in: root) == .pending, "Keep loading and unknown sections visible")

        let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        wrapper.addSubview(grid)
        assert(HomeFeedLayout.sectionKind(in: root) == .pending, "An unnamed shortcuts collection must remain visible inside wrappers")
        grid.removeFromSuperview()

        let shelf = RecommendationShelf(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        wrapper.addSubview(shelf)
        assert(HomeFeedLayout.sectionKind(in: root) == .recommendations, "Recognize music recommendation shelves")
        shelf.removeFromSuperview()

        let shortcut = ShortcutGrid()
        wrapper.addSubview(shortcut)
        assert(HomeFeedLayout.sectionKind(in: root) == .shortcuts, "Recognize a wrapped shortcuts grid")
        wrapper.addSubview(shelf)
        assert(HomeFeedLayout.sectionKind(in: root) == .shortcuts, "Keep a section containing shortcuts")
        shortcut.removeFromSuperview()
        shelf.removeFromSuperview()
        assert(HomeFeedLayout.sectionKind(in: root) == .pending, "Reused wrappers must be classified again")

        let card = UIView()
        card.accessibilityIdentifier = "ActionCardCarouselElement"
        wrapper.addSubview(card)
        assert(HomeFeedLayout.sectionKind(in: root) == .recommendations, "Recognize episode recommendation carousels")

        let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 0, width: 390, height: 180))
        let originalMask = cell.contentView.autoresizingMask
        let originalClipping = cell.clipsToBounds
        let fixedCard = UIView()
        fixedCard.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(fixedCard)
        let cardHeight = fixedCard.heightAnchor.constraint(equalToConstant: 180)
        NSLayoutConstraint.activate([
            fixedCard.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            fixedCard.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            fixedCard.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            fixedCard.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
            cardHeight,
        ])
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.size = cell.bounds.size
        HomeFeedLayout.collapse(cell, attributes: attributes)
        assert(attributes.size.height == 0 && !attributes.isHidden, "The collection keeps a zero-height cell in its lifecycle")
        for _ in 0..<100 {
            cell.frame.size.height = 0
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            HomeFeedLayout.maintain(cell)
            cell.contentView.layoutIfNeeded()
            assert(cell.contentView.bounds.height == 180, "Collapsing the outer cell must retain the card's natural height")
            assert(fixedCard.bounds.height == 180, "The fixed-height card must remain satisfiable")
        }
        assert(cell.contentView.isHidden && cell.accessibilityElementsHidden)
        HomeFeedLayout.restore(cell)
        assert(!HomeFeedLayout.isCollapsed(cell) && !cell.contentView.isHidden)
        assert(cell.contentView.autoresizingMask == originalMask)
        assert(!cell.accessibilityElementsHidden, "Restore accessibility on reuse")
        assert(cell.clipsToBounds == originalClipping, "Restore the container on reuse")
        cardHeight.constant = 240
        cell.frame.size.height = 240
        attributes.size.height = 240
        HomeFeedLayout.collapse(cell, attributes: attributes)
        assert(cell.contentView.bounds.height == 240, "A reused cell must acquire its new natural height")
        HomeFeedLayout.restore(cell)
    }
}

@main
struct LayoutTests {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(LayoutTestDelegate.self))
    }
}
