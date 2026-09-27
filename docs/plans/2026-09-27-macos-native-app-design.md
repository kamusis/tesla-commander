# Tesla Commander — 纯 Swift 原生 macOS App 架构设计方案

**版本**: v2.0 (纯原生 WebSocket 流式架构)
**日期**: 2026-09-27
**设计目标**: 构建零外部运行时依赖（零 Python、零外部 JS、零第三方包）的独立 macOS 桌面应用。通过 Swift 原生 `URLSessionWebSocketTask` 直连车机 Fleet Telemetry 实现毫秒级事件流驱动展示，配合纯原生 GUI 控制卡片直发指令。

---

## 1. 核心设计准则

1. **绝对原生，零外部运行时 (Zero External Runtimes)**：
   - 不依赖 Python 环境，不依赖 Node.js/外部 JS 脚本，不引入 Electron、Tauri 等重型容器。
   - 纯 Swift（AppKit + WebKit + Foundation），编译后单二进制独立运行，包体积 < 5MB。
2. **纯流式驱动，彻底消除轮询 (True Streaming, Zero Polling)**：
   - 不设任何 30s / 60s 定时器轮询。
   - 依赖 Apple 原生 `URLSessionWebSocketTask` 与 `wss://streaming.tessie.com/{vin}` 建立全双工长连接。
   - 车端遥测（电量、功率、胎压、车温、GPS、车锁状态）产生变动时，毫秒级流式推送到 App，界面平滑跳动更新。
3. **安全隔离 (Credential Isolation)**：
   - `TESSIE_API_KEY` 与 `MY_TESLA_VIN` 由 Native Swift 层统一管理（自动继承系统环境变量或本地安全配置），前端 Webview 源码绝不触碰 Token。
4. **纯 GUI 交互，消除终端残留 (Pure Native GUI)**：
   - 控制中心为 100% 原生 GUI 控件（带温度步进调节器、导航文本输入框、状态切换按钮），彻底消除任何 CLI 命令行。

---

## 2. 系统架构拓扑

```
┌────────────────────────────────────────────────────────┐
│             Tesla Commander (macOS Native App)         │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │             NSWindow (Standard Window)           │  │
│  │                                                  │  │
│  │  ┌────────────────────────────────────────────┐  │  │
│  │  │             WKWebView 视图层               │  │  │
│  │  │  - Header: ● LIVE STREAMING + ↻ 同步按钮   │  │  │
│  │  │  - Tab 01: 车辆全貌与遥测 (6 Scorecards)   │  │  │
│  │  │  - Tab 02: 充电与电能分析 (历史账单明细)   │  │  │
│  │  │  - Tab 03: 硬件架构与底盘矩阵             │  │  │
│  │  │  - Tab 04: 车辆快捷控制中心 (纯原生 GUI)   │  │  │
│  │  └──────────────────▲─────────────────────────┘  │  │
│  └─────────────────────┼────────────────────────────┘  │
│                        │                               │
│        [WebKit Native JavaScript Bridge]               │
│        ▲ postMessage(action)      │ evaluateJavaScript │
│        │ (UI 按钮操作)             ▼ (流式遥测数据帧)   │
│  ┌─────┴────────────────────────────────────────────┐  │
│  │           Swift Native 业务与通信层              │  │
│  │                                                  │  │
│  │  ├── ConfigManager.swift                         │  │
│  │  │   - 环境变量优先: TESSIE_API_KEY / VIN        │  │
│  │  │   - 备选: ~/.config/tesla-commander/config    │  │
│  │  │                                               │  │
│  │  ├── TelemetryStream.swift (核心流式引擎)        │  │
│  │  │   - URLSessionWebSocketTask 直连流服务        │  │
│  │  │   - 自动断线指数退避重连与心跳保活            │  │
│  │  │                                               │  │
│  │  ├── TessieClient.swift (REST 辅助引擎)          │  │
│  │  │   - URLSession 异步执行控制指令 (POST command) │  │
│  │  │   - 按需拉取历史充电/行程聚合账单 (GET)       │  │
│  │  │                                               │  │
│  │  └── BridgeHandler.swift                         │  │
│  │      - WKScriptMessageHandler 双向中继            │  │
│  └──────────────────▲───────────────────────────────┘  │
└─────────────────────┼──────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        │ WSS (实时流)   │ HTTPS (REST)
        ▼                            ▼
┌──────────────────────────┐   ┌─────────────────────────┐
│ wss://streaming.tessie   │   │ https://api.tessie.com  │
│ (Fleet Telemetry 长连接) │   │ (车机控制指令/历史账单) │
└──────────────────────────┘   └─────────────────────────┘
```

---

## 3. Swift Native 模块实现规范

### 3.1 核心流式引擎 (`TelemetryStream.swift`)
基于 Apple `Foundation` 原生 API，无任何三方库：

```swift
import Foundation

final class TelemetryStream {
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private let session = URLSession(configuration: .default)
    var onTelemetryFrame: ((Data) -> Void)?
    var onConnectionStateChange: ((Bool) -> Void)?

    func connect(vin: String, token: String) {
        guard let url = URL(string: "wss://streaming.tessie.com/\(vin)?access_token=\(token)") else { return }
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        listen()
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.isConnected = true
                self.onConnectionStateChange?(true)
                if case .string(let text) = message, let data = text.data(using: .utf8) {
                    self.onTelemetryFrame?(data)
                }
                self.listen() // 持续循环监听下一帧
            case .failure:
                self.isConnected = false
                self.onConnectionStateChange?(false)
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            // 自动重连
        }
    }
}
```

### 3.2 控制与历史请求引擎 (`TessieClient.swift`)
使用 Swift 现代 `async/await` 原生处理指令：
- `executeCommand(endpoint: String, params: [String: Any]) async throws -> Bool`：向 `https://api.tessie.com/{vin}/command/{endpoint}` 发送 POST。
- `fetchHistoricalSessions() async throws -> HistoricalData`：启动或切换 Tab 时单次拉取充电流水与历史行程。

### 3.3 界面双向桥接 (`BridgeHandler.swift`)
- **Swift → Web（流式推送数据）**：
  收到 WebSocket 帧时，直接在主线程派发：
  ```swift
  webView.evaluateJavaScript("window.updateTelemetryFrame(\(jsonString));")
  ```
- **Web → Swift（原生控件点击）**：
  ```javascript
  window.webkit.messageHandlers.teslaNative.postMessage({
    action: "command",
    endpoint: "start_climate",
    params: { temperature: 22.0 }
  });
  ```

---

## 4. UI 界面与交互规范

### 4.1 窗口 Header 右侧流状态
- **移除**：所有 30 秒轮询复选框及轮询计时器。
- **保留**：
  - `● LIVE STREAMING`：高亮绿色呼吸灯指示流连接通畅，车端数据实时汇入。
  - `○ RECONNECTING...`：若休眠或断网，自动显示重连状态。
  - `[↻]`：微型按需强制全量同步按钮（仅在需要重新对齐历史全量快照时点击）。

### 4.2 Tab 04 车辆快捷控制中心
- **寻车与灯光**：[鸣笛寻车] / [双跳闪灯]
- **智能座舱空调**：当前车温 29.4°C，`[-] 22.0°C [+]` 温度步进调节器，[开启空调]（实心绿）与 [关闭]（实心红）。
- **目的地导航**：搜索输入框（输入目的地商户名/地址），点击 [推送到车机] 直接写入车机大屏导航。
- **充电管理**：[80% 日常使用] / [100% 长途出行]，[停止充电] 紧急动作。
- **车门车窗**：[车窗透气留缝] / [一键完全关窗]。
- **哨兵模式**：实时布防状态，[开启哨兵监控] / [关闭哨兵]。
- **状态 Toast**：Swift 原生收到车机 200 OK 后，浮动 Toast 提示 `⚡ 指令已发送: 空调开启至 22.0°C`。

---

## 5. 工程与编译验证

```text
macos/
├── Package.swift                     # 纯 SPM，零外部依赖，仅依附 macOS SDK
├── Makefile                          # make run / make app
└── Sources/
    ├── main.swift                    # NSWindow 主窗口与入口
    ├── Config.swift                  # 凭据解析
    ├── TelemetryStream.swift         # 原生 URLSessionWebSocketTask
    ├── TessieClient.swift            # 原生 URLSession HTTPS REST
    └── BridgeHandler.swift           # WKScriptMessageHandler
```

终端一键编译运行：
```bash
cd macos && swift run
```
