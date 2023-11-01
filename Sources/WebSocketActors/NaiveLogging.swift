/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Simplistic "fake" logging infrastructure, just so we can easily print and verify output from a simulator running app.
*/

import Foundation

public func debug(_ category: String, _ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    // ignore
}

public func log(_ category: String, _ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    print("[\(category)][\(file):\(line)](\(function)) \(message)")
}
