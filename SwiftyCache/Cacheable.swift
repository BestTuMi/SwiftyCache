//
//  Cacheable.swift
//  SwiftyCache
//
//  Created by lihao on 16/5/21.
//  Copyright © 2016年 Egg Swift. All rights reserved.
//

import Foundation

public protocol Cacheable {
    associatedtype CacheType
    
    func archive() -> NSData?
    static func unarchive(data: NSData) -> CacheType?
}
