# AppNotes · 应用备注

一个 macOS 菜单栏工具，为已安装的应用记录用途、快捷键和提醒。支持 macOS 15 及以上的 Apple Silicon Mac。

- 原生三栏界面：分类、应用列表、备注详情。
- 在窗口右上角的设置按钮、菜单栏「设置…」或 `⌘,` 中调整偏好。
- 外观支持跟随系统、浅色、深色；界面语言支持跟随系统、简体中文、English，立即生效并自动保存。
- `⌃⌥N` 打开快捷搜索，方向键选择、回车打开应用、Esc 关闭。
- 备注自动保存，已有备注和抓取到的简介不会随界面语言切换而翻译。

## 构建与验证

```sh
./build.sh
zsh test.sh
```

应用位于 `Build/AppNotes.app`。构建脚本会打包 `Resources` 中的中英文资源；`./package.sh` 可生成 DMG。

可选的原生界面检查：

```sh
zsh ui-review.sh
Build/UIReview.app/Contents/MacOS/UIReview
```

该程序在临时目录创建独立的测试数据，使用相同窗口依次切换两种语言和两种外观，输出到系统临时目录的 `appnotes-ui-review` 文件夹，并检查测试备注的保存内容。需要在 macOS 图形会话中运行。
