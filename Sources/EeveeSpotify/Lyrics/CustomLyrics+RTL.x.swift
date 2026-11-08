import Orion
import UIKit

class LyricsCellRTLHook: ClassHook<UITableViewCell> {
    typealias Group = BaseLyricsGroup

    func layoutSubviews() {
        orig.layoutSubviews()

        let className = NSStringFromClass(type(of: target))
        guard className.contains("Lyrics") && className.contains("Cell") else { return }

        applyRTLIfNeeded(in: target)
    }

    private func applyRTLIfNeeded(in view: UIView) {
        var queue = [view]
        while !queue.isEmpty {
            let current = queue.removeFirst()

            if let label = current as? UILabel, let text = label.text, !text.isEmpty {
                if text.isRTL {
                    label.textAlignment = .right
                    if let attr = label.attributedText, attr.length > 0 {
                        let mutable = NSMutableAttributedString(attributedString: attr)
                        let paragraphStyle = NSMutableParagraphStyle()
                        paragraphStyle.alignment = .right
                        mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attr.length))
                        label.attributedText = mutable
                    }
                }
            } else if let textView = current as? UITextView, let text = textView.text, !text.isEmpty {
                if text.isRTL {
                    textView.textAlignment = .right
                }
            }

            queue.append(contentsOf: current.subviews)
        }
    }
}
