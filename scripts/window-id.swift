// Prints the window number of the largest on-screen window of one app.
// Usage: swift scripts/window-id.swift <app name> [process id]
// With a process id only the windows of that process count: a second copy of the app that
// runs beside it, as the one a person works in, is never the one a picture is taken of.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let process = arguments.count == 3 ? Int(arguments[2]) : nil
guard arguments.count == 2 || process != nil else {
    FileHandle.standardError.write(Data("Usage: swift scripts/window-id.swift <app name> [process id]\n".utf8))
    exit(2)
}
let owner = arguments[1]
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
let candidates = windows.compactMap { window -> (id: Int, area: Double)? in
    guard window[kCGWindowOwnerName as String] as? String == owner,
          window[kCGWindowLayer as String] as? Int == 0,
          process == nil || window[kCGWindowOwnerPID as String] as? Int == process,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let width = bounds["Width"], let height = bounds["Height"] else { return nil }
    return (id, width * height)
}
guard let largest = candidates.max(by: { $0.area < $1.area }) else {
    let place = process.map { " in the process \($0)" } ?? ""
    FileHandle.standardError.write(Data("No open window of \(owner)\(place) was found.\n".utf8))
    exit(1)
}
print(largest.id)
