//
//  ClipboardPreviewBarItem.swift
//  MTMR
//
//  Gboard-style clipboard suggestion chip for the Touch Bar. This is a thin
//  display only — ClipboardMonitor owns pasteboard polling, the hide timer,
//  and the truncated preview text, so the chip can be freely created and
//  destroyed as it enters/leaves the bar (TouchBarController.createItems()
//  only shows it while ClipboardMonitor.shared.previewText != nil) without
//  ever missing a clipboard change in between.
//

import Cocoa

class ClipboardPreviewBarItem: CustomButtonTouchBarItem {
    // `width` from items.json is treated as a cap, not a fixed size — unlike
    // every other button type (see CanSetWidth in TouchBarController.swift),
    // this chip's content length varies copy to copy, so a fixed-width
    // constraint would leave a mostly-empty bordered box behind short text.
    //
    // Width is computed deterministically from the actual title text rather
    // than left to the button's own Auto Layout content-hugging/compression
    // resistance: with only a lessThanOrEqualToConstant upper bound and no
    // opposing force, resolution of the "natural" width is ambiguous for
    // this app's custom NSButtonCell subclass, and was observed resolving
    // to the full cap instead of the content size — which also hard-conflicts
    // with BasicView's required anti-overlap constraints once the cap is
    // larger than the space actually available, clipping the button without
    // triggering byTruncatingTail's ellipsis (the cell needs LESS width than
    // it was actually given to know it should truncate).
    private static let horizontalPadding: CGFloat = 24
    private static let minWidth: CGFloat = 40
    private static let defaultMaxWidth: CGFloat = 200
    private static let font = NSFont.systemFont(ofSize: 15, weight: .regular)

    private let maxWidth: CGFloat
    private var widthConstraint: NSLayoutConstraint!

    init(identifier: NSTouchBarItem.Identifier, maxWidth: CGFloat?) {
        let resolvedMax = (maxWidth?.isFinite == true && maxWidth! > 0) ? maxWidth! : ClipboardPreviewBarItem.defaultMaxWidth
        self.maxWidth = max(resolvedMax, ClipboardPreviewBarItem.minWidth)

        let text = ClipboardMonitor.shared.previewText ?? ""
        super.init(identifier: identifier, title: text)
        isBordered = true

        widthConstraint = view.widthAnchor.constraint(equalToConstant: ClipboardPreviewBarItem.width(for: text, cappedAt: self.maxWidth))
        widthConstraint.isActive = true

        actions.append(ItemAction(trigger: .singleTap, {
            ClipboardMonitor.shared.paste()
        }))

        // Picks up a second copy that happens while this chip is already on
        // screen (a rebuild-worthy identifier/count change didn't occur, so
        // TouchBarController wouldn't otherwise touch this instance again).
        ClipboardMonitor.shared.setOnChange { [weak self] in
            guard let self = self else { return }
            let text = ClipboardMonitor.shared.previewText ?? ""
            self.title = text
            self.widthConstraint.constant = ClipboardPreviewBarItem.width(for: text, cappedAt: self.maxWidth)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        ClipboardMonitor.shared.setOnChange(nil)
    }

    private static func width(for text: String, cappedAt maxWidth: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return minWidth }
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        return min(max(ceil(textWidth) + horizontalPadding, minWidth), maxWidth)
    }
}
