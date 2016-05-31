//
//  DiskCache.swift
//  SwiftyCache
//
//  Created by lihao on 16/5/21.
//  Copyright © 2016年 Egg Swift. All rights reserved.
//

import Foundation
import CoreFoundation

public class DiskCache {
    
    public static let queue: dispatch_queue_t = {
        let queue = dispatch_queue_create(SwiftyCache.prefix + "DiskCache", DISPATCH_QUEUE_SERIAL)
        return queue
    }()
    
    public let name: String
    public let URL: NSURL!
    public private(set) var dateInfo = [String: NSDate]()
    public private(set) var sizeInfo = [String: UInt64]()
    public private(set) var LRUTable = [String]()
    
    public var debugMode: Bool = true
    
    public private(set) var byteSize: UInt64 = 0 {
        didSet {
            if byteLimit > 0 && byteSize >= byteLimit {
                self.remove(toByte: byteLimit, block: nil)
            }
        }
    }
    public var byteLimit: UInt64 = 0 {
        didSet {
            if byteLimit > 0 && byteSize >= byteLimit {
                self.remove(toByte: byteLimit, block: nil)
            }
        }
    }
    public var graveLimit: NSTimeInterval = 0 {
        didSet {
            if graveLimit > 0 {
                self.removeExpired()
            }
        }
    }

    public required init(name: String, rootPath path: String) {
        self.name = name
        self.URL = NSURL.fileURLWithPathComponents([path, SwiftyCache.prefix+name])
        dispatch_async(DiskCache.queue) {
            self.setup()
        }
    }
    
    public convenience init(name: String) {
        let directory: String = NSSearchPathForDirectoriesInDomains(.CachesDirectory, .UserDomainMask, true).first!
        self.init(name: name, rootPath: directory)
    }
    
    internal func setup() {
        byteSize = 0
        sizeInfo.removeAll()
        dateInfo.removeAll()
        LRUTable.removeAll()
        
        guard let path = URL.path else {
            return
        }
        var directory = ObjCBool(false)
        let exists = NSFileManager().fileExistsAtPath(path, isDirectory: &directory)
        do {
            if exists && !directory {
                // 如果有同名的文件，删除它
                try NSFileManager().removeItemAtURL(URL)
            }

            if !(exists && directory) {
                // 创建当前缓存文件夹
                try NSFileManager().createDirectoryAtURL(URL, withIntermediateDirectories: true, attributes: nil)
            }
            
            // 缓存文件大小和修改时间
            var totalSize: UInt64 = 0
            let properties = [NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey]
            let files = try NSFileManager().contentsOfDirectoryAtURL(URL, includingPropertiesForKeys: properties, options: .SkipsHiddenFiles)
            for fileURL in files {
                let key = fileKey(forURL: fileURL)
                let infos = try fileURL.resourceValuesForKeys(properties)
                if let date = infos[NSURLContentModificationDateKey] as? NSDate, let size = infos[NSURLTotalFileAllocatedSizeKey]?.integerValue {
                    LRUTable.append(key)
                    dateInfo[key] = date
                    sizeInfo[key] = UInt64(size)
                    totalSize += UInt64(size)
                }
            }
            
            // 缓存LRU表
            let sortDates = dateInfo.sort({$0.1.compare($1.1) == .OrderedDescending }).map({ return $0.0})
            LRUTable.appendContentsOf(sortDates)
            
            // 缓存当前大小
            byteSize = totalSize
            
        } catch {
            errorReport(error)
        }
        debugReport("初始化成功")
    }
    
    // Action
    public func object<T>(forKey key: String) -> T? {
        var obj: T?
        let semaphore = dispatch_semaphore_create(0)
        self.object(forKey: key) { (cache, key, object: T?) in
            obj = object
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return obj
    }
    
    public func object<T>(forKey key: String, block: ((cache: DiskCache?, key: String, object: T?) -> ())?) {
        dispatch_async(DiskCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?(cache: self, key: key, object: nil)
                return
            }
            weakSelf.debugReport("开始获取 \(key) 缓存数据")
            let url = weakSelf.fileURL(forKey: key)
            guard let path = url.path where NSFileManager().fileExistsAtPath(path),
                let data = NSData.init(contentsOfFile: path) as? T else {
                    do {
                        try NSFileManager().removeItemAtURL(url) // 删除异常数据
                    } catch {
                        weakSelf.errorReport(error)
                    }
                    block?(cache: self, key: key, object: nil)
                    return
            }
            let date = NSDate()
            dispatch_barrier_async(DiskCache.queue, {
                guard let weakSelf = self else {
                    block?(cache: self, key: key, object: nil)
                    return
                }
                weakSelf.LRU(key)
                weakSelf.dateInfo[key] = date
                try! NSFileManager().setAttributes([NSFileModificationDate: date], ofItemAtPath: url.path!)
                weakSelf.debugReport("获取 \(key) 缓存数据, 修改日期成功")
            })
            block?(cache: self, key: key, object: data)
            weakSelf.debugReport("获取 \(key) 缓存数据成功")
        }
    }
    
    public func object<T: Cacheable>(forKey key: String) -> T? {
        var obj: T?
        let semaphore = dispatch_semaphore_create(0)
        self.object(forKey: key) { (cache, key, object: T?) in
            obj = object
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return obj
    }

    public func object<T: Cacheable>(forKey key: String, block: ((cache: DiskCache?, key: String, object: T?) -> ())?) {
        self.object(forKey: key) { (cache, key, object: AnyObject?) in
            if let object = object as? NSData {
                if let obj = T.unarchive(object) as? T {
                    block?(cache: self, key: key, object: obj)
                    return
                }
            }
            block?(cache: self, key: key, object: nil)
        }
    }
    
    public func object<T: Cacheable>(forKey key: String) -> (completion: ((DiskCache?, String, T?) -> ())?) -> () {
        return { completion in
            self.object(forKey: key, block: { (cache, key, object: T?) in
                completion?(self, key, object)
            })
        }
    }

    public func object<T: NSCoding>(forKey key: String) -> T? {
        var obj: T?
        let semaphore = dispatch_semaphore_create(0)
        self.object(forKey: key) { (cache, key, object: T?) in
            obj = object
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return obj
    }
    
    public func object<T: NSCoding>(forKey key: String, block: ((cache: DiskCache?, key: String, object: T?) -> ())?) {
        self.object(forKey: key) { (cache, key, object: AnyObject?) in
            if let object = object as? NSData {
                if let obj = NSKeyedUnarchiver.unarchiveObjectWithData(object) as? T {
                    block?(cache: self, key: key, object: obj)
                    return
                }
            }
            block?(cache: self, key: key, object: nil)
        }
    }
    
    public func object<T: NSCoding>(forKey key: String) -> (completion: ((DiskCache?, String, T?) -> ())?) -> () {
        return { completion in
            self.object(forKey: key, block: { (cache, key, object: T?) in
                completion?(self, key, object)
            })
        }
    }
    
    public func save<T: Cacheable>(object object: T, forKey key: String) -> DiskCache? {
        let semaphore = dispatch_semaphore_create(0)
        self.save(object: object, forKey: key) { (result) in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return self
    }
    
    public func save<T: Cacheable>(object object: T, forKey key: String, block: (DiskCache? -> ())?) {
        dispatch_async(DiskCache.queue) { [weak self] in
            guard let weakSelf = self,
                let url = Optional.Some(weakSelf.fileURL(forKey: key)),
                let path = url.path else {
                    block?(self)
                    return
            }
            weakSelf.debugReport("开始保存 \(key) 缓存数据")
            
            let date = NSDate()
            let written = NSFileManager().createFileAtPath(path, contents: object.archive(), attributes: nil)
            if written {
                dispatch_barrier_async(DiskCache.queue, {
                    weakSelf.LRU(key)
                    do {
                        // Date
                        weakSelf.dateInfo[key] = date
                        try NSFileManager().setAttributes([NSFileModificationDate: date], ofItemAtPath: url.path!)
                        // Size
                        let infos = try url.resourceValuesForKeys([NSURLTotalFileAllocatedSizeKey])
                        if let size = infos[NSURLTotalFileAllocatedSizeKey]?.intValue {
                            let sizeInfo = weakSelf.sizeInfo[key]
                            weakSelf.byteSize -= sizeInfo ?? 0
                            weakSelf.sizeInfo[key] = UInt64(size)
                            weakSelf.byteSize += sizeInfo ?? 0
                        }
                        weakSelf.debugReport("保存 \(key) 缓存数据, 修改日期成功")
                    } catch {
                        weakSelf.errorReport(error)
                    }
                })
            }
            block?(weakSelf)
            weakSelf.debugReport("保存 \(key) 缓存数据成功")
        }
    }
    
    public func save<T: NSCoding>(object object: T, forKey key: String) -> DiskCache? {
        let semaphore = dispatch_semaphore_create(0)
        self.save(object: object, forKey: key) { (result) in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return self
    }
    
    public func save<T: NSCoding>(object object: T, forKey key: String, block: (DiskCache? -> ())?) {
        dispatch_async(DiskCache.queue) { [weak self] in
            guard let weakSelf = self,
                  let url = Optional.Some(weakSelf.fileURL(forKey: key)),
                  let path = url.path else {
                block?(self)
                return
            }
            weakSelf.debugReport("开始保存 \(key) 缓存数据")

            let date = NSDate()
            let written = NSKeyedArchiver.archiveRootObject(object, toFile: path)
            if written {
                dispatch_barrier_async(DiskCache.queue, { 
                    weakSelf.LRU(key)
                    do {
                        // Date
                        weakSelf.dateInfo[key] = date
                        try NSFileManager().setAttributes([NSFileModificationDate: date], ofItemAtPath: url.path!)
                        // Size
                        let infos = try url.resourceValuesForKeys([NSURLTotalFileAllocatedSizeKey])
                        if let size = infos[NSURLTotalFileAllocatedSizeKey]?.intValue {
                            let sizeInfo = weakSelf.sizeInfo[key]
                            weakSelf.byteSize -= sizeInfo ?? 0
                            weakSelf.sizeInfo[key] = UInt64(size)
                            weakSelf.byteSize += sizeInfo ?? 0
                        }
                        weakSelf.debugReport("保存 \(key) 缓存数据, 修改日期成功")
                    } catch {
                        weakSelf.errorReport(error)
                    }
                })
            }
            block?(weakSelf)
            weakSelf.debugReport("保存 \(key) 缓存数据成功")
        }
    }
    
    public func remove(forKey key: String) -> DiskCache? {
        let semaphore = dispatch_semaphore_create(0)
        self.remove(forKey: key) { (result) in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return self
    }
    
    public func remove(forKey key: String, block: (DiskCache? -> ())?) {
        dispatch_async(DiskCache.queue) { [weak self] in
            guard let weakSelf = self,
                  let path = weakSelf.fileURL(forKey: key).path where NSFileManager().fileExistsAtPath(path) else {
                    block?(self)
                    return
            }
            weakSelf.debugReport("开始删除 \(key) 缓存数据")
            
            do {
                try NSFileManager().removeItemAtPath(path)
                weakSelf.LRU(remove: key)
                weakSelf.dateInfo[key] = nil
                weakSelf.sizeInfo[key] = nil
                weakSelf.debugReport("删除 \(key) 缓存数据成功")
            } catch {
                weakSelf.errorReport(error)
            }
            block?(weakSelf)
        }
    }
    
    public func removeAll() -> DiskCache? {
        let semaphore = dispatch_semaphore_create(0)
        self.removeAll { (result) in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return self
    }
    
    public func removeAll(block: (DiskCache? -> ())?) {
        dispatch_async(DiskCache.queue) { [weak self] in
            guard let weakSelf = self,
                let path = weakSelf.URL.path where NSFileManager().fileExistsAtPath(path) else {
                    block?(self)
                    return
            }
            weakSelf.debugReport("开始清空缓存数据")
            
            do {
                try NSFileManager().removeItemAtPath(path)
                weakSelf.setup()
                weakSelf.debugReport("清空缓存数据成功")
            } catch {
                weakSelf.errorReport(error)
            }
            block?(weakSelf)
        }
    }
    
    public func remove(toDate date: NSDate) -> DiskCache? {
        let semaphore = dispatch_semaphore_create(0)
        self.remove(toDate: date) { _ in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return self
    }
    
    public func remove(toDate date: NSDate, block: ((DiskCache?) -> ())?) {
        dispatch_async(DiskCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?(self)
                return
            }
            weakSelf.debugReport("开始删除缓存数据到 \(date)")
            
            for key in weakSelf.LRUTable.reverse() {
                if let element = weakSelf.dateInfo[key] where element.timeIntervalSinceDate(date) <= 0 {
                    weakSelf.remove(forKey: key)
                } else {
                    break
                }
            }
            weakSelf.debugReport("删除缓存数据到 \(date) 成功")
            block?(weakSelf)
        }
    }
    
    public func remove(toByte byte: UInt64) -> DiskCache? {
        let semaphore = dispatch_semaphore_create(0)
        self.remove(toByte: byte) { _ in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return self
    }
    
    public func remove(toByte byte: UInt64, block: ((DiskCache?) -> ())?) {
        dispatch_async(DiskCache.queue) { [weak self] in
            guard let weakSelf = self else {
                block?(self)
                return
            }
            weakSelf.debugReport("开始删除缓存数据到 \(byte)")
            
            if byte > weakSelf.byteSize {
                block?(weakSelf)
                return
            }
            for key in weakSelf.LRUTable.reverse() {
                weakSelf.remove(forKey: key)
                if weakSelf.byteSize <= byte {
                    break
                }
            }
            weakSelf.debugReport("删除缓存数据到 \(byte) 成功")
            block?(weakSelf)
        }
    }
    
    public func removeExpired() -> DiskCache? {
        let semaphore = dispatch_semaphore_create(0)
        self.removeExpired { _ in
            dispatch_semaphore_signal(semaphore)
        }
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
        return self
    }
    
    public func removeExpired(block: ((DiskCache?) -> ())?) {
        dispatch_async(DiskCache.queue) { [weak self] in
            guard let weakSelf = self where weakSelf.graveLimit > 0.0 else {
                block?(self)
                return
            }
            weakSelf.debugReport("开始删除过期缓存数据")
            
            for key in weakSelf.LRUTable.reverse() {
                if let element = weakSelf.dateInfo[key] where element.timeIntervalSinceNow < -weakSelf.graveLimit {
                    weakSelf.remove(forKey: key)
                } else {
                    break
                }
            }
            weakSelf.debugReport("删除过期缓存数据成功")
            block?(weakSelf)
        }
    }

    // MARK: Helper
    public func fileURL(forKey key: String) -> NSURL {
        let fileURL = URL.URLByAppendingPathComponent(encode(URLString: key))
        return fileURL
    }
    
    public func fileKey(forURL url: NSURL) -> String {
        if let fileName = url.lastPathComponent {
            return self.dencode(URLString: fileName)
        }
        return ""
    }
    
    public func encode(URLString string: String) -> String {
        // Encode all the reserved characters, per RFC 3986 http://www.ietf.org/rfc/rfc3986.txt
        var output = ""
        if NSProcessInfo().isOperatingSystemAtLeastVersion(NSOperatingSystemVersion(majorVersion: 9, minorVersion: 0, patchVersion: 0)) {
            output = string.stringByAddingPercentEncodingWithAllowedCharacters(NSCharacterSet.init(charactersInString: "!*'();:@&=+$,/?%#[]").invertedSet) ?? ""
        } else {
            // #pragma clang diagnostic push
            // #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            output = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, string as CFString, nil, "!*'();:@&=+$,/?%#[]" as CFString, 0x08000100) as String
            // #pragma clang diagnostic pop
        }
        return output
    }
    
    public func dencode(URLString string: String) -> String {
        var output = ""
        if NSProcessInfo().isOperatingSystemAtLeastVersion(NSOperatingSystemVersion(majorVersion: 9, minorVersion: 0, patchVersion: 0)) {
            output = string.stringByRemovingPercentEncoding ?? ""
        } else {
            // #pragma clang diagnostic push
            // #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            output = CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault, string as CFString, "", 0x08000100) as String
            // #pragma clang diagnostic pop
        }
        return output
    }
    
}


/*
 LRU(Least Recently Used) https://en.wikipedia.org/wiki/LRU
 
 Discards the least recently used items first. This algorithm requires keeping track of what was used when, which is expensive if one wants to make sure the algorithm always discards the least recently used item. General implementations of this technique require keeping "age bits" for cache-lines and track the "Least Recently Used" cache-line based on age-bits. In such an implementation, every time a cache-line is used, the age of all other cache-lines changes. LRU is actually [a family of caching algorithms](https://en.wikipedia.org/wiki/Page_replacement_algorithm#Variants_on_LRU) with members including 2Q by Theodore Johnson and Dennis Shasha,[3] and LRU/K by Pat O'Neil, Betty O'Neil and Gerhard Weikum.
 */
//  MARK: LRU Method
extension DiskCache /* LRU */ {
    
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

// MARK: Description
extension DiskCache /* Description */ {
    
    public var description: String {
        let name = self.name,
        url = self.URL,
        byteSize = self.byteSize,
        byteLimit = self.byteLimit,
        LRUInfo = self.LRUTable,
        dateInfo = self.dateInfo,
        sizeInfo = self.sizeInfo,
        description = "DiskCache: \n\t Name: \(name), \n\t Path: \(url.path!), \n\t URL: \(url), \n\t ByteSize: \(byteSize), \n\t ByteLimit: \(byteLimit), \n\t DateInfo: \(dateInfo.description) \n\t SizeInfo: \(sizeInfo.description) \n\t LRUInfo: \(LRUInfo.description) \n"
        return description
    }
    
    func errorReport(err: Any?) {
        if debugMode == true {
            print("SwiftyCache catch ERROR: \(err)")
        }
    }

    func debugReport(str: String) {
        if debugMode == true {
            print("SwiftyCache report: \(str) \n \(self.description)")
        }
    }
    
}
