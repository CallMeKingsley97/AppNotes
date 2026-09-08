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
        return "<html><script type=\"application/json\" id=\"serialized-server-data\">\(String(decoding: data, as: UTF8.self))</script></html>"
    }

    static func details(app: AppEntry = app, country: String = "cn", language: String = "zh-Hans") throws -> AppDetails {
        let listing = try listing(for: app, language: language)
        let page = try StorePageDetails.parse(pageHTML(listing: listing, language: language, country: country),
                                             listing: listing, country: country)
        return AppDetails(listing: listing, country: country, language: language, fetchedAt: Date(), page: page)
    }
}

struct FixtureDetailsLoader: AppDetailsLoading {
    func fetch(app: AppEntry, country: String, language: String) async throws -> AppDetails {
        try DetailsFixtures.details(app: app, country: country, language: language)
    }
}
