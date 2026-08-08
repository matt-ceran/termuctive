import Foundation

enum LearningPDFRequest {
    static var bundledSkillURL: URL? {
        bundledSkillURL(in: Bundle.main.resourceURL)
    }

    static func bundledSkillURL(in resourceDirectory: URL?) -> URL? {
        guard let resourceDirectory else {
            return nil
        }
        let skillURL =
            resourceDirectory
            .appendingPathComponent(skillDirectoryName, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: skillURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue
        else {
            return nil
        }
        return skillURL.standardizedFileURL
    }

    static func prompt(skillURL: URL) -> String {
        [
            "Create a learning PDF about the recent meaningful work in this active Codex conversation.",
            "Read and follow the complete Termuctive skill at <\(skillURL.standardizedFileURL.path)>.",
            "Use its Compact Textbook template and bundled renderer.",
            "Explain the concept in simple terms, document exact implementation evidence, include one useful visual, and keep completed, proposed, uncertain, and untouched work distinct.",
            "Do not install or relaunch Termuctive.",
            "Verify every rendered page.",
            "When finished, print exactly one canonical absolute path to the valid PDF on its own final line so Termuctive can remember it for /movepdfright.",
        ].joined(separator: " ")
    }

    private static let skillDirectoryName = "termuctive-learning-pdf"
}
