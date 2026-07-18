//
//  BasicView.swift
//  MTMR
//
//  Created by Fedor Zaitsev on 3/29/20.
//  Copyright © 2020 Anton Palgunov. All rights reserved.
//

import Foundation


class BasicView: NSCustomTouchBarItem, NSGestureRecognizerDelegate {
    var twofingers: NSPanGestureRecognizer!
    var threefingers: NSPanGestureRecognizer!
    var fourfingers: NSPanGestureRecognizer!
    var swipeItems: [SwipeItem] = []
    var prevPositions: [Int: CGFloat] = [2:0, 3:0, 4:0]

    // legacy gesture positions
    // by legacy I mean gestures to increse/decrease volume/brigtness which can be checked from app menu
    var legacyPrevPositions: [Int: CGFloat] = [2:0, 3:0, 4:0]
    var legacyGesturesEnabled = false

    // Left/right packed against their edges as before; center items get a
    // real centerXAnchor constraint against the *whole* bar's width instead
    // of just being concatenated into the same flat stack as everything
    // else (which only ever left-packed them right after the left items,
    // regardless of "align": "center" — there was no actual centering logic
    // before this).
    init(identifier: NSTouchBarItem.Identifier, leftItems: [NSTouchBarItem], centerItem: NSTouchBarItem?, rightItems: [NSTouchBarItem], swipeItems: [SwipeItem]) {
        super.init(identifier: identifier)
        self.swipeItems = swipeItems

        // Left as frame-based (translatesAutoresizingMaskIntoConstraints
        // stays true, matching what the old plain NSStackView did) so the
        // Touch Bar system's own external sizing of this item's view keeps
        // working exactly as before — only the subviews below opt into Auto
        // Layout, positioned relative to container's bounds.
        let container = NSView()

        let leftStack = NSStackView(views: leftItems.compactMap { $0.view })
        leftStack.spacing = 8
        leftStack.orientation = .horizontal
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: rightItems.compactMap { $0.view })
        rightStack.spacing = 8
        rightStack.orientation = .horizontal
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(leftStack)
        container.addSubview(rightStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftStack.topAnchor.constraint(equalTo: container.topAnchor),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightStack.topAnchor.constraint(equalTo: container.topAnchor),
            rightStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        if let centerView = centerItem?.view {
            // ScrollViewItem sizes its NSScrollView's frame to its content's
            // fittingSize at construction time, but NSScrollView reports no
            // meaningful intrinsicContentSize of its own — capture that
            // frame width now, before switching to Auto Layout below (which
            // otherwise leaves the view's width ambiguous/zero).
            let centerWidth = max(centerView.frame.width, 0)
            centerView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(centerView)

            // Required: never let center content overlap the left/right
            // items — takes priority over being perfectly centered when
            // space is tight (graceful degradation, not a layout break).
            let clearsLeft = centerView.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 8)
            let clearsRight = rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: centerView.trailingAnchor, constant: 8)
            clearsLeft.priority = .required
            clearsRight.priority = .required

            // High but not required: true horizontal centering, yielded to
            // the anti-overlap constraints above rather than fighting them.
            let centered = centerView.centerXAnchor.constraint(equalTo: container.centerXAnchor)
            centered.priority = .defaultHigh

            // Also not required: if a widget's content genuinely can't fit
            // alongside left/right items at its natural width, this should
            // compress rather than hard-conflict with the required
            // clearsLeft/clearsRight constraints above (a conflict silently
            // produces undefined/clipped layout instead of an intentional
            // shrink).
            let width = centerView.widthAnchor.constraint(equalToConstant: centerWidth)
            width.priority = .defaultHigh

            NSLayoutConstraint.activate([
                clearsLeft, clearsRight, centered, width,
                centerView.topAnchor.constraint(equalTo: container.topAnchor),
                centerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        view = container

        twofingers = NSPanGestureRecognizer(target: self, action: #selector(twofingersHandler(_:)))
        twofingers.numberOfTouchesRequired = 2
        twofingers.allowedTouchTypes = .direct
        view.addGestureRecognizer(twofingers)

        threefingers = NSPanGestureRecognizer(target: self, action: #selector(threefingersHandler(_:)))
        threefingers.numberOfTouchesRequired = 3
        threefingers.allowedTouchTypes = .direct
        view.addGestureRecognizer(threefingers)

        fourfingers = NSPanGestureRecognizer(target: self, action: #selector(fourfingersHandler(_:)))
        fourfingers.numberOfTouchesRequired = 4
        fourfingers.allowedTouchTypes = .direct
        view.addGestureRecognizer(fourfingers)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func gestureHandler(position: CGFloat, fingers: Int, state: NSGestureRecognizer.State) {
        switch state {
        case .began:
            prevPositions[fingers] = position
            legacyPrevPositions[fingers] = position
        case .changed:
            if self.legacyGesturesEnabled {
                if fingers == 2 {
                    let prevPos = legacyPrevPositions[fingers]!
                    if ((position - prevPos) > 10) || ((prevPos - position) > 10) {
                        if position > prevPos {
                            HIDPostAuxKey(NX_KEYTYPE_SOUND_UP)
                        } else if position < prevPos {
                            HIDPostAuxKey(NX_KEYTYPE_SOUND_DOWN)
                        }
                        legacyPrevPositions[fingers] = position
                    }
                }
                if fingers == 3 {
                    let prevPos = legacyPrevPositions[fingers]!
                    if ((position - prevPos) > 15) || ((prevPos - position) > 15) {
                        if position > prevPos {
                            HIDPostAuxKey(NX_KEYTYPE_BRIGHTNESS_UP)
                        } else if position < prevPos {
                            HIDPostAuxKey(NX_KEYTYPE_BRIGHTNESS_DOWN)
                        }
                        legacyPrevPositions[fingers] = position
                    }
                }
            }
        case .ended:
            print("gesture ended \(position - prevPositions[fingers]!) \(fingers)")
            for item in swipeItems {
                item.processEvent(offset: position - prevPositions[fingers]!, fingers: fingers)
            }
        default:
            break
        }
    }

    @objc func twofingersHandler(_ sender: NSGestureRecognizer?) {
        let position = (sender?.location(in: sender?.view).x)!
        self.gestureHandler(position: position, fingers: 2, state: sender!.state)
    }

    @objc func threefingersHandler(_ sender: NSGestureRecognizer?) {
        let position = (sender?.location(in: sender?.view).x)!
        self.gestureHandler(position: position, fingers: 3, state: sender!.state)
    }

    @objc func fourfingersHandler(_ sender: NSGestureRecognizer?) {
        let position = (sender?.location(in: sender?.view).x)!
        self.gestureHandler(position: position, fingers: 4, state: sender!.state)
    }
}
