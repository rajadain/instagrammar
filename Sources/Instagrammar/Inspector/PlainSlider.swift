import AppKit
import SwiftUI

/// The standard macOS slider (no tick marks) that resets on double-click.
///
/// Wraps `NSSlider` directly: SwiftUI's `Slider` swallows double-clicks, and with a `step` it
/// draws a tick per step, so the inspector's sliders looked inconsistent.
struct PlainSlider: NSViewRepresentable {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    /// `true` when a drag starts, `false` when it ends (one undo step per drag).
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onReset: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ResettableNSSlider {
        let slider = ResettableNSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                                        target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.setAccessibilityLabel(label)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: ResettableNSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        // Don't fight the user's drag with the (rounded) value coming back from the model.
        if !slider.isTracking, slider.doubleValue != value { slider.doubleValue = value }
        slider.isEnabled = context.environment.isEnabled
        slider.onTrackingChanged = { [coordinator = context.coordinator] in coordinator.parent.onEditingChanged($0) }
        slider.onDoubleClick = { [coordinator = context.coordinator] in coordinator.parent.onReset() }
    }

    final class Coordinator: NSObject {
        var parent: PlainSlider
        init(_ parent: PlainSlider) { self.parent = parent }

        @objc func valueChanged(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
}

final class ResettableNSSlider: NSSlider {
    var onTrackingChanged: (Bool) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    private(set) var isTracking = false

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick()
            return
        }
        isTracking = true
        onTrackingChanged(true)
        super.mouseDown(with: event)  // Runs AppKit's tracking loop until mouse-up.
        isTracking = false
        onTrackingChanged(false)
    }
}
