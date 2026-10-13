import Foundation

/// POSIX shell quoting for commands that ssh hands to the remote login shell.
enum ShellQuoting {
    private static let safeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-"
    )

    static func quote(_ argument: String) -> String {
        if !argument.isEmpty,
            argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) })
        {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}
