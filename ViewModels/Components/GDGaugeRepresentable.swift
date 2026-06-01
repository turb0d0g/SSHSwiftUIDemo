//
//  GDGaugeRepresentable.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 11/1/25.
//


//
//  GDGaugeRepresentable.swift
//  SSHSwiftUIDemo
//
//  Wraps GDGaugeView (UIKit) for SwiftUI.
//  iOS 16+
//
//  NOTE: This file compiles even if GDGauge hasn’t been added yet.
//  Once the SPM dependency is added, the `#if canImport(GDGauge)`
//  branch is used automatically.
//

import SwiftUI

#if canImport(GDGauge)
import GDGauge
#endif

public struct GDGaugeRepresentable: View {
    public var value: Double
    public var minValue: Double
    public var maxValue: Double
    public var unitTitle: String
    public var startDegree: CGFloat
    public var endDegree: CGFloat
    public var containerWidth: CGFloat
    public var containerColor: Color
    public var handleColor: Color
    public var indicatorsColor: Color
    public var indicatorsValuesColor: Color
    public var fontSize: CGFloat

    public init(
        value: Double,
        in range: ClosedRange<Double>,
        unitTitle: String,
        startDegree: CGFloat = 135,
        endDegree: CGFloat = 45,
        containerWidth: CGFloat = 16,
        containerColor: Color = .secondary.opacity(0.15),
        handleColor: Color = .primary,
        indicatorsColor: Color = .secondary,
        indicatorsValuesColor: Color = .secondary,
        fontSize: CGFloat = 11
    ) {
        self.value = value.clamped(to: range)
        self.minValue = range.lowerBound
        self.maxValue = range.upperBound
        self.unitTitle = unitTitle
        self.startDegree = startDegree
        self.endDegree = endDegree
        self.containerWidth = containerWidth
        self.containerColor = containerColor
        self.handleColor = handleColor
        self.indicatorsColor = indicatorsColor
        self.indicatorsValuesColor = indicatorsValuesColor
        self.fontSize = fontSize
    }

    public var body: some View {
#if canImport(GDGauge)
        _GDGaugeUIView(
            value: CGFloat(value),
            minValue: CGFloat(minValue),
            maxValue: CGFloat(maxValue),
            unitTitle: unitTitle,
            startDegree: startDegree,
            endDegree: endDegree,
            containerWidth: containerWidth,
            containerColor: UIColor(containerColor),
            handleColor: UIColor(handleColor),
            indicatorsColor: UIColor(indicatorsColor),
            indicatorsValuesColor: UIColor(indicatorsValuesColor),
            fontSize: fontSize
        )
#else
        // Fallback: native SwiftUI Gauge (ensures app still compiles)
        VStack(spacing: 8) {
            Gauge(value: value, in: minValue...maxValue) {
                Text(unitTitle)
            } currentValueLabel: {
                Text(Int(value).description)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(handleColor)
        }
#endif
    }
}

#if canImport(GDGauge)
private struct _GDGaugeUIView: UIViewRepresentable {
    var value: CGFloat
    var minValue: CGFloat
    var maxValue: CGFloat
    var unitTitle: String
    var startDegree: CGFloat
    var endDegree: CGFloat
    var containerWidth: CGFloat
    var containerColor: UIColor
    var handleColor: UIColor
    var indicatorsColor: UIColor
    var indicatorsValuesColor: UIColor
    var fontSize: CGFloat

    func makeUIView(context: Context) -> GDGaugeView {
        let view = GDGaugeView(frame: .zero)
        // Build the gauge once. The library uses a builder-style API.
        view
            .setupGuage(
                startDegree: startDegree,
                endDegree: endDegree,
                sectionGap: 2,
                minValue: minValue,
                maxValue: maxValue
            )
            .setupContainer(
                width: containerWidth,
                color: containerColor,
                handleColor: handleColor,
                options: [], // Using no special options keeps defaults (labels, ticks)
                indicatorsColor: indicatorsColor,
                indicatorsValuesColor: indicatorsValuesColor,
                indicatorsFont: .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            )
            .setupUnitTitle(
                title: unitTitle,
                font: .systemFont(ofSize: fontSize, weight: .semibold)
            )
            .buildGauge()

        // Initial value
        view.updateValueTo(value)
        return view
    }

    func updateUIView(_ uiView: GDGaugeView, context: Context) {
        // Smoothly animate to the new value.
        uiView.updateValueTo(value)

        // Optional: simple heat mapping when unit is °C or a percentage range
        let normalized = (value - minValue) / max(1, (maxValue - minValue))
        let heat = UIColor(
            hue: CGFloat(0.33 - 0.33 * min(max(normalized, 0), 1)), // green->red
            saturation: 0.85,
            brightness: 0.95,
            alpha: 1
        )
        uiView.updateColors(containerColor: containerColor, indicatorsColor: heat)
    }
}
#endif

// MARK: - Utilities

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension UIColor {
    convenience init(_ color: Color) {
        self.init(dynamicProvider: { trait in
            UIColor(color)
        })
    }
}