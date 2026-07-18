//
//  TouchBarItems.swift
//  MTMR
//
//  Created by Anton Palgunov on 18/03/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa

// Opt-in for CustomButtonTouchBarItem subclasses that continuously refresh
// their own title in the background on a timer (ShellScriptTouchBarItem),
// independent of any user interaction. cycleAdvance's plain snapshot-restore
// would go stale for these — if the real value changes while cycled away
// from index 0, restoring a snapshot taken before that change shows outdated
// data with no indication anything's wrong. A conforming type must suppress
// applying its own background refreshes to the visible title/image while
// suppressed (so cycling can put arbitrary content there without it being
// clobbered mid-cycle), while continuing to track the freshest value
// internally so it can be shown immediately on return to index 0.
protocol RefreshSuppressible: AnyObject {
    func suppressAutoRefresh(_ suppressed: Bool)
    func restoreLatestAutoRefreshedTitle()
}

struct ItemAction {
    typealias TriggerClosure = (() -> Void)?
    
    let trigger: Action.Trigger
    let closure: TriggerClosure
    
    init(trigger: Action.Trigger, _ closure: TriggerClosure) {
        self.trigger = trigger
        self.closure = closure
    }
}

class CustomButtonTouchBarItem: NSCustomTouchBarItem, NSGestureRecognizerDelegate {
    
    var actions: [ItemAction] = [] {
        didSet {
            multiClick.isDoubleClickEnabled = actions.filter({ $0.trigger == .doubleTap }).count > 0
            multiClick.isTripleClickEnabled = actions.filter({ $0.trigger == .tripleTap }).count > 0
            longClick.isEnabled = actions.filter({ $0.trigger == .longTap }).count > 0
        }
    }
    var finishViewConfiguration: ()->() = {}
    
    private var button: NSButton!
    private var longClick: LongPressGestureRecognizer!
    private var multiClick: MultiClickGestureRecognizer!

    init(identifier: NSTouchBarItem.Identifier, title: String) {
        attributedTitle = title.defaultTouchbarAttributedString

        super.init(identifier: identifier)
        button = CustomHeightButton(title: title, target: nil, action: nil)

        longClick = LongPressGestureRecognizer(target: self, action: #selector(handleGestureLong))
        longClick.isEnabled = false
        longClick.allowedTouchTypes = .direct
        longClick.delegate = self
        
        multiClick = MultiClickGestureRecognizer(
            target: self,
            action: #selector(handleGestureSingleTap),
            doubleAction: #selector(handleGestureDoubleTap),
            tripleAction: #selector(handleGestureTripleTap)
        )
        multiClick.allowedTouchTypes = .direct
        multiClick.delegate = self
        multiClick.isDoubleClickEnabled = false
        multiClick.isTripleClickEnabled = false

        reinstallButton()
        button.attributedTitle = attributedTitle
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isBordered: Bool = true {
        didSet {
            reinstallButton()
        }
    }

    var backgroundColor: NSColor? {
        didSet {
            reinstallButton()
        }
    }

    var title: String {
        get {
            return attributedTitle.string
        }
        set {
            attributedTitle = newValue.defaultTouchbarAttributedString
        }
    }

    var attributedTitle: NSAttributedString {
        didSet {
            button?.imagePosition = attributedTitle.length > 0 ? .imageLeading : .imageOnly
            button?.attributedTitle = attributedTitle
        }
    }

    var image: NSImage? {
        didSet {
            button.image = image
        }
    }

    // Cycle state for the cycleScriptOutput action: index 0 means "no
    // override, show this item's own normal content"; index 1...N means
    // "showing sources[index-1]'s cached output", sticky until tapped again
    // (no timer — a timer-based "reveal for N seconds" was tried first and
    // had a real bug: a second tap before the first's timer fired captured
    // the *already-revealed* text as "what to restore to", permanently
    // losing the real baseline. A tap-driven state machine has no timer to
    // race with, so that class of bug can't recur here).
    private(set) var cycleIndex = 0
    private var cycleBaselineTitle: NSAttributedString?

    // Advances to the next cycle state and applies whatever's needed to
    // return to index 0 (nothing to fetch there — either restore the
    // snapshot taken on the way out, or, for RefreshSuppressible items,
    // resume normal auto-refresh and show its latest fetched value instead
    // of a possibly-stale snapshot). Returns the new index; the caller is
    // responsible for fetching/showing content for indices > 0 — this
    // method only owns the index and the index-0 restore path, since
    // fetching (`sources[index-1]`) is async and item-agnostic.
    @discardableResult
    func cycleAdvance(stateCount: Int) -> Int {
        guard stateCount > 0 else { return 0 }
        cycleIndex = (cycleIndex + 1) % (stateCount + 1)

        if cycleIndex == 0 {
            if let refreshable = self as? RefreshSuppressible {
                refreshable.suppressAutoRefresh(false)
                refreshable.restoreLatestAutoRefreshedTitle()
            } else if let baseline = cycleBaselineTitle {
                attributedTitle = baseline
            }
            cycleBaselineTitle = nil
        } else if cycleIndex == 1 {
            // Just left index 0 — capture what "off" looks like. Only
            // needed as a fallback for items that don't track their own
            // "latest" value independently.
            if let refreshable = self as? RefreshSuppressible {
                refreshable.suppressAutoRefresh(true)
            } else {
                cycleBaselineTitle = attributedTitle
            }
        }
        return cycleIndex
    }

    private func reinstallButton() {
        let title = button.attributedTitle
        let image = button.image
        let cell = CustomButtonCell(parentItem: self)
        // Ellipsize instead of silently clipping when a title doesn't fit
        // the button's actual pixel width (e.g. a configured `width` in
        // items.json narrower than the text needs) — separate from any
        // widget-level character-count truncation, which only bounds how
        // much text is ever put in the title in the first place.
        cell.lineBreakMode = .byTruncatingTail
        button.cell = cell
        if let color = backgroundColor {
            cell.isBordered = true
            button.bezelColor = color
            button.bezelStyle = .rounded
            cell.backgroundColor = color
        } else {
            button.isBordered = isBordered
            button.bezelStyle = isBordered ? .rounded : .inline
        }
        button.imageScaling = .scaleProportionallyDown
        button.imageHugsTitle = true
        button.attributedTitle = title
        button?.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
        button.image = image
        view = button

        view.addGestureRecognizer(longClick)
        // view.addGestureRecognizer(singleClick)
        view.addGestureRecognizer(multiClick)
        finishViewConfiguration()
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        if gestureRecognizer == multiClick && otherGestureRecognizer == longClick
            || gestureRecognizer == longClick && otherGestureRecognizer == multiClick // need it
        {
            return false
        }
        return true
    }
    
    func callActions(for trigger: Action.Trigger) {
        let itemActions = self.actions.filter { $0.trigger == trigger }
        for itemAction in itemActions {
            itemAction.closure?()
        }
    }
    
    @objc func handleGestureSingleTap() {
        callActions(for: .singleTap)
    }
    
    @objc func handleGestureDoubleTap() {
        callActions(for: .doubleTap)
    }
    
    @objc func handleGestureTripleTap() {
        callActions(for: .tripleTap)
    }

    @objc func handleGestureLong(gr: NSPressGestureRecognizer) {
        switch gr.state {
        case .possible: // tiny hack because we're calling action manually
            callActions(for: .longTap)
            break
        default:
            break
        }
    }
}

class CustomHeightButton: NSButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = 30
        return size
    }
}

class CustomButtonCell: NSButtonCell {
    weak var parentItem: CustomButtonTouchBarItem?

    init(parentItem: CustomButtonTouchBarItem) {
        super.init(textCell: "")
        self.parentItem = parentItem
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        if !isBordered {
            if flag {
                setAttributedTitle(attributedTitle, withColor: .lightGray)
            } else if let parentItem = self.parentItem {
                attributedTitle = parentItem.attributedTitle
            }
        }
    }
    
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        return rect // need that so content may better fit in button with very limited width
    }

    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setAttributedTitle(_ title: NSAttributedString, withColor color: NSColor) {
        let attrTitle = NSMutableAttributedString(attributedString: title)
        attrTitle.addAttributes([.foregroundColor: color], range: NSRange(location: 0, length: attrTitle.length))
        attributedTitle = attrTitle
    }
}

// Thanks to https://stackoverflow.com/a/49843893
final class MultiClickGestureRecognizer: NSClickGestureRecognizer {

    private let _action: Selector
    private let _doubleAction: Selector
    private let _tripleAction: Selector
    private var _clickCount: Int = 0
    
    public var isDoubleClickEnabled = true
    public var isTripleClickEnabled = true

    override var action: Selector? {
        get {
            return nil /// prevent base class from performing any actions
        } set {
            if newValue != nil { // if they are trying to assign an actual action
                fatalError("Only use init(target:action:doubleAction) for assigning actions")
            }
        }
    }

    required init(target: AnyObject, action: Selector, doubleAction: Selector, tripleAction: Selector) {
        _action = action
        _doubleAction = doubleAction
        _tripleAction = tripleAction
        super.init(target: target, action: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(target:action:doubleAction:tripleAction) is only support atm")
    }
    
    override func touchesBegan(with event: NSEvent) {
        HapticFeedback.instance.tap(type: .click)
        super.touchesBegan(with: event)
    }

    override func touchesEnded(with event: NSEvent) {
        HapticFeedback.instance.tap(type: .back)
        super.touchesEnded(with: event)
        _clickCount += 1
        
        var delayThreshold: TimeInterval // fine tune this as needed
        
        guard isDoubleClickEnabled || isTripleClickEnabled else {
            _ = target?.perform(_action)
            return
        }
        
        if (isTripleClickEnabled) {
            delayThreshold = 0.4
            perform(#selector(_resetAndPerformActionIfNecessary), with: nil, afterDelay: delayThreshold)
            if _clickCount == 3 {
                _ = target?.perform(_tripleAction)
            }
        } else {
            delayThreshold = 0.3
            perform(#selector(_resetAndPerformActionIfNecessary), with: nil, afterDelay: delayThreshold)
            if _clickCount == 2 {
                _ = target?.perform(_doubleAction)
            }
        }
    }

    @objc private func _resetAndPerformActionIfNecessary() {
        if _clickCount == 1 {
            _ = target?.perform(_action)
        }
        if isTripleClickEnabled && _clickCount == 2 {
            _ = target?.perform(_doubleAction)
        }
        _clickCount = 0
    }
}

class LongPressGestureRecognizer: NSPressGestureRecognizer {
    var recognizeTimeout = 0.4
    private var timer: Timer?
    
    override func touchesBegan(with event: NSEvent) {
        timerInvalidate()
        
        let touches = event.touches(for: self.view!)
        if touches.count == 1 { // to prevent it for built-in two/three-finger gestures
            timer = Timer.scheduledTimer(timeInterval: recognizeTimeout, target: self, selector: #selector(self.onTimer), userInfo: nil, repeats: false)
        }
        
        super.touchesBegan(with: event)
    }
    
    override func touchesMoved(with event: NSEvent) {
        timerInvalidate() // to prevent it for built-in two/three-finger gestures
        super.touchesMoved(with: event)
    }
    
    override func touchesCancelled(with event: NSEvent) {
        timerInvalidate()
        super.touchesCancelled(with: event)
    }
    
    override func touchesEnded(with event: NSEvent) {
        timerInvalidate()
        super.touchesEnded(with: event)
    }
    
    private func timerInvalidate() {
        if let timer = timer {
            timer.invalidate()
            self.timer = nil
        }
    }
    
    @objc private func onTimer() {
        if let target = self.target, let action = self.action {
            target.performSelector(onMainThread: action, with: self, waitUntilDone: false)
            HapticFeedback.instance.tap(type: .strong)
        }
    }
    
    deinit {
        timerInvalidate()
    }
}

extension String {
    var defaultTouchbarAttributedString: NSAttributedString {
        let attrTitle = NSMutableAttributedString(string: self, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15, weight: .regular), .baselineOffset: 1])
        attrTitle.setAlignment(.center, range: NSRange(location: 0, length: count))
        return attrTitle
    }
}
