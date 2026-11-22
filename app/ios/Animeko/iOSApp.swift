import Foundation
import SwiftUI
import UIKit
import application


class AppDelegate: NSObject, UIApplicationDelegate {
	/// 非 nil 时, App 只允许这些屏幕方向. 全屏播放时会锁定为横屏.
	///
	/// 只靠 `requestGeometryUpdate` 旋转一次是不够的: 竖屏仍然是受支持的方向,
	/// 从后台切回来时系统会按设备实际方向 (或竖排方向锁定) 把界面转回竖屏.
	static var orientationLock: UIInterfaceOrientationMask? = nil

	func application(
		_ application: UIApplication,
		supportedInterfaceOrientationsFor window: UIWindow?
	) -> UIInterfaceOrientationMask {
		if let lock = AppDelegate.orientationLock {
			return lock
		}
		// 与 Info.plist 的 UISupportedInterfaceOrientations 保持一致
		return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
	}
}

@main
struct iOSApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@State private var showsNativeInterface: Bool
	@State private var qrLoginRequest: String?

	let app: AniIosApplication
	private let catalog: IosNativeCatalog?

	init() {
		SwiftBridgeKt.SwiftBridge = SwiftBridgeImpl()
		let instance = AniIosKt.startIosApp()
		app = instance
		#if DEBUG
		let useNativeInterface = ProcessInfo.processInfo.arguments.contains("-AnimekoNativeUI")
		catalog = useNativeInterface ? instance.nativeCatalog() : nil
		_showsNativeInterface = State(initialValue: useNativeInterface)
		#else
		catalog = nil
		_showsNativeInterface = State(initialValue: false)
		#endif
	}

	var body: some Scene {
		WindowGroup {
			Group {
				if showsNativeInterface, let catalog {
					NativeAnimekoView(catalog: catalog, qrLoginRequest: $qrLoginRequest) {
						showsNativeInterface = false
					} openUpdateSettings: {
						showsNativeInterface = false
						app.openUpdateSettings()
					}
				} else {
					ContentView(app: app)
				}
			}
			.onOpenURL { url in
				if showsNativeInterface, let catalog {
					if let requestId = catalog.qrLoginRequestId(content: url.absoluteString) {
						qrLoginRequest = requestId
					}
				} else {
					_ = app.openUrl(url: url.absoluteString)
				}
			}
		}
	}
}
