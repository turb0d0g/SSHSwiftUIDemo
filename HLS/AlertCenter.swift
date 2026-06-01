//
//  AlertCenter.swift
//  HLSDemo
//
//  Created by Jesse Herring on 8/5/25.
//


// AlertCenter.swift
// Present UIKit alerts from anywhere (incl. SwiftUI). Thread-safe via @MainActor.

import UIKit

@MainActor
final class AlertCenter {
    static let shared = AlertCenter()
    private init() {}

    // MARK: - Public API

    /// Present a simple alert. Returns the UIAlertController in case you want to customize further.
    @discardableResult
    func present(title: String,
                 message: String? = nil,
                 preferredStyle: UIAlertController.Style = .alert,
                 actions: [UIAlertAction] = [UIAlertAction(title: "OK", style: .default)]) -> UIAlertController? {
        guard let top = topViewController else { return nil }
        let ac = UIAlertController(title: title, message: message, preferredStyle: preferredStyle)
        actions.forEach { ac.addAction($0) }

        // iPad action sheets need an anchor
        if preferredStyle == .actionSheet, let pop = ac.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }

        top.present(ac, animated: true)
        return ac
    }

    /// Convenience confirm dialog with Cancel + Destructive confirm.
    func confirm(title: String,
                 message: String? = nil,
                 confirmTitle: String = "OK",
                 confirmStyle: UIAlertAction.Style = .destructive,
                 cancelTitle: String = "Cancel",
                 onConfirm: @escaping () -> Void) {
        let ok = UIAlertAction(title: confirmTitle, style: confirmStyle) { _ in onConfirm() }
        let cancel = UIAlertAction(title: cancelTitle, style: .cancel)
        _ = present(title: title, message: message, actions: [cancel, ok])
    }

    /// Input prompt with a single text field.
    func prompt(title: String,
                message: String? = nil,
                placeholder: String? = nil,
                defaultText: String? = nil,
                confirmTitle: String = "Save",
                cancelTitle: String = "Cancel",
                keyboardType: UIKeyboardType = .default,
                onConfirm: @escaping (String) -> Void) {
        guard let top = topViewController else { return }
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addTextField {
            $0.placeholder = placeholder
            $0.text = defaultText
            $0.keyboardType = keyboardType
        }
        ac.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
        ac.addAction(UIAlertAction(title: confirmTitle, style: .default, handler: { _ in
            let text = ac.textFields?.first?.text ?? ""
            onConfirm(text)
        }))
        top.present(ac, animated: true)
    }

    // MARK: - Utilities

    /// Attempts to find the top-most view controller in the active foreground scene.
    private var topViewController: UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else { return nil }

        while let presented = top.presentedViewController { top = presented }
        return top
    }
}