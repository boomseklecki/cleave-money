import SwiftUI
import UIKit

/// One regex token the accessory bar can insert.
struct RegexToken {
    let symbol: String        // display glyph, e.g. "\b"
    let hint: String          // tooltip + accessibilityLabel, e.g. "word boundary"
    let insertText: String    // text inserted at the cursor (both halves for a pair, e.g. "()")
    var caretBackOffset: Int = 0   // caret moves back this many chars after insert (1 for a pair/lookaround)
}

enum RegexTokens {
    /// All tokens in one horizontally-scrollable row, grouped left-to-right with a thin divider between groups.
    /// `/` is its own group (a delimiter the pattern is wrapped in). Lookarounds insert their skeleton with the
    /// caret placed inside the closing paren.
    static let groups: [[RegexToken]] = [
        [ RegexToken(symbol: "/", hint: "regex delimiter (goes before and after the pattern)", insertText: "/") ],
        [ RegexToken(symbol: "?", hint: "optional, 0 or 1", insertText: "?"),
          RegexToken(symbol: "+", hint: "1 or more", insertText: "+"),
          RegexToken(symbol: "*", hint: "0 or more", insertText: "*") ],
        [ RegexToken(symbol: "^", hint: "start of text", insertText: "^"),
          RegexToken(symbol: "$", hint: "end of text", insertText: "$"),
          RegexToken(symbol: "\\b", hint: "word boundary", insertText: "\\b") ],
        [ RegexToken(symbol: ".", hint: "any character", insertText: "."),
          RegexToken(symbol: "\\s", hint: "whitespace", insertText: "\\s"),
          RegexToken(symbol: "\\d", hint: "any digit", insertText: "\\d"),
          RegexToken(symbol: "\\w", hint: "any letter, digit, or _", insertText: "\\w") ],
        [ RegexToken(symbol: "(", hint: "group", insertText: "()", caretBackOffset: 1),
          RegexToken(symbol: ")", hint: "end group", insertText: ")"),
          RegexToken(symbol: "[", hint: "character set", insertText: "[]", caretBackOffset: 1),
          RegexToken(symbol: "]", hint: "end set", insertText: "]"),
          RegexToken(symbol: "|", hint: "or", insertText: "|") ],
        [ RegexToken(symbol: "(?=)", hint: "followed by (must come next)", insertText: "(?=)", caretBackOffset: 1),
          RegexToken(symbol: "(?!)", hint: "NOT followed by (exclude what comes next)", insertText: "(?!)", caretBackOffset: 1),
          RegexToken(symbol: "(?<=)", hint: "preceded by (must come before)", insertText: "(?<=)", caretBackOffset: 1),
          RegexToken(symbol: "(?<!)", hint: "NOT preceded by (exclude what comes before)", insertText: "(?<!)", caretBackOffset: 1) ],
    ]
}

/// A slim, fixed-height keyboard accessory bar for regex entry: one horizontally-scrollable row of token keys.
/// Tapping a key inserts its token at the cursor; press-and-hold shows a plain-language hint, and you can drag
/// across keys to preview each. The standard system keyboard stays active - this is only the bar above it
/// (`inputAccessoryView`), not a replacement.
final class RegexAccessoryBar: UIView {
    /// The field to insert into. Weak: the field owns this bar via `inputAccessoryView`.
    weak var textField: UITextField?

    private let rowHeight: CGFloat = 48

    private let scrollView = UIScrollView()
    private let rowStack = UIStackView()
    private let fadeLayer = CAGradientLayer()
    private var tokensByButton: [UIButton: RegexToken] = [:]
    private weak var activeTooltip: UIView?
    private weak var tooltipLabel: UILabel?
    private weak var tooltipButton: UIButton?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: rowHeight))
        // Fixed height + `.flexibleWidth`: the host stretches the bar to the full keyboard width and the height
        // never changes (no self-sizing to fight). This is the reliable, single-level design.
        autoresizingMask = .flexibleWidth
        backgroundColor = .secondarySystemBackground
        buildRow()

        // One long-press for the whole bar: hold to reveal a hint, then slide across keys to preview each
        // (a per-button recognizer would stay stuck on the key you started on). A quick tap still inserts.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private func buildRow() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 5
        scrollView.addSubview(rowStack)

        for (i, group) in RegexTokens.groups.enumerated() {
            for token in group { rowStack.addArrangedSubview(makeKey(token)) }
            if i < RegexTokens.groups.count - 1 { rowStack.addArrangedSubview(makeDivider()) }
        }

        // A short fade at the scroll view's trailing edge, shown only when the row overflows (a "scroll for
        // more" cue). The advanced tokens live at the far end.
        fadeLayer.colors = [UIColor.secondarySystemBackground.withAlphaComponent(0).cgColor,
                            UIColor.secondarySystemBackground.cgColor]
        fadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fadeLayer.isHidden = true
        layer.addSublayer(fadeLayer)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            rowStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            rowStack.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor),
            rowStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only show the trailing fade when the row actually overflows.
        let overflow = scrollView.contentSize.width > scrollView.bounds.width + 1
        fadeLayer.isHidden = !overflow
        if overflow {
            fadeLayer.frame = CGRect(x: scrollView.frame.maxX - 18, y: scrollView.frame.minY,
                                     width: 18, height: scrollView.frame.height)
        }
    }

    // MARK: Keys

    /// Single glyphs get the base width/font; multi-character tokens (`\b`, and the wider lookarounds like
    /// `(?<=)`) get a slightly smaller font and a width that grows with the glyph so they don't clip.
    private func keyWidth(_ symbol: String) -> CGFloat {
        switch symbol.count {
        case 1: return 34
        case 2: return 38
        default: return CGFloat(symbol.count) * 9 + 14   // (?=) -> 50, (?<=) -> 59
        }
    }

    private func makeKey(_ token: RegexToken) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(token.symbol, for: .normal)
        button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: token.symbol.count > 1 ? 13 : 15, weight: .medium)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .tertiarySystemBackground
        button.layer.cornerRadius = 6
        button.accessibilityLabel = token.hint            // VoiceOver (required, independent of the tooltip)
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: keyWidth(token.symbol)),
            button.heightAnchor.constraint(equalToConstant: 34),
        ])
        tokensByButton[button] = token
        return button
    }

    private func makeDivider() -> UIView {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = .separator
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 24),
        ])
        return line
    }

    // MARK: Insert

    @objc private func keyTapped(_ sender: UIButton) {
        guard let token = tokensByButton[sender], let field = textField else { return }
        // Cursor-aware insertion (works mid-string, not just append) via the text-range API.
        if let range = field.selectedTextRange {
            field.replace(range, withText: token.insertText)
            if token.caretBackOffset > 0, let sel = field.selectedTextRange,
               let back = field.position(from: sel.start, offset: -token.caretBackOffset) {
                field.selectedTextRange = field.textRange(from: back, to: back)
            }
        } else {
            field.text = (field.text ?? "") + token.insertText
        }
        field.sendActions(for: .editingChanged)   // push the change to the SwiftUI binding
    }

    // MARK: Long-press tooltip (hold, then drag across keys)

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if let button = keyButton(at: gesture.location(in: self)), let token = tokensByButton[button] {
                if button !== tooltipButton {
                    tooltipButton = button
                    showTooltip(token.hint, above: button)
                }
            } else if tooltipButton != nil {
                tooltipButton = nil
                hideTooltip()
            }
        case .ended, .cancelled, .failed:
            tooltipButton = nil
            hideTooltip()
        default:
            break
        }
    }

    /// The token key under a point in the bar's coordinate space (nil for dividers / gaps).
    private func keyButton(at point: CGPoint) -> UIButton? {
        var view = hitTest(point, with: nil)
        while let v = view {
            if let button = v as? UIButton, tokensByButton[button] != nil { return button }
            view = v.superview
        }
        return nil
    }

    private func showTooltip(_ text: String, above button: UIButton) {
        // Present in the accessory's OWN window (the keyboard/input window, which is topmost and doesn't clip
        // its subviews), so the bubble stays visible above the bar. A single bubble is reused and slid/relabeled
        // as the finger drags across keys; horizontal position is clamped on-screen.
        guard let host = button.window else { return }
        let reusing = activeTooltip != nil && tooltipLabel != nil
        let bubble: UIView, label: UILabel
        if reusing {
            bubble = activeTooltip!; label = tooltipLabel!
        } else {
            (bubble, label) = makeTooltip()
            host.addSubview(bubble)
            activeTooltip = bubble
            tooltipLabel = label
        }
        label.text = text
        let size = bubble.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let anchor = host.convert(button.bounds, from: button)
        let x = min(max(8, anchor.midX - size.width / 2), host.bounds.width - size.width - 8)
        let frame = CGRect(x: x, y: anchor.minY - size.height - 8, width: size.width, height: size.height)
        if reusing {
            UIView.animate(withDuration: 0.12) { bubble.frame = frame; bubble.alpha = 1 }   // slide to the new key
        } else {
            bubble.frame = frame                                    // appear in place (no fly-in from the corner)
            bubble.alpha = 0
            UIView.animate(withDuration: 0.12) { bubble.alpha = 1 }
        }
    }

    private func hideTooltip() {
        guard let bubble = activeTooltip else { return }
        activeTooltip = nil
        tooltipLabel = nil
        UIView.animate(withDuration: 0.12, animations: { bubble.alpha = 0 }) { _ in bubble.removeFromSuperview() }
    }

    private func makeTooltip() -> (UIView, UILabel) {
        let container = UIView()
        container.backgroundColor = .systemBackground
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.separator.cgColor
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.18
        container.layer.shadowRadius = 6
        container.layer.shadowOffset = CGSize(width: 0, height: 2)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .label
        label.numberOfLines = 1
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return (container, label)
    }
}

/// A `UITextField` bridged into SwiftUI so it can carry the regex `RegexAccessoryBar` as its
/// `inputAccessoryView`. Monospaced, no autocorrect/autocapitalize - matches the old SwiftUI pattern field.
struct RegexPatternTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Pattern"

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
                                           weight: .regular)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .whileEditing
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
                        for: .editingChanged)

        let bar = RegexAccessoryBar()
        bar.textField = field
        field.inputAccessoryView = bar
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }   // only when out of sync, so typing doesn't reset the caret
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func editingChanged(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
    }
}
