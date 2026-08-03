# BBDown Web

基于 [BBDown](https://github.com/nilaoda/BBDown) 的可视化 Web 封装，零依赖，纯 PowerShell 驱动。

## 致谢

本项目仅为 [nilaoda/BBDown](https://github.com/nilaoda/BBDown) 的图形化前端封装，核心下载功能完全由 BBDown 提供。感谢原作者及相关贡献者的开发与维护。

## 快速开始

1. 确保目录下包含 `BBDown.exe`、`ffmpeg.exe`、`server.ps1`、`index.html`、`login-worker.ps1`、`qrcode.min.js`
2. 双击 `启动.bat`
3. 浏览器自动打开 `http://localhost:3000`

## 功能说明

### 登录

| 按钮 | 作用 |
|------|------|
| 扫码登录 | 自研扫码流程（`login-worker.ps1` + `qrcode.min.js`），绕过 BBDown 1.6.3 的"假登录"bug，从 Set-Cookie 提取 SESSDATA |
| TV登录 | 调用 `BBDown logintv`，电视端扫码登录 |

登录后可下载高画质视频。登录态保存在 `BBDown.data` 文件中。

> ⚠️ **已知问题**：BBDown 1.6.3 是官方最终版本（仓库已归档），其 `BBDown login` 扫码登录存在"假成功"bug——只会写入 `ticket` 等无效 cookie，导致界面误报"已登录"、画质始终停留在最低档。本项目已用自研扫码流程绕开该问题。若沿用旧版 `BBDown login`，请勿再点击扫码。

登录状态按 `BBDown.data` 中是否存在 `SESSDATA` 真实校验；扫码登录进行中会忽略旧账号登录态，支持随时换账号重新登录。

### 解析视频

粘贴 BV/AV/EP/SS 链接，选择 API 模式后点击"解析"：

| API 模式 | CLI 参数 | 适用场景 |
|----------|----------|----------|
| WEB | 默认 | 普通视频 |
| TV | `--use-tv-api` | 电视端接口，部分视频画质更高 |
| APP | `--use-app-api` | 移动端接口 |
| INTL | `--use-intl-api` | 国际版接口，港澳台及海外视频 |(目前似乎已失效)

解析结果展示：视频标题、UP主、发布时间、所有分P、可用视频流和音频流。

### 下载模式

| 模式 | CLI 参数 | 说明 |
|------|----------|------|
| 视频+音频 | 默认 | 下载并混流为完整视频文件 |
| 仅视频 | `--video-only` | 仅下载视频轨道 |
| 仅音频 | `--audio-only` | 仅下载音频轨道 |
| 仅弹幕 | `--danmaku-only` | 仅下载弹幕 XML 文件 |
| 仅字幕 | `--sub-only` | 仅下载字幕文件 |
| 仅封面 | `--cover-only` | 仅下载封面图片 |

冲突规则："仅字幕"模式自动禁用"跳过字幕"，"仅封面"模式自动禁用"跳过封面"。

### 画质与编码选择

点击视频流卡片选择目标画质和编码（HEVC/AVC）。`-q` 参数传入画质名称，`-e` 传入编码格式。音频流同理。

### 高级设置

| 选项 | CLI 参数 | 说明 |
|------|----------|------|
| 同时下载弹幕 | `-dd` | 下载视频的同时下载弹幕 |
| 跳过混流 | `--skip-mux` | 保留分离的音视频文件 |
| 跳过字幕 | `--skip-subtitle` | 不下载字幕 |
| 跳过封面 | `--skip-cover` | 不下载封面 |
| 视频升序 | `--video-ascending` | 优先下载最低画质 |
| 音频升序 | `--audio-ascending` | 优先下载最低音质 |
| 允许PCDN | `--allow-pcdn` | 允许使用 PCDN 加速 |
| 存档记录 | `--save-archives-to-file` | 跳过已下载的视频，避免重复 |
| 文件名模板 | `-F` | 自定义单P文件名，如 `<videoTitle>` |
| 多P模板 | `-M` | 自定义多P文件名结构 |
| 语言代码 | `--language` | 指定字幕语言，如 `chi`、`jpn` |
| 分P间隔 | `--delay-per-page` | 多P下载间隔（秒），降低限流风险 |
| User-Agent | `-ua` | 自定义 UA |
| Cookie | `-c` | 手动传入 Cookie 字符串 |

### 分P选择

多P视频解析后可勾选目标分P，仅下载选中的分P，对应 `-p` 参数。

### 文件管理

下载完成的文件支持在线播放（视频/音频）、文本查看（字幕/弹幕）、浏览器下载和删除操作。

## 文件类型标识

| 扩展名 | 类型 | 颜色 |
|--------|------|------|
| mp4/flv/mkv | 视频 | 绿色 |
| m4a/mp3 | 音频 | 蓝色 |
| ass | 字幕 | 橙色 |
| xml | 弹幕 | 灰色 |

## 法律声明

本工具仅供个人学习和研究使用。使用者应遵守所在地区法律法规及B站用户协议，不得用于侵犯他人知识产权、盗版传播等非法用途。下载内容请于 24 小时内删除，版权归原作者所有。因使用本工具产生的任何法律后果由使用者自行承担。

## 技术栈

- PowerShell 5.x+ (HttpListener)
- 原生 JavaScript (SSE)
- qrcode-generator（本地 `qrcode.min.js`，前端渲染二维码）
- 零外部依赖，无需 npm/pip
