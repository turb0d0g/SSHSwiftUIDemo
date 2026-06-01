//
//  SwiftUITerminalView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 2025-10-07.
//

//
//  SwiftUITerminalView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 2025-10-07.
//  Updated: 2026-01-12
//
import Foundation
import SwiftUI
import SwiftTerm
import UIKit

struct SwiftUITerminalView: UIViewRepresentable {
    @ObservedObject var viewModel: TerminalViewModel

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)

        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.isOpaque = true
        tv.backgroundColor = .black
        tv.contentMode = .redraw
        tv.clearsContextBeforeDrawing = true
        tv.layer.magnificationFilter = .nearest
        tv.layer.contentsScale = UIScreen.main.scale

        // IMPORTANT: terminal delegate, not UIScrollView.delegate
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv

        // Hand terminal ref to the VM so it can feed bytes.
        viewModel.attachTerminal(tv)

        print("[SwiftUITerminalView] makeUIView tv=\(Unmanaged.passUnretained(tv).toOpaque()) coord=\(context.coordinator.coordID)")

        DispatchQueue.main.async {
            tv.setNeedsLayout()
            tv.layoutIfNeeded()
            tv.setNeedsDisplay()
        }

        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // This gets called a lot. Keep it cheap.
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
        uiView.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    /// ✅ Critical teardown hook.
    /// Break delegate chains and cancel pending work so UIKit can release everything promptly.
    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        print("[SwiftUITerminalView] dismantleUIView tv=\(Unmanaged.passUnretained(uiView).toOpaque()) coord=\(coordinator.coordID)")

        coordinator.redrawWorkItem?.cancel()
        coordinator.redrawWorkItem = nil

        // Break TerminalView -> Coordinator strong edge (if TerminalView retains delegate strongly).
        uiView.terminalDelegate = nil

        // Clear coordinator backref (just hygiene).
        coordinator.terminalView = nil

        // Clear VM's weak terminal pointer (hygiene; not strictly required).
        coordinator.viewModel?.terminal = nil
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var viewModel: TerminalViewModel?
        weak var terminalView: TerminalView?

        fileprivate var redrawWorkItem: DispatchWorkItem?

        let coordID = UUID().uuidString

        init(viewModel: TerminalViewModel) {
            self.viewModel = viewModel
            super.init()
            Swift.print("[SwiftUITerminalView.Coordinator] init coord=\(coordID)")
        }

        deinit {
            Swift.print("[SwiftUITerminalView.Coordinator] deinit coord=\(coordID) → cancel redrawWorkItem")
            redrawWorkItem?.cancel()
            redrawWorkItem = nil
        }

        // terminal → remote (user keystrokes)
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let vm = viewModel else {
                Swift.print("[SwiftUITerminalView.Coordinator] send dropped (vm nil) coord=\(coordID)")
                return
            }
            Task { await vm.send(data) }
        }

        func paste(source: TerminalView, data: Data) {
            guard let vm = viewModel else { return }
            Task { await vm.send(ArraySlice(data)) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            redrawWorkItem?.cancel()

            // Debounced redraw to keep SwiftTerm from thrashing on rotations/resizes.
            let work = DispatchWorkItem { [weak source] in
                source?.setNeedsLayout()
                source?.layoutIfNeeded()
                source?.setNeedsDisplay()
            }
            redrawWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)

            guard let vm = viewModel else { return }
            Task { await vm.windowChange(cols: newCols, rows: newRows) }
        }

        func scrolled(source: TerminalView, position: Double) {
            source.setNeedsDisplay()
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            source.setNeedsDisplay()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }

        // MARK: - Unused TerminalViewDelegate hooks (no-ops)

        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func bell(source: TerminalView) {}
        func selectionChanged(source: TerminalView) {}
        func selectionHandleMoved(source: TerminalView) {}
        func mouseModeChanged(source: TerminalView) {}
        func bracketedPasteModeChanged(source: TerminalView) {}
        func requestStartNewSession(source: TerminalView) {}
        func openTerminalSettings(source: TerminalView) {}
        func terminalClosed(source: TerminalView) {}
        func print(source: TerminalView, text: String) {}
        func suspend(source: TerminalView) {}
        func resume(source: TerminalView) {}
    }
}
