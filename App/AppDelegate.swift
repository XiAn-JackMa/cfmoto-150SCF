import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 侧载包，手机上没有调试器可挂：把上一次的未捕获异常记在 UserDefaults 里，下次启动时
        // `CfMotoLogStore` 会把它写成日志第三行的 `上次闪退: …`。没有这一句，闪退就是无声的。
        CrashCatcher.install()
        // 静默读一次系统 Wi-Fi 名称（不弹权限框）：日志首行要能区分「系统读到的」和「预设里填的」。
        SystemWiFiName.prefetch()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Receiver", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: ReceiverViewController())
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.tintColor = .systemBlue
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
    }
}
