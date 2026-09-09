# AppNotes

原生 macOS 菜单栏应用，用来记录已安装应用的用途、快捷键和提醒，并整理个人应用分类。

[![Build macOS](https://github.com/CallMeKingsley97/AppNotes/actions/workflows/macos.yml/badge.svg)](https://github.com/CallMeKingsley97/AppNotes/actions/workflows/macos.yml)
[![macOS](https://img.shields.io/badge/macOS-15%2B-black)](#系统要求)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 特性

- 原生三栏界面：分类、应用列表、应用详情。
- 应用详情可切换「应用概览」和「我的备注」。
- 概览包含应用介绍、应用信息和 App 内购买卡片。
- 支持复制完整信息、展开全文和使用 Apple 翻译。
- 应用备注自动保存，可在离线状态下记录。
- `⌃⌥N` 打开快捷搜索，方向键选择，回车打开应用，`Esc` 关闭。
- 支持跟随系统、浅色和深色外观。
- 界面语言支持跟随系统、简体中文和 English，切换后立即生效。
- 支持自建分类、批量管理应用、从右键菜单归类和查看分类成员。

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

`Build/Tests/AppDetailsTests --live` 会请求真实 App Store 数据，需要联网。常规测试使用离线数据。

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

应用备注、分类和偏好保存在本机。商店资料按 App ID / Bundle ID 匹配，来自 Apple lookup 接口和公开 App Store 页面，并按地区与界面语言缓存 24 小时。

分类不会移动应用文件；删除分类不会卸载应用，也不会删除应用备注。

## 发布

推送 `v*` 标签会触发 GitHub Actions 构建，并上传 DMG 到对应的 GitHub Release。

```sh
git tag v1.0.0
git push origin v1.0.0
```

## Community

Shared on [LINUX DO](https://linux.do).

## 贡献

欢迎提交 Issue 和 Pull Request。提交前请运行：

```sh
./build.sh
zsh test.sh
```

## License

Released under the [MIT License](LICENSE).
