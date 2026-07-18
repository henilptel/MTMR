//
//  ClipboardMonitor.swift
//  MTMR
//
//  Owns pasteboard polling for the clipboardPreview widget, independent of
//  whether the Touch Bar chip itself currently exists. The chip is only
//  instantiated while there's an active preview (TouchBarController.
//  createItems() gates its visibility on ClipboardMonitor.shared.previewText),
//  so something has to keep watching the clipboard even while the chip is
//  absent from the bar — otherwise the next copy would never bring it back.
//
//  Same privacy posture as the old in-widget implementation: never writes
//  copied content to disk, only holds a truncated display string in memory,
//  and clears it after hideAfter seconds.
//

import Cocoa

final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private static let maxRawLengthToProcess = 20_000

    private(set) var previewText: String?

    private var pollTimer: Timer?
    private var hideTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var hideAfter: TimeInterval = 45.0
    private var maxChars: Int = 18
    private var started = false

    // Fired whenever previewText changes while the chip may already be on
    // screen, so the live NSTouchBarItem can update its title immediately —
    // TouchBarController's reuse-existing-instance optimization means a
    // second copy while the chip is still showing won't otherwise trigger
    // any rebuild that would pick up the new text.
    private var onChange: (() -> Void)?

    private init() {}

    // items.json can be reloaded (config values may change) — refresh the
    // live hideAfter/maxChars every call, but only ever start the poll timer
    // once, on the first configure() after launch.
    func configure(hideAfter: TimeInterval, maxChars: Int) {
        self.hideAfter = hideAfter
        self.maxChars = maxChars
        guard !started else { return }
        started = true
        lastChangeCount = NSPasteboard.general.changeCount

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        // .common so this keeps firing even while the Touch Bar/AppKit is in
        // a tracking run loop mode (e.g. during a drag or menu tracking).
        RunLoop.current.add(timer, forMode: .common)
        pollTimer = timer
    }

    func setOnChange(_ callback: (() -> Void)?) {
        onChange = callback
    }

    func paste() {
        guard previewText != nil else { return }
        GenericKeyPress(keyCode: 9, flags: .maskCommand).send() // Cmd+V
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // Any change we can't turn into a usable text preview (an image was
        // copied, the pasteboard was cleared, only non-text types present)
        // invalidates whatever's currently showing — leaving a stale text
        // preview up would be misleading: tapping it pastes whatever's
        // *actually* on the clipboard now, which would no longer match.
        guard let string = pb.string(forType: .string) else {
            clearPreview()
            return
        }

        // prefix(n) only scans up to n characters regardless of the full
        // string's length — unlike checking string.count > n first, which
        // would itself be an O(full length) scan and defeat the point of
        // bounding work for a huge clipboard payload.
        let bounded = String(string.prefix(ClipboardMonitor.maxRawLengthToProcess))
        let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearPreview()
            return
        }

        // Collapse embedded newlines/tabs/whitespace runs to single spaces —
        // multi-line copied text would otherwise break a single-line chip.
        let singleLine = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else {
            clearPreview()
            return
        }

        let truncated = singleLine.count > maxChars
            ? String(singleLine.prefix(maxChars)) + "…"
            : singleLine

        let wasActive = previewText != nil
        previewText = truncated
        onChange?()
        // Only a structural bar rebuild (chip going from absent to present)
        // needs prepareTouchBar(); an already-visible chip was just updated
        // in place above via onChange().
        if !wasActive {
            TouchBarController.shared.prepareTouchBar()
        }

        hideTimer?.invalidate()
        let timer = Timer(timeInterval: hideAfter, repeats: false) { [weak self] _ in
            self?.clearPreview()
        }
        RunLoop.current.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func clearPreview() {
        guard previewText != nil else { return }
        previewText = nil
        hideTimer?.invalidate()
        hideTimer = nil
        TouchBarController.shared.prepareTouchBar()
    }
}
