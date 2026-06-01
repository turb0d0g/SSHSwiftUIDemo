//
//  DeinitHook.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/30/25.
//

//
//  DeinitHook.swift
//  SSHSwiftUIDemo
//
//  Cycle-safe deinit callback helper.
//  Prevents accidental self-retain cycles by optionally capturing a weak object.
//

import Foundation

public final class DeinitHook {
    private let onDeinit: () -> Void

    /// Basic hook. Use ONLY when your closure does not capture `self` (directly or via `obj = self`).
    public init(_ onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    /// Cycle-safe hook: captures the object WEAKLY and only calls if it still exists.
    /// This prevents: self → hook → closure → self retain cycles.
    public convenience init(weak object: AnyObject, _ onDeinit: @escaping (AnyObject) -> Void) {
        weak var weakObj: AnyObject? = object
        self.init {
            guard let obj = weakObj else { return }
            onDeinit(obj)
        }
    }

    deinit { onDeinit() }
}
