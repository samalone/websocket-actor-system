//
//  TaskPath.swift
//
//
//  Created by Stuart A. Malone on 11/18/23.
//

import Foundation

struct TaskPath: CustomStringConvertible {
    @TaskLocal static var current: TaskPath = TaskPath()
    
    let path: String
    
    init(path: String = "") {
        self.path = path
    }
    
    static func with<R>(name: String, block: () async throws -> R) async rethrows -> R {
        let p = current.path
        return try await $current.withValue(TaskPath(path: p.isEmpty ? name : p + " > " + name), operation: block)
    }
    
    var description: String {
        "{Task \(path)}"
    }
}
