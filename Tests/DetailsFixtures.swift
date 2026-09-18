import Foundation

// Compact fixtures mirror the public App Store information shelf observed on 2026-09-08.
// Descriptions and app identities used for UI renders are test data, never persisted to user storage.
enum DetailsFixtures {
    static let app = AppEntry(path: "/Applications/Example.app", name: "Example",
                              bundleID: "com.example.mac", version: "3.15", appStoreID: 6757103562,
                              storefrontCountryCode: "cn")

    static func listing(for app: AppEntry = app, language: String = "zh-Hans") throws -> StoreListing {
        let text = language == "zh-Hans"
            ? "为每一次工作保留清晰的上下文，轻松整理灵感、记录快捷键，并快速找到所需的工具。\n\n支持本地保存与快捷搜索，让日常使用更加从容。\n\n主要功能\n• 整理日常工作与项目灵感\n• 快速访问常用内容\n• 让信息保持清晰、有序"
            : "Keep useful context close at hand. Organize ideas, remember shortcuts, and quickly find the tools you need.\n\nLocal storage and quick search make everyday work feel effortless.\n\nHighlights\n• Organize projects and everyday ideas\n• Find useful information quickly\n• Keep your workspace clear and focused"
        let raw: [String: Any] = [
            "trackId": app.appStoreID ?? 6757103562, "bundleId": app.bundleID ?? "com.example.mac",
            "trackName": app.name, "kind": "mac-software", "description": text,
            "sellerName": "Example Studio", "artistViewUrl": "https://apps.apple.com/cn/developer/id1758343835",
            "version": "3.16", "price": 0, "currency": "CNY", "formattedPrice": "免费",
            "averageUserRating": 4.5, "userRatingCount": 14,
            "genres": [language == "zh-Hans" ? "效率" : "Productivity"],
            "contentAdvisoryRating": "4+", "languageCodesISO2A": ["ZH", "EN"],
            "fileSizeBytes": "55837696", "minimumOsVersion": "14.0",
            "currentVersionReleaseDate": "2026-09-04T22:06:25Z"
        ]
        return try JSONDecoder().decode(StoreListing.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    static func pageHTML(listing: StoreListing, language: String = "zh-Hans", purchases: Bool? = true,
                         includeList: Bool = true, country: String = "cn") throws -> String {
        let chinese = language == "zh-Hans"
        var offer: [String: Any] = [:]
        if let purchases { offer["hasInAppPurchases"] = purchases }
        let pairs = includeList && purchases == true
            ? [["Pro 终身会员", "¥68.00"], ["Ultimate 终身会员", "¥168.00"], ["Ultimate", "¥98.00"], ["Ultimate", "¥28.00"]]
            : []
        let page: [String: Any] = [
            "intent": ["id": String(listing.trackId), "storefront": country],
            "data": [
                "lockup": ["adamId": String(listing.trackId), "bundleId": listing.bundleId ?? ""],
                "titleOfferDisplayProperties": offer,
                "shelfMapping": [
                    "information": ["items": [
                        ["title": chinese ? "兼容性" : "Compatibility",
                         "items": [["heading": "Mac", "text": chinese
                                    ? "需要 macOS 14.0 或更高版本以及装有 Apple M1 或更高版本芯片的 Mac。"
                                    : "Requires macOS 14.0 or later and a Mac with Apple M1 chip or later."]]],
                        ["title": chinese ? "App内购买" : "In-App Purchases", "items": [["textPairs": pairs]]]
                    ]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["data": [page]])
        let currentNotes = chinese
            ? "优化本地缓存，修复搜索结果可能重复的问题。"
            : "Improve local caching and fix duplicated search results."
        let previousNotes = chinese
            ? "新增键盘快捷键，列表加载速度更快。当前版本 &amp; 上一版本都支持这些改进。"
            : "Add keyboard shortcuts and make lists load faster. Both the current &amp; previous versions include these changes."
        let datePrefix = String(listing.currentVersionReleaseDate?.prefix(10) ?? "2026-09-04")
        let releaseHistory = #"""
            <section id="mostRecentVersion" data-test-id="shelf-wrapper" aria-label="新功能">
              <div class="content-container"><ul>
                <li><p class="detail"><span class="notes">\#(currentNotes)</span><div class="metadata"><span>\#(listing.version ?? "1.0")</span><time datetime="\#(datePrefix)">2 days ago</time></div></p></li>
                <li><p class="detail"><span class="notes">\#(previousNotes)</span><div class="metadata"><span>1.9</span><time datetime="2026-08-12">August 13</time></div></p></li>
              </ul></div>
            </section>
            """#
        return "<html><script type=\"application/json\" id=\"serialized-server-data\">\(String(decoding: data, as: UTF8.self))</script>\(releaseHistory)</html>"
    }

    static func details(app: AppEntry = app, country: String = "cn", language: String = "zh-Hans") throws -> AppDetails {
        let listing = try listing(for: app, language: language)
        let page = try StorePageDetails.parse(pageHTML(listing: listing, language: language, country: country),
                                             listing: listing, country: country)
        return AppDetails(listing: listing, country: country, language: language, fetchedAt: Date(),
                          page: page, schemaVersion: AppDetails.currentSchemaVersion)
    }
}

struct FixtureDetailsLoader: AppDetailsLoading {
    func fetch(app: AppEntry, country: String, language: String) async throws -> AppDetails {
        try DetailsFixtures.details(app: app, country: country, language: language)
    }
}
