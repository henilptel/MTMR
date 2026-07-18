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
    init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier, title: ClipboardMonitor.shared.previewText ?? "")
        isBordered = true

        actions.append(ItemAction(trigger: .singleTap, {
            ClipboardMonitor.shared.paste()
        }))

        // Picks up a second copy that happens while this chip is already on
        // screen (a rebuild-worthy identifier/count change didn't occur, so
        // TouchBarController wouldn't otherwise touch this instance again).
        ClipboardMonitor.shared.setOnChange { [weak self] in
            self?.title = ClipboardMonitor.shared.previewText ?? ""
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        ClipboardMonitor.shared.setOnChange(nil)
    }
}
