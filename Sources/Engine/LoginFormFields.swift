/// Which two text fields of a form take a login. The port that sees the form knows only the
/// order of its text fields and which of them hide what is typed; this rule says which is
/// the user name and which the password. It reads no value and no label.
public enum LoginFormFields {
    /// - Parameters:
    ///   - isSecure: for each text field of the form, in the order of the form, whether it
    ///     hides what is typed.
    ///   - cursor: the field that has the cursor.
    /// - Returns: the places of the user name and of the password; nil for a form that has
    ///   no such pair around the cursor.
    public static func pair(isSecure: [Bool], cursor: Int) -> (username: Int, password: Int)? {
        guard isSecure.indices.contains(cursor) else { return nil }
        if isSecure[cursor] {
            // The cursor is in the password: the user name is the nearest open field before it.
            guard let username = isSecure[..<cursor].lastIndex(of: false) else { return nil }
            return (username, cursor)
        }
        // The cursor is in the user name: the password is the first hidden field after it.
        guard let password = isSecure[(cursor + 1)...].firstIndex(of: true) else { return nil }
        return (cursor, password)
    }

    /// The login form of a page or a window in which no field has the cursor: the first
    /// hidden field that has an open field before it, with the nearest such field.
    public static func first(isSecure: [Bool]) -> (username: Int, password: Int)? {
        for password in isSecure.indices where isSecure[password] {
            if let username = isSecure[..<password].lastIndex(of: false) { return (username, password) }
        }
        return nil
    }
}
