import AppKit
import ObjectiveC

/// A Control Strip button that opens continuous monitor sliders. Apple's own Touch Bar volume slider
/// is unavailable because macOS sees no volume control on a DisplayPort audio device.
/// These are private APIs too; if they're missing, nothing appears and nothing else is affected.
@MainActor final class TouchBarControls: NSObject, NSTouchBarDelegate {
    var read: () -> (brightness: Int, volume: Int) = { (0, 0) }
    var setBrightness: (Int) -> Void = { _ in }
    var setVolume: (Int) -> Void = { _ in }

    private static let trayID = NSTouchBarItem.Identifier("com.ethanpan.SamsungDisplayMate.tray")
    private static let brightnessID = NSTouchBarItem.Identifier("com.ethanpan.SamsungDisplayMate.brightness")
    private static let volumeID = NSTouchBarItem.Identifier("com.ethanpan.SamsungDisplayMate.volume")

    private var trayItem: NSCustomTouchBarItem?
    private var bar: NSTouchBar?
    private var brightnessSlider: NSSliderTouchBarItem?
    private var volumeSlider: NSSliderTouchBarItem?

    private typealias SetPresence = @convention(c) (NSString, ObjCBool) -> Void
    private static let setPresence: SetPresence? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW),
              let f = dlsym(h, "DFRElementSetControlStripPresenceForIdentifier") else { return nil }
        return unsafeBitCast(f, to: SetPresence.self)
    }()

    func setVisible(_ visible: Bool) {
        guard let setPresence = Self.setPresence else { return }
        if visible, trayItem == nil {
            let selector = NSSelectorFromString("addSystemTrayItem:")
            guard NSTouchBarItem.responds(to: selector) else { return }
            let item = NSCustomTouchBarItem(identifier: Self.trayID)
            item.view = NSButton(image: NSImage(systemSymbolName: "display", accessibilityDescription: "Monitor controls")!,
                                 target: self, action: #selector(open))
            NSTouchBarItem.perform(selector, with: item)
            trayItem = item
        }
        guard trayItem != nil else { return }
        setPresence(Self.trayID.rawValue as NSString, ObjCBool(visible))
    }

    @objc private func open() {
        let selector = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        guard NSTouchBar.responds(to: selector) else { return }
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.brightnessID, Self.volumeID]
        self.bar = bar
        NSTouchBar.perform(selector, with: bar, with: Self.trayID.rawValue as NSString)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSSliderTouchBarItem(identifier: id)
        let current = read()
        item.target = self
        item.action = #selector(sliderMoved(_:))
        item.minimumSliderWidth = 170
        if id == Self.brightnessID {
            item.label = "☀︎"
            item.slider.minValue = 0
            item.slider.maxValue = 50
            item.slider.integerValue = current.brightness
            brightnessSlider = item
        } else {
            item.label = "🔊"
            item.slider.minValue = 0
            item.slider.maxValue = 100
            item.slider.integerValue = current.volume
            volumeSlider = item
        }
        return item
    }

    @objc private func sliderMoved(_ sender: NSSliderTouchBarItem) {
        if sender === brightnessSlider { setBrightness(sender.slider.integerValue) }
        else if sender === volumeSlider { setVolume(sender.slider.integerValue) }
    }
}
