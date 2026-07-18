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
    private var itemButtons: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
    private var itemIdentifiers: [NSTouchBarItem.Identifier] = []

    static let cacheDir: String = {
        let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
            .appending("/MTMR/icons/bookmarks-cache")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }()

    init(identifier: NSTouchBarItem.Identifier, source: SourceProtocol) {
        self.source = source
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
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
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
            button.actions.append(ItemAction(trigger: .singleTap, {
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = ["-a", "Brave Browser Nightly", urlString]
                try? task.run()
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
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()

        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let hexString = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hexString.isEmpty else {
            return nil
        }
        return Data(hexEncoded: hexString)
    }

    private static func fetchFromNetwork(host: String) -> Data? {
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        return try? Data(contentsOf: url)
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
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
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
