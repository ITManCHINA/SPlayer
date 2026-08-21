import Capacitor
import UIKit

/// 应用主视图控制器
///
/// 存在的唯一目的是注册 `NCMNativePlugin`。
///
/// Capacitor 8 **不做运行时反射扫类**，而是只读 `capacitor.config.json` 的
/// `packageClassList`（见 `CapacitorBridge.swift:303` 的 `registerPlugins()`），
/// 而该列表由 `cap sync` 从 npm 依赖生成。`NCMNativePlugin` 是手写在 App target 里的
/// 本地类、不是 npm 包，因此永远不会进入该列表 —— 只把 Swift 文件加进工程是不够的，
/// 插件能编译进二进制但运行时不会被注册，JS 侧调用会全部失败。
///
/// 另注：`registerPluginType(_:)` 在 `autoRegisterPlugins == true` 时会直接 return，
/// 所以必须用 `registerPluginInstance(_:)`。
class ViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(NCMNativePlugin())
    }
}
