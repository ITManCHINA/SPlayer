import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "top.imsyy.splayer.ios",
  appName: "SPlayer",
  webDir: "out/renderer",
  ios: {
    // 允许 Safari 网页检查器连接 WKWebView
    //
    // 默认行为只在 Debug 配置下开启：ios/debug.xcconfig 的 CAPACITOR_DEBUG=true
    // 仅挂在两个 Debug configuration 上，Release 产物里该值为空，
    // 于是 CapacitorBridge 把 webView.isInspectable 设为 false，Safari 看不到页面。
    // 显式配置优先于 CAPACITOR_DEBUG（见 CAPInstanceDescriptor.swift:137）。
    //
    // 移植阶段需要它来排查 JS 侧问题，对外分发前应移除
    webContentsDebuggingEnabled: true,
  },
};

export default config;
