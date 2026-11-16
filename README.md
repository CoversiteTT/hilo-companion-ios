# Hilo 连接

Hilo 和 Hilo Plus 的自用 iPhone 蓝牙客户端。设备连接和记录统计在手机上完成。项目基于 SwiftUI 和 Core Bluetooth，适用于 iOS 16 及以上。

## 在 Windows 上装机

1. 下载构建产物中的 `Hilo-Companion-0.1.0-unsigned.ipa`。
2. 在 Windows 安装 AltServer，用它在 iPhone 上安装 AltStore Classic。按 AltStore 引导启用 iPhone 的开发者模式。[AltStore 官方安装指南](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)
3. 把 IPA 存进 iPhone 的「文件」。在 AltStore 的「My Apps」点 `+` 选中 IPA，用自己的 Apple 账号签名并安装。

## 连接和同步

1. 连按设备控制键 5 次进入配对模式。在 App 点「搜索设备」，选择自己的 Hilo 或 Hilo Plus。若 iOS 弹出蓝牙配对请求，按系统提示操作。
2. Hilo Plus 通过充电盒连接。调整档位或同步记录前，将加热笔插入已连接的充电盒。
3. 等设备空闲后，在「加热时长」选档并保存。设备的响应和读回值一致时，App 会显示保存成功。
4. 在「使用统计」点「同步记录」。统计范围为手机已同步到的记录，可按设备或加热笔查看，支持今天、近 7 天和近 30 天。

如果找不到设备，确认它正在配对模式，并让当前与之连接的客户端先断开。如果固件要求官方启用，请先完成官方流程。真机配对和不同固件的兼容性仍待验证。

## 构建

在 macOS 上运行 `bash Scripts/build-ipa.sh`。项目也可以在 Xcode 中打开并用自己的开发团队签名。GitHub Actions 产物是 arm64 的未签名 IPA，安装前应签名。

## 协议依据

- Hilo 和 Hilo Plus 的四个会话服务 UUID 来自 myglo 网页客户端。原版的标准档位为 5 分 10 秒、4 分钟、3 分钟。1.5 版使用独立的 Smooth 和 Boost 系列档位。[myglo 功能说明](https://www.myglo.com/en-gr/pages/hilo-app) · [公开蓝牙实现](https://app.myglo.com/it/static/js/820.fcbbfb98.js) · [公开客户端](https://app.myglo.com/it/static/js/696.fa3983a0.js)
- 时长设置使用官方档位编号，收到设备确认后再次查询当前档位。记录同步订阅和读取会话记录特征。原版采用 19 字节记录，1.5 版还支持带版本字节的批量记录。Hilo Plus 历史按加热笔去重。
- 协议测试使用合成数据覆盖 UUID、档位读写、记录标志位、批量解析、时间戳处理和重复同步。[日本市场公开配置](https://dfa00k0zv1pye.cloudfront.net/v1.0/tenants/configurations/ppmo598fh4cp4dll4o1bqp3zx5msi9iz)
