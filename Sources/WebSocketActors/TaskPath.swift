//
//  TaskPath.swift
//
//
//  Created by Stuart A. Malone on 11/18/23.
//

import Foundation

public struct TaskPath: CustomStringConvertible {
    @TaskLocal public static var current: TaskPath = .init()

    let path: String

    init(path: String = "") {
        self.path = path
    }

    public static func with<R>(name: String, block: () async throws -> R) async rethrows -> R {
        let p = current.path
        return try await $current.withValue(TaskPath(path: p.isEmpty ? name : p + " > " + name), operation: block)
    }

    public var description: String {
        "{Task \(path)}"
    }
}
