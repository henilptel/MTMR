//
//  BookmarksBarItem.swift
//  MTMR
//
//  A collapsible group whose bookmark buttons are read fresh from a plain
//  text file (one URL per line, blank lines and "#" comments ignored) every
//  time it's opened, instead of being hardcoded in items.json. Favicons are
//  resolved once per domain and cached to disk (Brave's local favicon
//  database first, a network fetch of /favicon.ico as fallback), so opening
//  the group is always fast/local after a bookmark's first appearance.
//

import Cocoa

class BookmarksBarItem: NSPopoverTouchBarItem, NSTouchBarDelegate {
    private let source: SourceProtocol
    // Which app to open bookmarks in — e.g. "Brave Browser Nightly". Optional:
    // when nil, links open via NSWorkspace.shared.open(url), i.e. whatever
    // the user's actual default browser/handler is, so this widget works for
    // anyone regardless of which browser they use, not just Brave.
    private let openInApp: String?
    private var itemButtons: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
    private var itemIdentifiers: [NSTouchBarItem.Identifier] = []

    static let cacheDir: String = {
        let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
            .appending("/MTMR/icons/bookmarks-cache")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }()

    init(identifier: NSTouchBarItem.Identifier, source: SourceProtocol, openInApp: String?) {
        self.source = source
        self.openInApp = openInApp
        super.init(identifier: identifier)
        popoverTouchBar.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func readURLs() -> [String] {
        guard let content = source.string else { return [] }
        return content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty, !line.hasPrefix("#") else { return false }
                // Only accept http(s) links with a parseable host — anything
                // else (a stray typo, a non-URL line accidentally pasted in)
                // would otherwise silently become a button that does nothing
                // useful when tapped ("open -a Brave <garbage>" fails quietly
                // at the OS level) instead of just being skipped.
                guard let url = URL(string: line), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", url.host != nil else {
                    return false
                }
                return true
            }
    }

    @objc override func showPopover(_ sender: Any?) {
        itemButtons = [:]
        itemIdentifiers = []

        let urls = readURLs()
        let uid = UUID().uuidString

        for (index, urlString) in urls.enumerated() {
            let identifier = NSTouchBarItem.Identifier("com.toxblh.mtmr.bookmark.\(index).\(uid)")
            let button = CustomButtonTouchBarItem(identifier: identifier, title: "")
            button.image = BookmarksBarItem.iconForURL(urlString)
            button.isBordered = true
            let targetApp = openInApp
            button.actions.append(ItemAction(trigger: .singleTap, {
                if let targetApp = targetApp {
                    let task = Process()
                    task.launchPath = "/usr/bin/open"
                    task.arguments = ["-a", targetApp, urlString]
                    try? task.run()
                } else if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }))
            itemButtons[identifier] = button
            itemIdentifiers.append(identifier)
        }

        let closeIdentifier = NSTouchBarItem.Identifier("com.toxblh.mtmr.bookmarks.close.\(uid)")
        let closeButton = CustomButtonTouchBarItem(identifier: closeIdentifier, title: "")
        closeButton.image = NSImage(named: NSImage.stopProgressFreestandingTemplateName)
        closeButton.actions.append(ItemAction(trigger: .singleTap, {
            TouchBarController.shared.touchBar.delegate = TouchBarController.shared
            TouchBarController.shared.touchBar.defaultItemIdentifiers = [TouchBarController.shared.basicViewIdentifier]
        }))
        itemButtons[closeIdentifier] = closeButton
        itemIdentifiers.append(closeIdentifier)

        TouchBarController.shared.touchBar.delegate = self
        TouchBarController.shared.touchBar.defaultItemIdentifiers = itemIdentifiers

        // Any bookmark not yet cached shows the generic fallback icon above for
        // this open, but gets resolved in the background so the *next* open
        // has its real favicon — never blocks showing the popover on a
        // network/disk lookup.
        DispatchQueue.global(qos: .utility).async {
            for urlString in urls {
                BookmarksBarItem.ensureCachedIcon(for: urlString)
            }
        }
    }

    func touchBar(_: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        return itemButtons[identifier]
    }

    // MARK: - Favicon resolution

    private static func domainKey(for urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return host.replacingOccurrences(of: ".", with: "_")
    }

    private static func cachedIconPath(for urlString: String) -> String? {
        guard let key = domainKey(for: urlString) else { return nil }
        let path = "\(cacheDir)/\(key).png"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static let genericBookmarkIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil),
           let configured = symbol.withSymbolConfiguration(config) {
            // Template mode instead of an explicit palette color (that API needs
            // macOS 12+, this project targets older) — the system auto-tints
            // template images appropriately for the Touch Bar's dark context.
            configured.isTemplate = true
            return configured
        }
        return NSImage()
    }()

    static func iconForURL(_ urlString: String) -> NSImage {
        if let path = cachedIconPath(for: urlString), let image = NSImage(contentsOfFile: path) {
            return image
        }
        return genericBookmarkIcon
    }

    @discardableResult
    static func ensureCachedIcon(for urlString: String) -> String? {
        if let existing = cachedIconPath(for: urlString) { return existing }
        guard let key = domainKey(for: urlString), let host = URL(string: urlString)?.host else { return nil }
        let destPath = "\(cacheDir)/\(key).png"

        if let localData = fetchFromBraveHistory(host: host), writeCleanPNG(data: localData, to: destPath) {
            return destPath
        }
        if let networkData = fetchFromNetwork(host: host), writeCleanPNG(data: networkData, to: destPath) {
            return destPath
        }
        return nil
    }

    private static func fetchFromBraveHistory(host: String) -> Data? {
        let faviconsDB = NSHomeDirectory().appending("/Library/Application Support/BraveSoftware/Brave-Browser-Nightly/Default/Favicons")
        guard FileManager.default.fileExists(atPath: faviconsDB) else { return nil }

        let tmpCopy = NSTemporaryDirectory().appending("mtmr_favicons_\(UUID().uuidString).db")
        guard (try? FileManager.default.copyItem(atPath: faviconsDB, toPath: tmpCopy)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(atPath: tmpCopy) }

        let query = """
        SELECT hex(fb.image_data) FROM icon_mapping im
        JOIN favicons f ON im.icon_id = f.id
        JOIN favicon_bitmaps fb ON fb.icon_id = f.id
        WHERE im.page_url LIKE '%\(host)%'
        ORDER BY fb.width DESC LIMIT 1;
        """

        let task = Process()
        task.launchPath = "/usr/bin/sqlite3"
        task.arguments = [tmpCopy, query]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        guard (try? task.run()) != nil else { return nil }

        // Drain both pipes concurrently with the process running, not just
        // after waitUntilExit() — a pipe's OS buffer is finite (~64KB), and
        // reading stdout only after the process exits (with stderr never
        // read at all, as this used to do) means a child that fills either
        // buffer while still running blocks on write() forever, while we're
        // blocked in waitUntilExit() waiting for it to exit: a real
        // Process+Pipe deadlock, not just a theoretical one.
        let drainGroup = DispatchGroup()
        var outData = Data()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile() // drain only, content unused
            drainGroup.leave()
        }
        task.waitUntilExit()
        drainGroup.wait()

        // A non-zero exit (malformed/locked DB despite the copy, schema
        // mismatch in a future Brave version, etc.) means the query didn't
        // actually succeed — treat that the same as "no favicon found"
        // rather than trying to hex-decode whatever partial/empty output
        // came back.
        guard task.terminationStatus == 0 else { return nil }

        guard let hexString = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hexString.isEmpty else {
            return nil
        }
        return Data(hexEncoded: hexString)
    }

    private static func fetchFromNetwork(host: String) -> Data? {
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }

        // Data(contentsOf:) uses a long default timeout (up to 60s) with no
        // way to override it — an unreachable/slow domain would otherwise
        // stall this background prefetch pass for a full minute per
        // bookmark. Use URLSession with an explicit short timeout instead,
        // and turn the async API into a blocking call with a semaphore since
        // this whole resolution pass is already running off the main thread
        // on a background queue (see showPopover's prefetch dispatch) and is
        // meant to complete quickly, not fan out into more concurrency.
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0

        var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data = data, !data.isEmpty else {
                return
            }
            result = data
        }
        task.resume()
        // Wait slightly longer than the request timeout so we don't cut off
        // a response that's about to arrive right at the timeout boundary.
        _ = semaphore.wait(timeout: .now() + request.timeoutInterval + 1.0)
        return result
    }

    private static func writeCleanPNG(data: Data, to path: String) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        let size = NSSize(width: 22, height: 22)
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        // Write to a temp file in the same directory then rename into place.
        // A plain write(to:) that gets interrupted (app quit, disk full
        // mid-write) could leave a truncated/corrupt PNG sitting at the
        // final path — cachedIconPath() only checks *existence*, not
        // validity, so a corrupt file would permanently block ever
        // re-fetching that bookmark's real favicon. rename(2) is atomic, so
        // the final path only ever contains a complete file or doesn't
        // exist at all.
        let tempPath = "\(path).tmp-\(UUID().uuidString)"
        let tempURL = URL(fileURLWithPath: tempPath)
        do {
            try png.write(to: tempURL)
            _ = try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: tempPath, toPath: path)
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            return false
        }
    }
}

private extension Data {
    init?(hexEncoded hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
