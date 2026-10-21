import SwiftUI
import UIKit

struct PromptTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var maximumLines = 4
    var light = false
    var heightChanged: ((CGFloat) -> Void)?
    @Environment(\.sizeCategory) private var sizeCategory

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = SizingPromptTextView()
        view.maximumLines = maximumLines
        view.heightChanged = heightChanged
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isOpaque = false
        view.textColor = .white
        view.tintColor = .white
        view.keyboardAppearance = .dark
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "提示词"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.textColor = light ? UIColor(red: 0.122, green: 0.255, blue: 0.247, alpha: 1) : .white
        view.tintColor = light ? UIColor(red: 0.22, green: 0.408, blue: 0.365, alpha: 1) : .white
        view.keyboardAppearance = light ? .light : .dark
        if let sizingView = view as? SizingPromptTextView {
            sizingView.maximumLines = maximumLines
            sizingView.heightChanged = heightChanged
            sizingView.setNeedsLayout()
        }
        let font = Self.bodyFont(for: sizeCategory)
        if view.font != font { view.font = font }
        if view.text != text, view.markedTextRange == nil { view.text = text }
        if focused, !view.isFirstResponder { view.becomeFirstResponder() }
        else if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }

    static func bodyFont(for category: ContentSizeCategory) -> UIFont {
        let value: UIContentSizeCategory
        switch category {
        case .extraSmall: value = .extraSmall
        case .small: value = .small
        case .medium: value = .medium
        case .large: value = .large
        case .extraLarge: value = .extraLarge
        case .extraExtraLarge: value = .extraExtraLarge
        case .extraExtraExtraLarge: value = .extraExtraExtraLarge
        case .accessibilityMedium: value = .accessibilityMedium
        case .accessibilityLarge: value = .accessibilityLarge
        case .accessibilityExtraLarge: value = .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: value = .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: value = .accessibilityExtraExtraExtraLarge
        @unknown default: value = .large
        }
        return UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: value))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PromptTextView
        init(parent: PromptTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { parent.focused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}

final class SizingPromptTextView: UITextView {
    var maximumLines = 4
    var heightChanged: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let contentHeight = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        let limit = (font?.lineHeight ?? 22) * CGFloat(maximumLines) + textContainerInset.top
        let height = min(max(44, limit), max(44, ceil(contentHeight)))
        if abs(height - reportedHeight) > 0.5 {
            reportedHeight = height
            DispatchQueue.main.async { [weak self] in self?.heightChanged?(height) }
        }
    }
}
