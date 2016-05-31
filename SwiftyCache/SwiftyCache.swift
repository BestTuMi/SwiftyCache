//
//  SwiftyCache.swift
//  SwiftyCache
//
//  Created by lihao on 16/5/21.
//  Copyright © 2016年 Egg Swift. All rights reserved.
//

import Foundation

public class SwiftyCache {
    public static let prefix: String = {
        let appName = NSBundle.mainBundle().infoDictionary?[String(kCFBundleExecutableKey)] as? String ?? "Application"
        let prefix = "com." + appName + "."
        return prefix
    }()
    
}
