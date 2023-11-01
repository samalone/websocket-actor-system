/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Simplistic "fake" logging infrastructure, just so we can easily print and verify output from a simulator running app.
*/

import Foundation
import Logging

let logger = Logger(label: "com.llamagraphics.WebSocketActorSystem")

public func debug(_ category: String, _ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    logger.debug("[\(category)][\(file):\(line)](\(function)) \(message)")
}

public func log(_ category: String, _ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    logger.info("[\(category)][\(file):\(line)](\(function)) \(message)")
}
