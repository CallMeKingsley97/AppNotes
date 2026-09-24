import Foundation

@main
struct ManualImportTests {
    static func main() async throws {
        let pages = "https://apps.apple.com/cn/app/pages/id409201541?mt=12"
        let parsed = AppStoreLink.parse(pages)
        precondition(parsed?.trackID == 409201541 && parsed?.countryCode == "cn")
        precondition(AppStoreLink.parse("https://apps.apple.com/app/id409201541")?.countryCode == nil)
precondition(AppStoreLink.parse("https://apps.apple.com/cn/app/微信/id836500024")?.trackID == 836500024)
        precondition(AppStoreLink.parse("https://www.geo.itunes.apple.com/us/app/xcode/id497799835")?.trackID == 497799835)
        precondition(AppStoreLink.parse("itms-apps://apps.apple.com/cn/app/id836500024")?.trackID == 836500024)
        precondition(AppStoreLink.parse("macappstore://apps.apple.com/cn/app/pages/id409201541")?.countryCode == "cn")
        precondition(AppStoreLink.parse("看看这个 \(pages) 吧")?.trackID == 409201541)
        precondition(AppStoreLink.parse("https://apps.apple.com/cn/developer/apple/id284417353") == nil)
        precondition(AppStoreLink.parse("https://apps.apple.com/cn/iphone/search?term=pages") == nil)
        precondition(AppStoreLink.parse("https://example.com/app/id409201541") == nil)
        precondition(AppStoreLink.parse("  ") == nil)

        let installed = AppEntry(path: "/Applications/Pages.app", name: "Pages", bundleID: "com.apple.iWork.Pages",
                                 version: "14.1", appStoreID: 409201541, storefrontCountryCode: "cn")
        let downloaded = AppEntry(path: "/Applications/Editor.app", name: "Editor", bundleID: "com.example.editor",
                                  version: "1", appStoreID: nil, storefrontCountryCode: nil)
        let imported = ManualImportRecord(appStoreID: 836500024, name: "微信", bundleID: "com.tencent.xinWeChat",
                                          version: "4", seller: "Tencent", storefrontCountryCode: "cn",
                                          artworkURL: "https://example.com/wechat.png").entry
        precondition(AppCategory.of(imported) == .manual)
        precondition(AppCategory.of(installed) == .appStore)
        let visible = LibraryCatalog.combine(installed: [installed, downloaded], imported: [imported, installed])
        precondition(Set(visible.map(\.name)) == ["Editor", "Pages", "微信"])
        precondition(visible.filter { $0.origin == .manual }.map(\.name) == ["微信"])
        precondition(!visible.contains { $0.origin == .manual && $0.appStoreID == 409201541 })

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppNotesImports-\(UUID().uuidString)")
        let store = ManualImportStore(directory: directory)
        let record = importedRecord(836500024, name: "微信", bundle: "com.tencent.xinWeChat")
        precondition(store.add(record))
        precondition(store.add(importedRecord(836500024, name: "微信 WeChat", bundle: "com.tencent.xinWeChat")))
        precondition(store.records.count == 1 && store.records[0].name == "微信 WeChat")
        let restored = ManualImportStore(directory: directory)
        precondition(restored.entries.map(\.path) == [ManualImportRecord.path(for: 836500024)])
        precondition(restored.entries[0].artworkURL == "https://example.com/icon.png")
        precondition(restored.remove(836500024) && restored.records.isEmpty)
        precondition(ManualImportStore(directory: directory).records.isEmpty)

        let failedDirectory = directory.appendingPathComponent("write-failure")
        let failed = ManualImportStore(directory: failedDirectory)
        try FileManager.default.createDirectory(at: failedDirectory.appendingPathComponent("manual-imports.json"),
                                                withIntermediateDirectories: true)
        precondition(!failed.add(record) && failed.records.isEmpty && failed.errorKey == "import.saveFailed")

        let corruptedDirectory = directory.appendingPathComponent("invalid-data")
        try FileManager.default.createDirectory(at: corruptedDirectory, withIntermediateDirectories: true)
        let file = corruptedDirectory.appendingPathComponent("manual-imports.json")
        let original = Data("invalid json".utf8)
        try original.write(to: file)
        let corrupted = ManualImportStore(directory: corruptedDirectory)
        precondition(corrupted.errorKey == "import.loadFailed")
        precondition(!corrupted.add(record))
        let kept = try Data(contentsOf: file)
        precondition(kept == original)

        let link = AppStoreLink.parse(pages)!
        let prompt = await ClipboardImport.resolve(clipboard: "复制 \(pages)", existing: [downloaded]) { requested in
            precondition(requested == link)
            return importedRecord(link.trackID, name: "Pages", bundle: "com.apple.iWork.Pages")
        }
        guard case .prompt(let prompted) = prompt else { throw Failure("expected a prompt") }
        precondition(prompted.name == "Pages" && prompted.storefrontCountryCode == "cn")
        let ignored = await ClipboardImport.resolve(clipboard: pages, existing: [installed]) { _ in
            throw Failure("lookup should not run when the app is already listed")
        }
        precondition(ignored == .ignore)
        let sameBundle = await ClipboardImport.resolve(clipboard: pages, existing: [downloaded]) { _ in
            importedRecord(link.trackID, name: "Pages", bundle: downloaded.bundleID)
        }
        precondition(sameBundle == .ignore)
        let unavailable = await ClipboardImport.resolve(clipboard: pages, existing: []) { _ in nil }
        precondition(unavailable == .failed)
        let offline = await ClipboardImport.resolve(clipboard: pages, existing: []) { _ in
            throw URLError(.notConnectedToInternet)
        }
        precondition(offline == .failed)
        let plain = await ClipboardImport.resolve(clipboard: "hello", existing: []) { _ in nil }
        precondition(plain == .ignore)

        let json = Data(#"""
        {"resultCount":2,"results":[
          {"trackId":409201541,"trackName":"Pages","bundleId":"com.apple.Pages.ios","sellerName":"","artistName":"Apple","version":"14","artworkUrl100":"https://example.com/ios.png","wrapperType":"software","kind":"software"},
          {"trackId":409201541,"trackName":"Pages","bundleId":"com.apple.iWork.Pages","sellerName":"Apple Distribution","version":"14.4","artworkUrl512":"https://example.com/mac.png","wrapperType":"software","kind":"mac-software"}
        ]}
        """#.utf8)
        let decoded = AppStoreLinkLookup.record(from: json, country: "cn", trackID: 409201541)
        precondition(decoded?.bundleID == "com.apple.iWork.Pages")
        precondition(decoded?.seller == "Apple Distribution")
        precondition(decoded?.artworkURL == "https://example.com/mac.png")
        precondition(decoded?.entry.origin == .manual)
        precondition(AppStoreLinkLookup.record(from: Data(#"{"results":[]}"#.utf8), country: "us", trackID: 1) == nil)
        print("Passed: App Store link parsing, manual import persistence, source deduplication, and import prompts.")
    }

    private static func importedRecord(_ id: Int64, name: String, bundle: String?) -> ManualImportRecord {
        ManualImportRecord(appStoreID: id, name: name, bundleID: bundle, version: "1", seller: "Apple",
                           storefrontCountryCode: "cn", artworkURL: "https://example.com/icon.png")
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
