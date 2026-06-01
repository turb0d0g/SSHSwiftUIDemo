//
//  MemoryPressureLogger.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/31/25.
//


import UIKit

final class MemoryPressureLogger {
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[MEM][WARN] UIApplication.didReceiveMemoryWarningNotification fired")
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
        print("[DEINIT] MemoryPressureLogger")
    }
}