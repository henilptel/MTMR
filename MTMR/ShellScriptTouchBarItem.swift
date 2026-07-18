//
//  ShellScriptTouchBarItem.swift
//  MTMR
//
//  Created by bobr on 08/08/2019.
//  Copyright © 2019 Anton Palgunov. All rights reserved.
//
import Foundation

class ShellScriptTouchBarItem: CustomButtonTouchBarItem, RefreshSuppressible {
    private let interval: TimeInterval
    private let source: String
    private var forceHideConstraint: NSLayoutConstraint!

    // Tracks the freshest fetched result independent of whether it's
    // currently being displayed, so a cycleScriptOutput action can show it
    // immediately on returning to index 0 rather than a stale snapshot from
    // whenever cycling started — see RefreshSuppressible's doc comment.
    private var isRefreshSuppressed = false
    private var latestAttributedTitle: NSAttributedString?
    private var latestImage: NSImage?
    private var latestForceHide = false
    private var latestBackgroundColor: NSColor?

    struct ScriptResult: Decodable {
        var title: String?
        var image: Source?
    }

    init?(identifier: NSTouchBarItem.Identifier, source: SourceProtocol, interval: TimeInterval) {
        self.interval = interval
        self.source = source.string ?? "echo No \"source\""
        super.init(identifier: identifier, title: "⏳")
        
        forceHideConstraint = view.widthAnchor.constraint(equalToConstant: 0)
        
        DispatchQueue.shellScriptQueue.async {
            self.refreshAndSchedule()
        }
    }
    
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func refreshAndSchedule() {
        // Execute script and get result
        let scriptResult = execute(source)
        var rawTitle: String, image: NSImage?
        var json: Bool

        do {
            let decoder = JSONDecoder()
            let result = try decoder.decode(ScriptResult.self, from: scriptResult.data(using: .utf8)!)
            json = true
            rawTitle = result.title ?? ""
            image = result.image?.image
        } catch {
            json = false
            rawTitle = scriptResult
        }

        // Apply returned text attributes (if they were returned) to our result string
        let helper = AMR_ANSIEscapeHelper.init()
        helper.defaultStringColor = NSColor.white
        helper.font = "1".defaultTouchbarAttributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let title = NSMutableAttributedString.init(attributedString: helper.attributedString(withANSIEscapedString: rawTitle) ?? NSAttributedString(string: ""))
        title.addAttributes([.baselineOffset: 1], range: NSRange(location: 0, length: title.length))
        let newBackgoundColor: NSColor? = title.length != 0 ? title.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        
        // Update UI — always track the freshest result (for RefreshSuppressible),
        // but only apply it to what's actually visible when not suppressed by
        // an active cycle override.
        DispatchQueue.main.async { [weak self, newBackgoundColor] in
            guard let self = self else { return }
            self.latestAttributedTitle = title
            self.latestBackgroundColor = newBackgoundColor
            if json {
                self.latestImage = image
            }
            self.latestForceHide = scriptResult == ""

            guard !self.isRefreshSuppressed else { return }
            if (newBackgoundColor != self.backgroundColor) { // performance optimization because of reinstallButton
                self.backgroundColor = newBackgoundColor
            }
            self.attributedTitle = title
            if json {
                self.image = image
            }
            self.forceHideConstraint.isActive = scriptResult == ""
        }

        // Schedule next update
        DispatchQueue.shellScriptQueue.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.refreshAndSchedule()
        }
    }

    func suppressAutoRefresh(_ suppressed: Bool) {
        isRefreshSuppressed = suppressed
    }

    func restoreLatestAutoRefreshedTitle() {
        if let color = latestBackgroundColor, color != backgroundColor {
            backgroundColor = latestBackgroundColor
        }
        if let title = latestAttributedTitle {
            attributedTitle = title
        }
        if let image = latestImage {
            self.image = image
        }
        if forceHideConstraint != nil {
            forceHideConstraint.isActive = latestForceHide
        }
    }

    func execute(_ command: String) -> String {
        return ShellScriptTouchBarItem.runCapturingOutput(command, timeout: interval)
    }

    // Extracted from the instance method above so other tap-driven actions
    // (see TouchBarController's cycleScriptOutput handling) can capture a
    // script's output too, without duplicating the Process/Pipe setup.
    static func runCapturingOutput(_ command: String, timeout: TimeInterval) -> String {
        let task = Process()
        if let shell = getenv("SHELL") {
            task.launchPath = String.init(cString: shell)
        } else {
            task.launchPath = "/bin/bash"
        }
        task.arguments = ["-c", command]

        let pipe = Pipe()
        task.standardOutput = pipe

        // kill process if it runs over the caller's own timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak task] in
            task?.terminate()
        }

        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var output: String = NSString(data: data, encoding: String.Encoding.utf8.rawValue) as String? ?? ""

        //always wait until task end or you can catch "task still running" error while accessing task.terminationStatus variable
        task.waitUntilExit()
        if (output == "" && task.terminationStatus != 0) {
            output = "error"
        }

        return output.replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
    }
}

extension DispatchQueue {
    static let shellScriptQueue = DispatchQueue(label: "mtmr.shellscript")
}
