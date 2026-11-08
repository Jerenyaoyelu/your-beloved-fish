# 小鲸鱼桌宠（Whale Pet）

一只**独立运行在 Windows 桌面上**的小鲸鱼：不需要打开 DeepSeek Harness 窗口，也能一直在屏幕角落陪着你。
始终置顶、透明无边框、可以拖着走、点它会冒泡、双击它就能聊天。

- 技术栈：Windows PowerShell 5.1 + WPF，**不用安装 Node / Electron / Python**
- 聊天：直连 DeepSeek API（`api.deepseek.com`），和你的 DeepSeek 账号余额共用
- 资源占用：一个 PowerShell 进程，内存约 60–100 MB

---

## 一、启动

- 双击桌面上的 **「小鲸鱼桌宠」** 快捷方式；或
- 双击本目录里的 `start-whale-pet.vbs`（无控制台窗口）

启动后小鲸鱼会出现在屏幕**右下角**，气泡提示几秒后自动消失。
开机自启已经加到「启动」文件夹，登录 Windows 后会自己出现。

> 如果 360 / 火绒等安全软件弹「有程序修改系统启动目录」，那是它创建开机启动项，点**允许**即可；不允许也不影响手动启动。

## 二、第一次聊天：填 API Key

小鲸鱼现在还没有 key，所以只会冒泡、不会说话。填一次就行：

1. 打开 <https://platform.deepseek.com/api_keys>（用你的 DeepSeek 账号登录）
2. 点「创建 API key」，复制 `sk-` 开头的那串
3. **右键小鲸鱼 →「设置…」** → 粘贴到 `DeepSeek API Key` → 保存

保存后会自动拉一次余额，标题栏会显示「余额 ¥xx.xx」。
API Key 用 Windows DPAPI 加密后存在本机 `data\config.json`，只有当前 Windows 用户能解密。

> 计费说明：这里走的是 DeepSeek 官方 API，按 token 计费，和网页版/账号余额是同一个钱包。
> 如果账号里没有余额，聊天会提示 402。

## 三、操作

| 操作 | 效果 |
|---|---|
| 按住拖动 | 移动位置，松手自动记住（会自动贴回屏幕内） |
| 单击 | 随机冒一句泡，并显示余额 / 今日 token |
| 双击 | 打开 / 关掉聊天窗口 |
| 右键 | 菜单：聊天、刷新余额、始终置顶、开机自启、设置、打开数据文件夹、退出 |
| 托盘图标 | 左键/双击开聊天，右键可显示隐藏、刷新、退出 |

聊天窗口：`Enter` 发送，`Esc` 收起；右上角 `✕` 只是隐藏，右键鲸鱼随时能叫回来。

## 四、文件说明

```
whale-pet/
├─ WhalePet.ps1            主程序（WPF 界面 + 聊天 + 余额）
├─ start-whale-pet.vbs     静默启动器（无控制台）
├─ assets/whale.png        小鲸鱼形象
├─ assets/whale.ico        快捷方式/托盘图标
└─ data/                   运行数据（自动生成）
   ├─ config.json          位置、模型、加密后的 API Key、今日 token
   └─ whale-pet.log        运行日志（排查问题看这里）
```

## 五、卸载

1. 右键小鲸鱼 → **退出**（或托盘图标右键 → 退出）
2. 删除「启动」文件夹里的 `小鲸鱼桌宠.lnk`（`Win+R` 输入 `shell:startup`）和桌面快捷方式
3. 删除整个 `whale-pet` 文件夹

如果只是不想开机自启：右键小鲸鱼 → 取消勾选「开机自启」。

## 六、常见问题

- **聊天报 401**：key 填错或已删除，重新在设置里粘贴。
- **聊天报 402**：DeepSeek 账户余额不足。
- **聊天报「连不上 DeepSeek 服务器」**：检查网络 / 代理；开了系统代理但 PowerShell 不走代理时，可在 `WhalePet.ps1` 开头加 `$env:HTTPS_PROXY='http://127.0.0.1:端口'`。
- **模型名**：默认 `deepseek-chat`，可在设置里改（如 `deepseek-reasoner`）。报 400 且提示模型不存在时换一个。
- **想换形象**：替换 `assets\whale.png`（建议 610×610 透明 PNG），重启桌宠。
- **想调大小**：改 `WhalePet.ps1` 里主窗口的 `Width="360" Height="430"` 和 `WhaleImage` 的 `Width/Height`。

## 七、许可与素材来源

- **代码**：MIT（见 `LICENSE`）。
- **形象素材** `assets/whale.png` / `assets/whale.ico`：来自
  [MeteorNOX/DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)
  的 `assets/DSniang1.png`。该项目声明代码为 MIT，但 `assets/` 目录为 as-is 提供、不在 MIT 覆盖范围内；
  使用前请自行确认素材授权。想换成自己的图，直接替换 `assets/whale.png` 即可（610×610 透明 PNG）。

## 八、和 DSH 插件的关系

- 这个是**独立的桌宠**，DSH 关掉也照样在。
- DSH 里那个「小鲸鱼挂件」仍然只出现在 DSH 窗口右下角，两者互不影响，可以同时用。
