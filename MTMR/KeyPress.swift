//
//  KeyPress.swift
//  MTMR
//
//  Created by Anton Palgunov on 17/03/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Foundation

protocol KeyPress {
    var keyCode: CGKeyCode { get }
    var flags: CGEventFlags { get }
    func send()
}

struct GenericKeyPress: KeyPress {
    var keyCode: CGKeyCode
    var flags: CGEventFlags = []
}

extension KeyPress {
    func send() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        if !flags.isEmpty {
            keyDown?.flags = flags
            keyUp?.flags = flags
        }

        let loc: CGEventTapLocation = .cghidEventTap
        keyDown?.post(tap: loc)
        keyUp?.post(tap: loc)
    }
}

// Maps JSON modifier names ("command"/"cmd", "option"/"alt", "control"/"ctrl", "shift")
// to CGEventFlags for the keyPress action, so it can send shortcuts like Cmd+Option+I
// natively (posting a CGEvent directly) instead of needing AppleScript + System Events.
func parseModifierFlags(_ names: [String]?) -> CGEventFlags {
    guard let names = names else { return [] }
    var flags: CGEventFlags = []
    for name in names {
        switch name.lowercased() {
        case "command", "cmd": flags.insert(.maskCommand)
        case "option", "alt": flags.insert(.maskAlternate)
        case "control", "ctrl": flags.insert(.maskControl)
        case "shift": flags.insert(.maskShift)
        default: break
        }
    }
    return flags
}

func HIDPostAuxKey(_ key: Int32) {
    let key = UInt8(key)
    MediaKeys.hidPostAuxKey(key)
}
