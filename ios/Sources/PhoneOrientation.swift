import SwiftUI
import UIKit

/// Knob on the iPhone stays upright, except the player with a song loaded, which turns on its
/// side into the record deck (PhoneVinylDeck). The app says which it allows here at any moment.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    static var allowed: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowed
    }
}

@MainActor
enum PhoneOrientation {
    static func allow(landscape: Bool) {
        let mask: UIInterfaceOrientationMask = landscape ? .allButUpsideDown : .portrait
        guard PhoneAppDelegate.allowed != mask else { return }
        PhoneAppDelegate.allowed = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !landscape { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        }
    }
}
