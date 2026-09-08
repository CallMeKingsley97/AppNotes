import Foundation

@main
struct CustomCategoryTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppNotesCategories-\(UUID().uuidString)")
        let store = CustomCategoryStore(directory: directory)
        let rocket = AppEntry(path: "/Applications/Shadowrocket.app", name: "Shadowrocket", bundleID: "test.rocket",
                              version: "1", appStoreID: nil, storefrontCountryCode: nil)
        let egern = AppEntry(path: "/Applications/Egern.app", name: "Egern", bundleID: "test.egern",
                             version: "1", appStoreID: nil, storefrontCountryCode: nil)
        let editor = AppEntry(path: "/Applications/Editor.app", name: "Editor", bundleID: "test.editor",
                              version: "1", appStoreID: nil, storefrontCountryCode: nil)
        let apps = [rocket, egern, editor]
        precondition(store.create(name: " \n ") == nil)
        let network = store.create(name: " 翻墙 \n", including: rocket)!
        precondition(network.name == "翻墙")
        precondition(store.create(name: "翻墙") == nil)
        let work = store.create(name: "Work")!
        precondition(store.create(name: " work ") == nil)
        precondition(!store.rename(network, to: "WORK"))
        precondition(store.contains(rocket, in: network))
        store.setMembership(egern, in: network, included: true)
        store.setMembership(egern, in: network, included: true)
        store.setMembership(rocket, in: work, included: true)
        precondition(store.apps(in: network, from: apps).map(\.name) == ["Shadowrocket", "Egern"])
        precondition(store.apps(in: work, from: apps).map(\.name) == ["Shadowrocket"])

        // A rename keeps the stable category identity and all memberships across relaunches.
        precondition(store.rename(network, to: "网络工具"))
        let restored = CustomCategoryStore(directory: directory)
        precondition(restored.categories.first?.id == network.id && restored.categories.first?.name == "网络工具")
        precondition(restored.apps(in: network, from: apps).map(\.path) == [rocket.path, egern.path])
        let updatedRocket = AppEntry(path: rocket.path, name: "Shadowrocket 2", bundleID: rocket.bundleID,
                                     version: "2", appStoreID: nil, storefrontCountryCode: nil)
        precondition(restored.contains(updatedRocket, in: network))

        // Editing installed apps doesn't erase a temporarily unavailable app's membership.
        precondition(restored.update(network, apps: [rocket, editor], selectedPaths: [editor.path]))
        precondition(!restored.contains(rocket, in: network) && restored.contains(egern, in: network))
        precondition(restored.contains(editor, in: network) && restored.contains(rocket, in: work))
        precondition(restored.apps(in: network, from: [rocket, editor]).map(\.path) == [editor.path])
        precondition(restored.apps(in: network, from: apps).map(\.path) == [egern.path, editor.path])

        let notes = NotesStore(directory: directory)
        notes.set("Keep my note", for: rocket.path)
        notes.flush()
        precondition(restored.delete(network))
        precondition(restored.memberships.values.allSatisfy { !$0.contains(network.id) })
        precondition(restored.contains(rocket, in: work))
        precondition(NotesStore(directory: directory).note(for: rocket.path) == "Keep my note")
        precondition(!restored.update(network, apps: apps, selectedPaths: [rocket.path]))
        let afterDelete = CustomCategoryStore(directory: directory)
        precondition(afterDelete.categories.map(\.id) == [work.id])
        precondition(afterDelete.memberships == restored.memberships)

        let failedDirectory = directory.appendingPathComponent("write-failure")
        let failed = CustomCategoryStore(directory: failedDirectory)
        try FileManager.default.createDirectory(at: failedDirectory.appendingPathComponent("custom-categories.json"),
                                                withIntermediateDirectories: true)
        precondition(failed.create(name: "Unsaved") == nil && failed.categories.isEmpty)
        precondition(failed.errorKey == "category.saveFailed")

        let corruptedDirectory = directory.appendingPathComponent("invalid-data")
        try FileManager.default.createDirectory(at: corruptedDirectory, withIntermediateDirectories: true)
        let file = corruptedDirectory.appendingPathComponent("custom-categories.json")
        let original = Data("invalid json".utf8)
        try original.write(to: file)
        let corrupted = CustomCategoryStore(directory: corruptedDirectory)
        precondition(corrupted.errorKey == "category.loadFailed")
        precondition(corrupted.create(name: "Do not overwrite") == nil)
        let kept = try Data(contentsOf: file)
        precondition(kept == original)
        print("Passed: custom categories, name validation, multiple memberships, bulk edits, rescan and relaunch persistence, deletion isolation, and storage failure handling.")
    }
}
