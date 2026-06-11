import Foundation

/// A bundled recipe: the script plus the natural-language prompt that would
/// generate it — loading one restores both, so the prompt field always
/// matches the code in the editor.
public struct Recipe: Identifiable, Sendable {
    public let id: String          // resource file name (without .ts)
    public let title: String
    public let prompt: String
    public let phase: JobPhase
    public let systemImage: String

    public var source: String? { ResourceLocator.recipe(named: id) }
}

public enum RecipeCatalog {
    public static let all: [Recipe] = [
        Recipe(id: "find_yaml_key_value",
               title: "Find YAML key/value",
               prompt: "find repos that include a file at deploy/prod.yml where the key account_id has a value of \"481832923858\"",
               phase: .check,
               systemImage: "doc.text.magnifyingglass"),
        Recipe(id: "find_string_in_path",
               title: "Find string under path",
               prompt: "repos where a file in deploy/ contains the string `ec2-shell-prod-eu-west-1-keypair-1`",
               phase: .check,
               systemImage: "text.magnifyingglass"),
        Recipe(id: "remove_line_with_string",
               title: "Delete lines with string",
               prompt: "delete the line containing `ec2-shell-prod-eu-west-1-keypair-1` from files in deploy/",
               phase: .update,
               systemImage: "pencil.slash"),
        Recipe(id: "merge_approved_prs",
               title: "Merge approved PRs",
               prompt: "squash-merge the approved pull requests this job created, then delete their branches",
               phase: .merge,
               systemImage: "arrow.triangle.merge"),
        Recipe(id: "cancel_job",
               title: "Cancel job",
               prompt: "cancel this job: close its open pull requests without merging and delete its branches",
               phase: .merge,
               systemImage: "xmark.circle"),
    ]

    public static func recipe(id: String) -> Recipe? {
        all.first { $0.id == id }
    }
}
