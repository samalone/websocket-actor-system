/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Wrappers around Logging package to add metadata automatically.
*/

import Foundation
import Logging

let logger = Logger(label: "com.llamagraphics.WebSocketActors")

public func debug(_ category: String, _ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    logger.debug("[\(category)][\(file):\(line)](\(function)) \(message)")
}

public func log(_ category: String, _ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    logger.info("[\(category)][\(file):\(line)](\(function)) \(message)")
}
