//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Future
import Sockets

// TODO: Implement scheduling tasks in the future (a.k.a ScheduledExecutoreService
public class EventLoop {
    private let selector: Sockets.Selector
    private let thread: Thread
    private var tasks: [() -> ()]

    init() throws {
        self.selector = try Sockets.Selector()
        self.tasks = Array()
        thread = Thread.current
    }
    
    func register(channel: Channel) throws {
        assert(inEventLoop)
        try selector.register(selectable: channel.socket, interested: channel.interestedEvent, attachment: channel)
    }
    
    func deregister(channel: Channel) throws {
        assert(inEventLoop)
        try selector.deregister(selectable: channel.socket)
    }
    
    func reregister(channel: Channel) throws {
        assert(inEventLoop)
        try selector.reregister(selectable: channel.socket, interested: channel.interestedEvent)
    }
    
    public var inEventLoop: Bool {
        return Thread.current.isEqual(thread)
    }
    
    public func execute(task: @escaping () -> ()) {
        assert(inEventLoop)
        tasks.append(task)
    }

    public func schedule<T>(task: @escaping () -> (T)) -> Future<T> {
        let promise = Promise<T>()
        tasks.append({() -> () in
            promise.succeed(result: task())
        })
            
        return promise.futureResult
    }

    func run() throws {
        assert(inEventLoop)
        while true {
            // Block until there are events to handle
            if let events = try selector.awaitReady() {
                for ev in events {
                    
                    guard let channel = ev.attachment as? Channel else {
                        fatalError("ev.attachment has type \(type(of: ev.attachment)), expected Channel")
                    }
                        
                    guard handleEvents(channel) else {
                        continue
                    }
                    
                    if ev.isWritable {
                        channel.flushFromEventLoop()
                        
                        guard handleEvents(channel) else {
                            continue
                        }
                    }
                    
                    if ev.isReadable {
                        channel.readFromEventLoop()
                        
                        guard handleEvents(channel) else {
                            continue
                        }
                    }
                    
                    // Ensure we never reach here if the channel is not open anymore.
                    assert(channel.open)
                }
                
                // Execute all the tasks that were summited
                while let task = tasks.first {
                    task()

                    let _ = tasks.removeFirst()
                }
            }
        }
    }

    private func handleEvents(_ channel: Channel) -> Bool {
        if channel.open {
            return true
        }
        do {
            try deregister(channel: channel)
        } catch {
            // ignore for now... We should most likely at least log this.
        }

        return false
    }
    
    public func close() throws {
        try self.selector.close()
    }
    
    public func newPromise<T>(type: T.Type) -> Promise<T> {
        return Promise<T>()
    }
    
    public func newFailedFuture<T>(type: T.Type, error: Error) -> Future<T> {
        let promise = newPromise(type: type)
        promise.fail(error: error)
        return promise.futureResult
    }
    
    public func newSucceedFuture<T>(result: T) -> Future<T> {
        let promise = newPromise(type: type(of: result))
        promise.succeed(result: result)
        return promise.futureResult
    }
}
