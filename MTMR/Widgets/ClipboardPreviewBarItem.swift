//
//  ClipboardPreviewBarItem.swift
//  MTMR
//
//  Gboard-style clipboard suggestion chip for the Touch Bar: polls
//  NSPasteboard for changes (no special permission needed to read it,
//  unlike synthesizing keystrokes), shows a truncated preview of newly
//  copied text for a limited time, then reverts to an idle icon. Tapping
//  it while a preview is showing sends Cmd+V to paste — the content is
//  already on the system clipboard, this just saves the manual paste
//  shortcut.
//
//  Deliberately does not keep any history or write copied content to
//  disk — only ever holds the current pasteboard string transiently in
//  memory (as a truncated display string, not even the full copied
//  text), same exposure as the system clipboard itself, and clears it
//  after hideAfter seconds so anything sensitive (OTPs, tokens) doesn't
//  linger visible indefinitely.
//

import Cocoa

class ClipboardPreviewBarItem: CustomButtonTouchBarItem {
    // Sane bounds so a malformed/adversarial config value (0, negative,
    // absurdly large) can't produce a broken or resource-abusive widget.
    private static let minHideAfter: TimeInterval = 1.0
    private static let maxHideAfter: TimeInterval = 3600.0
    private static let minMaxChars = 1
    private static let maxMaxChars = 200
    // Cap how much of a huge clipboard payload (e.g. an entire copied file
    // or webpage scrape) we even bother trimming/scanning — we only ever
    // display a handful of characters, no need to process megabytes to get
    // there. Applied before any Character-based work, which is O(n) in
    // Swift for a String's grapheme-cluster-aware operations.
    private static let maxRawLengthToProcess = 20_000

    private var pollTimer: Timer?
    private var hideTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let hideAfter: TimeInterval
    private let maxChars: Int
    private var hasPreview = false

    private static let idleIcon: NSImage? = {
        let path = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
            .appending("/MTMR/icons/clipboard-idle.png")
        return NSImage(contentsOfFile: path)
    }()

    init(identifier: NSTouchBarItem.Identifier, hideAfter: TimeInterval, maxChars: Int) {
        self.hideAfter = hideAfter.isFinite
            ? min(max(hideAfter, ClipboardPreviewBarItem.minHideAfter), ClipboardPreviewBarItem.maxHideAfter)
            : 45.0
        self.maxChars = min(max(maxChars, ClipboardPreviewBarItem.minMaxChars), ClipboardPreviewBarItem.maxMaxChars)
        super.init(identifier: identifier, title: "")
        isBordered = true
        image = ClipboardPreviewBarItem.idleIcon

        actions.append(ItemAction(trigger: .singleTap, { [weak self] in
            self?.pasteIfAvailable()
        }))

        // Skip whatever's already on the clipboard at launch — only react to
        // genuinely new copies from here on, not stale pre-existing content
        // (which may include things copied before MTMR even started).
        lastChangeCount = NSPasteboard.general.changeCount

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        // .common so this keeps firing even while the Touch Bar/AppKit is in
        // a tracking run loop mode (e.g. during a drag or menu tracking) —
        // default mode timers can silently stall in those situations.
        RunLoop.current.add(timer, forMode: .common)
        pollTimer = timer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pollTimer?.invalidate()
        hideTimer?.invalidate()
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // Any change we can't turn into a usable text preview (an image was
        // copied, the pasteboard was cleared, only non-text types present,
        // etc.) invalidates whatever we're currently showing — leaving a
        // stale text preview up would be actively misleading: tapping it
        // still pastes whatever's *actually* on the clipboard right now,
        // which would no longer match the displayed text.
        guard let string = pb.string(forType: .string) else {
            if hasPreview { hidePreview() }
            return
        }

        // Substring.prefix(n) only scans up to n characters regardless of the
        // full string's length — unlike checking `string.count > n` first,
        // which would itself be an O(full length) scan and defeat the whole
        // point of bounding work for a huge clipboard payload (an entire
        // copied file, a webpage scrape, megabytes of text).
        let bounded = String(string.prefix(ClipboardPreviewBarItem.maxRawLengthToProcess))
        let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            if hasPreview { hidePreview() }
            return
        }

        showPreview(for: trimmed)
    }

    private func showPreview(for trimmed: String) {
        // Collapse embedded newlines/tabs/runs of whitespace to single spaces
        // — multi-line copied text (a paragraph, a code snippet) would
        // otherwise break a single-line Touch Bar button's layout.
        let singleLine = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else {
            if hasPreview { hidePreview() }
            return
        }

        let truncated = singleLine.count > maxChars
            ? String(singleLine.prefix(maxChars)) + "…"
            : singleLine

        hasPreview = true
        title = truncated
        image = nil

        hideTimer?.invalidate()
        let timer = Timer(timeInterval: hideAfter, repeats: false) { [weak self] _ in
            self?.hidePreview()
        }
        RunLoop.current.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func hidePreview() {
        hasPreview = false
        title = ""
        image = ClipboardPreviewBarItem.idleIcon
    }

    private func pasteIfAvailable() {
        guard hasPreview else { return }
        GenericKeyPress(keyCode: 9, flags: .maskCommand).send() // Cmd+V
    }
}
