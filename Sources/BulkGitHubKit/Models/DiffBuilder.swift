import Foundation

public struct DiffLine: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case context, removed, added
    }

    public let kind: Kind
    public let text: String
    public let id: Int

    init(kind: Kind, text: String, id: Int) {
        self.kind = kind
        self.text = text
        self.id = id
    }
}

/// Line diff for execution-plan review, built on CollectionDifference.
public enum DiffBuilder {

    public static func lines(before: String, after: String) -> [DiffLine] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        let difference = new.difference(from: old)

        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        var result: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        var id = 0
        while oldIndex < old.count || newIndex < new.count {
            if removals.contains(oldIndex) {
                result.append(DiffLine(kind: .removed, text: old[oldIndex], id: id))
                oldIndex += 1
            } else if insertions.contains(newIndex) {
                result.append(DiffLine(kind: .added, text: new[newIndex], id: id))
                newIndex += 1
            } else {
                result.append(DiffLine(kind: .context, text: old[oldIndex], id: id))
                oldIndex += 1
                newIndex += 1
            }
            id += 1
        }
        return result
    }
}
