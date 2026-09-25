# AppNotes

原生 macOS 应用，用来记录应用用途、快捷键和提醒，整理个人应用分类，并关注 App Store 应用及内购的限免变化。

[![Build macOS](https://github.com/CallMeKingsley97/AppNotes/actions/workflows/macos.yml/badge.svg)](https://github.com/CallMeKingsley97/AppNotes/actions/workflows/macos.yml)
[![macOS](https://img.shields.io/badge/macOS-15%2B-black)](#系统要求)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 特性

- 原生三栏界面：分类、应用列表、应用详情。
- 应用详情可切换「应用概览」「我的备注」和「最近更新」。
- 概览包含应用介绍、应用信息和 App 内购买卡片；最近更新展示 App Store 版本历史。
- 「最近更新」会按界面语言获取版本号、更新日期和更新说明，并支持复制。
- 支持复制完整信息、展开全文和使用 Apple 翻译。
- 应用备注自动保存，可在离线状态下记录。
- `⌃⌥N` 打开快捷搜索，方向键选择，回车打开应用，`Esc` 关闭。
- 支持跟随系统、浅色和深色外观。
- 界面语言支持跟随系统、简体中文和 English，切换后立即生效。
- 支持自建分类、批量管理应用、从右键菜单归类和查看分类成员。
- 复制 App Store 应用链接后回到 AppNotes，可确认导入，并在「手动导入」中与本机应用分开。
- 在顶部菜单栏保留快捷入口，同时在 Dock 显示应用图标。
- 关注 App Store 本体与公开内购价格；确认从收费降为免费后，在菜单栏和三栏提醒页用不同标识提示。
- 支持固定地区、未安装应用链接、未读/归档/撤销、单项暂停及自动检查开关。
- 关注详情完整展示商店公开的内购列表，包括同名商品，并标注价格获取时间；可比价条目单独统计。

## 关注价格与限免

1. 在「关注的应用」中点击 `+`，粘贴 App Store 链接并确认商店地区；也可以从应用详情点击关注。
2. 选择监控应用本体、内购或两者，保存关注。
3. 选中应用查看最近获取的价格。点击「立即检查」更新单个应用，列表底部的刷新按钮检查已启用的关注项。
4. 确认从收费降为免费后，在「限免提醒」和菜单栏查看记录，支持已读、归档和撤销。

「最近观察的价格」展示商店公开列表中的全部条目；「可比对」数量仅包含可以可靠比较价格的商品。同名商品仍会显示各自价格，但不会仅凭名称或列表位置认定为同一商品并推送限免提醒。

自动检查可在设置中暂停，暂停后仍可手动刷新。重新启动不会清空上次结果；更新应用后可手动刷新获取新结果。手动检查有至少 60 秒间隔，遇到 Apple 限流时会延后重试。

## 系统要求

- macOS 15 或更高版本
- Apple Silicon Mac
- Xcode Command Line Tools

## 快速开始

```sh
git clone https://github.com/CallMeKingsley97/AppNotes.git
cd AppNotes
./build.sh
open Build/AppNotes.app
```

## 开发命令

| 命令 | 说明 |
| --- | --- |
| `./build.sh` | 编译并生成 `Build/AppNotes.app` |
| `zsh test.sh` | 运行离线测试并校验本地化资源 |
| `./package.sh` | 构建并生成 DMG |
| `zsh ui-review.sh` | 编译原生界面检查工具 |
| `Build/UIReview.app/Contents/MacOS/UIReview` | 运行界面检查，需要在图形会话中执行 |

先执行 `./build.sh`，再执行 `zsh test.sh` 生成测试程序。`Build/Tests/AppDetailsTests --live` 和 `Build/Tests/PriceMonitoringTests --live` 会请求真实 App Store 数据，需要联网。常规测试使用离线数据与隔离临时目录，覆盖完整内购列表、同名/缺价条目、地区与语言校验、缓存兼容及价格事件判定。

## 项目结构

```text
Sources/                 SwiftUI 与 AppKit 应用源码
Tests/                   本地化、数据存储和界面检查测试
Resources/               英文与简体中文资源
.github/workflows/       macOS 构建与发布工作流
build.sh                 构建脚本
test.sh                  测试脚本
package.sh               DMG 打包脚本
```

## 数据与隐私

应用备注、分类和偏好保存在本机。商店资料按 App ID / Bundle ID 匹配，来自 Apple lookup 接口和公开 App Store 页面，并按地区与界面语言缓存 24 小时。「最近更新」优先使用应用安装时记录的商店地区；当该地区页面不可用时，会继续尝试其他可用地区，避免误显示为空记录。

分类不会移动应用文件；删除分类不会卸载应用，也不会删除应用备注。

限免监控独立保存在 `~/Library/Application Support/AppNotes/price-monitoring.json`，只在 AppNotes 运行时约每小时检查；关闭主窗口仍可检查，退出、关机或休眠期间停止。没有系统通知、云端监控或自动购买。监控地区固定，不采用资料查询的跨地区回退或 24 小时缓存。

内购展示保留商店公开列表的全部条目及获取时间，包括同名和缺价条目；价格监控另行筛选名称唯一、价格明确的条目。中国大陆商店固定读取中文，其他地区固定读取英文，不随界面语言改变；旧英文记录迁移到中文时重新建立比价基准。公开页面不提供稳定商品 ID，也可能不包含全部内购。改名、同名、缺价和试用不会被推断为限免，不保证覆盖订阅优惠、账号专享或 App 内促销。首次关注已经免费的条目不提醒；有收费基线并经过两次免费观测才生成事件。价格与购买条件以所选商店及 App 内购买页面为准。

## 发布

推送 `v*` 标签会触发 GitHub Actions 构建，并上传 DMG 到对应的 GitHub Release。

```sh
git tag v1.0.0
git push origin v1.0.0
```

## 社区

已分享在 [LINUX DO](https://linux.do).

## 贡献

欢迎提交 Issue 和 Pull Request。提交前请运行：

```sh
./build.sh
zsh test.sh
```

## License

Released under the [MIT License](LICENSE).
