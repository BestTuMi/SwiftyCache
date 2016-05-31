//
//  MemoryCache.swift
//  SwiftyCache
//
//  Created by lihao on 16/5/21.
//  Copyright © 2016年 Egg Swift. All rights reserved.
//

import Foundation
import CoreFoundation
import UIKit

public class MemoryCache {

    public static let queue: dispatch_queue_t = {
        let queue = dispatch_queue_create(SwiftyCache.prefix + "MemoryCache", DISPATCH_QUEUE_SERIAL)
        return queue
    }()
    
    public private(set) var memoryStack = [String: Any]()
    public private(set) var dateInfo = [String: NSDate]()
    public private(set) var LRUTable = [String]()
    
    public var trimWhenMemoryWarning: Bool = true
    public var trimWhenEnterBackground: Bool = true
    public var removeAllWhenMemoryWarning: Bool = false
    public var removeAllWhenEnterBackground: Bool = false
    public var graveLimit: NSTimeInterval = 0
    public var runloopInterval: NSTimeInterval = 0 {
        willSet {
            if newValue != 0 && runloopInterval != newValue {
                self.loop()
            }
        }
    }
    
    public required init() {
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(MemoryCache.receiveMemoryWarning), name: UIApplicationDidReceiveMemoryWarningNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(MemoryCache.receiveEnterBackground), name: UIApplicationDidEnterBackgroundNotification, object: nil)
    }
    
    // Notification
    @objc internal func receiveMemoryWarning() {
        if self.removeAllWhenMemoryWarning {
            self.removeAll({ (result) in
                
            })
            return
        }
        if self.trimWhenMemoryWarning {
            self.removeExpired({ (result) in
                
            })
        }
    }
    
    @objc internal func receiveEnterBackground() {
        if self.removeAllWhenMemoryWarning {
            self.removeAll({ (result) in
                
            })
            return
        }
        if self.trimWhenMemoryWarning {
            self.removeExpired({ (result) in
                
            })
        }
    }
    
    // Action
    public func object<T>(forKey key: String) -> T? {
        var object: T?
        let semaphore = dispatch_semaphore_create(0)
        self.object(forKey: key) { (obj: T?) in
            object = obj
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return object
    }
    
    public func object<T>(forKey key: String, block: ((T?) -> ())?) {
        dispatch_async(MemoryCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?(nil)
                return
            }
            if let element = weakSelf.memoryStack[key] as? T {
                dispatch_barrier_async(MemoryCache.queue, { [weak self] in
                    self?.dateInfo[key] = NSDate()
                    self?.LRU(key)
                })
                block?(element)
                return
            }
            block?(nil)
        }
    }

    public func avalibleObject<T>(forKey key: String) -> T? {
        var object: T?
        let semaphore = dispatch_semaphore_create(0)
        self.avalibleObject(forKey: key) { (obj: T?) in
            object = obj
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return object
    }
    
    public func avalibleObject<T>(forKey key: String, block: ((T?) -> ())?) {
        dispatch_async(MemoryCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?(nil)
                return
            }
            if let element = weakSelf.memoryStack[key] as? T, let date = weakSelf.dateInfo[key] {
                if date.timeIntervalSinceNow < weakSelf.graveLimit {
                    dispatch_barrier_async(MemoryCache.queue, { [weak self] in
                        self?.dateInfo[key] = NSDate()
                        self?.LRU(key)
                    })
                    block?(element)
                    return
                }
            }
            block?(nil)
        }
    }
    
    public func save<T>(object object: T, forKey key: String) {
        let semaphore = dispatch_semaphore_create(0)
        self.setObject(object: object, forKey: key) { (result) in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
    }
    
    public func setObject<T>(object object: T, forKey key: String, block: (() -> ())?) {
        dispatch_barrier_async(MemoryCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?()
                return
            }
            weakSelf.memoryStack[key] = object
            weakSelf.dateInfo[key] = NSDate()
            weakSelf.LRU(key)
            dispatch_async(MemoryCache.queue, { 
                block?()
            })
        }
    }
    
    public func remove(forKey key: String) {
        let semaphore = dispatch_semaphore_create(0)
        self.remove(forKey: key) { _ in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
    }
    
    public func remove(forKey key: String, block: (() -> ())?) {
        dispatch_barrier_async(MemoryCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?()
                return
            }
            weakSelf.dateInfo[key] = nil
            weakSelf.memoryStack[key] = nil
            weakSelf.LRU(remove: key)
            dispatch_async(MemoryCache.queue, {
                block?()
            })
        }
    }
    
    public func remove(toDate date: NSDate) {
        if date.isEqualToDate(NSDate.distantPast()) {
            self.removeAll()
            return
        }
        let semaphore = dispatch_semaphore_create(0)
        self.remove(toDate: date) { _ in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
    }
    
    public func remove(toDate date: NSDate, block: (() -> ())?) {
        if date.isEqualToDate(NSDate.distantPast()) {
            self.removeAll(block)
            return
        }
        dispatch_barrier_async(MemoryCache.queue, { [weak self] in
            guard let weakSelf = self else {
                block?()
                return
            }
            for key in weakSelf.LRUTable.reverse() {
                if let date = weakSelf.dateInfo[key] {
                    if date.timeIntervalSinceDate(date) <= 0 {
                        weakSelf.remove(forKey: key, block: nil)
                    } else {
                        break
                    }
                } else {
                    continue
                }
            }
            dispatch_async(MemoryCache.queue, {
                block?()
            })
        })
    }
    
    public func removeExpired() {
        guard self.graveLimit > 0.0 else {
            return
        }
        let semaphore = dispatch_semaphore_create(0)
        self.removeExpired() { _ in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
    }
    
    public func removeExpired(block: (() -> ())?) {
        guard self.graveLimit > 0.0 else {
            block?()
            return
        }
        dispatch_barrier_async(MemoryCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?()
                return
            }
            for key in weakSelf.LRUTable.reverse() {
                if let date = weakSelf.dateInfo[key] {
                    if date.timeIntervalSinceNow < -weakSelf.graveLimit {
                        weakSelf.remove(forKey: key, block: nil)
                    } else {
                        break
                    }
                } else {
                    continue
                }
            }
            dispatch_async(MemoryCache.queue, {
                block?()
            })
        }
    }
    
    public func removeAll() {
        let semaphore = dispatch_semaphore_create(0)
        self.removeAll() { _ in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
    }
    
    public func removeAll(block: (() -> ())?) {
        dispatch_barrier_async(MemoryCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?()
                return
            }
            weakSelf.LRUTable.removeAll()
            weakSelf.dateInfo.removeAll()
            weakSelf.memoryStack.removeAll()
            dispatch_async(MemoryCache.queue, {
                block?()
            })
        }
    }
    
    private func loop() {
        guard runloopInterval > 0 else {
            return
        }
        self.removeExpired()
        let minseconds = runloopInterval * Double(NSEC_PER_SEC)
        let dtime = dispatch_time(DISPATCH_TIME_NOW, Int64(minseconds))
        dispatch_after(dtime, MemoryCache.queue , { [weak self] in
            dispatch_barrier_async(MemoryCache.queue, { [weak self] in
                self?.loop()
            })
        })
    }
    
}

// MARK: LRU
extension MemoryCache {
    internal func LRU(key: String) {
        self.LRU(remove: key)
        self.LRUTable.insert(key, atIndex: 0)
    }
    
    internal func LRU(remove key: String) {
        if let index = self.LRUTable.indexOf(key) {
            self.LRUTable.removeAtIndex(index)
        }
    }
}
