# BBDown Web Server - zero deps, PowerShell only
$workDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bbdown = Join-Path $workDir "BBDown.exe"
$ffmpeg = Join-Path $workDir "ffmpeg.exe"
$qrfile = Join-Path $workDir "qrcode.png"
$datafile = Join-Path $workDir "BBDown.data"
$configfile = Join-Path $workDir "config.json"
$script:downloadDir = $workDir
function load-config {
  if (-not (Test-Path $configfile)) { return }
  try {
    $cfg = Get-Content $configfile -Raw | ConvertFrom-Json
    if ($cfg.downloadDir) {
      $dir = [IO.Path]::GetFullPath([string]$cfg.downloadDir)
      if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      $script:downloadDir = $dir
    }
  } catch {}
}
load-config
$port = 3000

$acl = "http://localhost:$port/"
try { $listener = New-Object System.Net.HttpListener; $listener.Prefixes.Add($acl) } catch {
  netsh http add urlacl url=$acl user=$env:USERNAME 2>$null
  $listener = New-Object System.Net.HttpListener; $listener.Prefixes.Add($acl)
}
$listener.Start()
Write-Host "http://localhost:$port"
Start-Process "http://localhost:$port"

# -- helpers --
function json($ctx, $data, $code=200) {
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = "application/json; charset=utf-8"
  $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $data -Compress -Depth 10))
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}

function read-body($ctx) {
  $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
  $body = $reader.ReadToEnd()
  if ($body) { return (ConvertFrom-Json $body) } else { return @{} }
}

function run-bbdown {
  param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
  )
  $pinfo = New-Object System.Diagnostics.ProcessStartInfo
  $pinfo.FileName = $bbdown
  $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
  $cmdline = [string]::Join(' ', $quoted)
  $pinfo.Arguments = $cmdline
  $pinfo.WorkingDirectory = $workDir
  $pinfo.RedirectStandardOutput = $true
  $pinfo.RedirectStandardError = $true
  $pinfo.UseShellExecute = $false
  $pinfo.CreateNoWindow = $true
  $pinfo.StandardOutputEncoding = [Text.Encoding]::GetEncoding('gb2312')
  $pinfo.StandardErrorEncoding = [Text.Encoding]::GetEncoding('gb2312')
  $proc = [System.Diagnostics.Process]::Start($pinfo)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  return @{ code = $proc.ExitCode; stdout = $stdout; stderr = $stderr; cmd = $cmdline }
}

# 递归统计目录大小（含 BBDown 下载中的临时分片）
function dir-size($path) {
  if (-not (Test-Path $path)) { return 0 }
  $s = (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if (-not $s) { return 0 } else { return [long]$s }
}

# -- parse BBDown -info output --
function parse-info($stdout) {
  $result = @{ title=''; upHome=''; date=''; pages=@(); videoStreams=@(); audioStreams=@() }
  foreach ($line in ($stdout -split "\r?\n")) {
    $t = $line.Trim()
    if ($t -match '视频标题:\s*(.+)$') { $result.title = $Matches[1].Trim() }
    if ($t -match 'UP主页:\s*(.+)$') { $result.upHome = $Matches[1].Trim() }
    if ($t -match '发布时间:\s*(.+)$') { $result.date = $Matches[1].Trim() }
    if ($t -match 'P(\d+):\s*\[(\d+)\]\s*\[(.*?)\]\s*\[(.*?)\]') {
      $result.pages += @{ index=[int]$Matches[1]; cid=$Matches[2]; title=$Matches[3]; duration=$Matches[4] }
    }
    if ($t -match '^(\d+)\.\s*\[(.+?)\]\s*\[(\d+)x(\d+)\]\s*\[(.+?)\]\s*\[([\d.]+)\]\s*\[(\d+)\s*kbps\]\s*\[~(.+?)\]') {
      $result.videoStreams += @{ index=[int]$Matches[1]; quality=$Matches[2]; width=[int]$Matches[3]; height=[int]$Matches[4]; codec=$Matches[5]; fps=[double]$Matches[6]; bitrate=[int]$Matches[7]; size=$Matches[8] }
    }
    if ($t -match '^(\d+)\.\s*\[M4A\]\s*\[(\d+)\s*kbps\]\s*\[~(.+?)\]') {
      $result.audioStreams += @{ index=[int]$Matches[1]; format='M4A'; bitrate=[int]$Matches[2]; size=$Matches[3] }
    }
  }
  return $result
}

# -- SSE --
function sse-start($ctx) {
  $ctx.Response.ContentType = "text/event-stream"
  $ctx.Response.Headers.Add("Cache-Control", "no-cache")
  $ctx.Response.Headers.Add("Connection", "keep-alive")
  $ctx.Response.StatusCode = 200
  $sw = New-Object System.IO.StreamWriter($ctx.Response.OutputStream, [Text.Encoding]::UTF8)
  $sw.AutoFlush = $true
  return $sw
}
function sse-send($sw, $event, $data) {
  $sw.Write("event: $event`n")
  $sw.Write("data: $(ConvertTo-Json $data -Compress -Depth 5)`n")
  $sw.Write("`n")
}

# 解析 BBDown 输出行并发 SSE（进度行含百分比+速度+已下/总量）
function send-bbdown-line($sw, $line) {
  $t = $line.Trim()
  if (-not $t) { return }
  if ($t -match '(\d+\.?\d*)%') {
    $m = @{ percent=[double]$Matches[1] }
    if ($t -match '([\d.]+)\s*(KiB|MiB|GiB|TiB)?/s' -and $Matches[1]) { $m.speed=[double]$Matches[1]; $m.speedUnit=$Matches[2] }
    if ($t -match '([\d.]+)\s*(KiB|MiB|GiB|TiB)?/([\d.]+)\s*(KiB|MiB|GiB|TiB)?' -and $Matches[1] -and $Matches[3]) { $m.done=[double]$Matches[1]; $m.doneUnit=$Matches[2]; $m.total=[double]$Matches[3]; $m.totalUnit=$Matches[4] }
    sse-send $sw 'progress' $m
  }
  elseif ($t -match '开始下载|合并|分片|下载.*完毕|任务完成|完成') { sse-send $sw 'status' @{ msg=$t } }
  else { sse-send $sw 'log' @{ msg=$t } }
}

function convert-format {
  param (
    [string] $format,
    [System.IO.DirectoryInfo] $dir
  )
  
  # 要转换的源扩展名
  $sourceExts = @('mp4', 'm4a')
  
  # 递归查找文件
  $files = Get-ChildItem -LiteralPath $Dir -Recurse -File | Where-Object {
      $sourceExts -contains $_.Extension.TrimStart('.').ToLower() -and $_.Name -like '*.raw*'
  }
  
  foreach ($file in $files) {
      $index++
      $targetPath = [System.IO.Path]::ChangeExtension($file.FullName, $Format).Replace('.raw', '')
  
      # 调用 ffmpeg，若不转换则直接复制
      if ($format -eq "none") {
        Copy-Item -Path $file.FullName -Destination $file.FullName.Replace('.raw', '')
      } else {
        & $ffmpeg -hide_banner -loglevel error -y -i $file.FullName $targetPath
      
        if ($LASTEXITCODE -ne 0) {
          # 清理可能产生的不完整输出
          if ((Test-Path -LiteralPath $targetPath) -and ($targetPath -ne $file.FullName)) {
            Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
          }
          continue
        }
      }
  
      # 转换成功，删除原文件
      if ($targetPath -ne $file.FullName) {
          Remove-Item -LiteralPath $file.FullName -Force
      }
  }
}

# -- login state --
$script:loginProc = $null

# -- main loop --
while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $req = $ctx.Request
  $path = $req.Url.AbsolutePath
  $method = $req.HttpMethod
  $ctx.Response.Headers.Add("Access-Control-Allow-Origin", "*")
  if ($method -eq 'OPTIONS') {
    $ctx.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
    $ctx.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
    $ctx.Response.StatusCode = 204; $ctx.Response.Close(); continue
  }
  try {
    # GET / or /index.html
    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
      $html = Get-Content (Join-Path $workDir "index.html") -Raw -Encoding UTF8
      $ctx.Response.ContentType = "text/html; charset=utf-8"
      $bytes = [Text.Encoding]::UTF8.GetBytes($html)
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      $ctx.Response.Close(); continue
    }
    # GET /qrcode.min.js
    if ($method -eq 'GET' -and $path -eq '/qrcode.min.js') {
      $jsPath = Join-Path $workDir 'qrcode.min.js'
      if (-not (Test-Path $jsPath)) { json $ctx @{ error='Not found' } 404; continue }
      $js = [IO.File]::ReadAllBytes($jsPath)
      $ctx.Response.ContentType = 'application/javascript; charset=utf-8'
      $ctx.Response.OutputStream.Write($js, 0, $js.Length); $ctx.Response.Close(); continue
    }
    # GET /api/login/status
    if ($method -eq 'GET' -and $path -eq '/api/login/status') {
      $loggedIn = $false
      $inProgress = ($script:loginProc -ne $null -and !$script:loginProc.HasExited)
      # 登录进行中时忽略旧账号的 SESSDATA，避免误判新登录已完成
      if (-not $inProgress -and (Test-Path $datafile)) { $loggedIn = ((Get-Content $datafile -Raw -ErrorAction SilentlyContinue) -match 'SESSDATA=') }
      $msg = ''
      if (-not $loggedIn) {
        $statusFile = Join-Path $workDir 'login-status.txt'
        if (Test-Path $statusFile) {
          $st = (Get-Content $statusFile -Raw -ErrorAction SilentlyContinue).Trim()
          if ($st -eq 'EXPIRED') { $msg = '二维码已过期，请重新生成' }
          elseif ($st -eq 'TIMEOUT') { $msg = '登录超时，请重新生成' }
          elseif ($st -like 'ERROR*') { $msg = $st }
        }
      }
      json $ctx @{
        loggedIn=$loggedIn
        loginInProgress=$inProgress
        message=$msg
      }; continue
    }
    # POST /api/login/start
    if ($method -eq 'POST' -and $path -eq '/api/login/start') {
      $body = read-body $ctx
      # 已有登录进程则先结束，允许随时换账号重新登录
      if ($script:loginProc -and !$script:loginProc.HasExited) { try { $script:loginProc.Kill() } catch {} }
      if ($body.type -eq 'tv') {
        # TV 登录（走 BBDown logintv）
        Remove-Item $qrfile -Force -ErrorAction SilentlyContinue
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $bbdown; $pinfo.Arguments = 'logintv'; $pinfo.WorkingDirectory = $workDir
        $pinfo.UseShellExecute = $false; $pinfo.CreateNoWindow = $true
        $script:loginProc = [System.Diagnostics.Process]::Start($pinfo)
        for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path $qrfile) { break } }
        json $ctx @{ ok=$true; qrReady=(Test-Path $qrfile); type='tv' }; continue
      }
      # WEB 扫码登录（自研流程，绕开 BBDown 1.6.3 假登录 bug）
      Remove-Item (Join-Path $workDir 'qrcode_url.txt') -Force -ErrorAction SilentlyContinue
      Remove-Item (Join-Path $workDir 'login-status.txt') -Force -ErrorAction SilentlyContinue
      $worker = Join-Path $workDir 'login-worker.ps1'
      $pinfo = New-Object System.Diagnostics.ProcessStartInfo
      $pinfo.FileName = 'powershell.exe'
      $pinfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$worker`" `"$workDir`""
      $pinfo.WorkingDirectory = $workDir; $pinfo.UseShellExecute = $false; $pinfo.CreateNoWindow = $true
      $script:loginProc = [System.Diagnostics.Process]::Start($pinfo)
      $qrUrl = ''
      for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path (Join-Path $workDir 'qrcode_url.txt')) { $qrUrl = Get-Content (Join-Path $workDir 'qrcode_url.txt') -Raw; break } }
      # 注意：此响应含 URL，子进程运行期间 ConvertTo-Json 会卡死，故手工拼 JSON
      $ok = if ($qrUrl -ne '') { 'true' } else { 'false' }
      $esc = ([string]$qrUrl).Replace('\','\\').Replace('"','\"')
      $jsonBody = '{"ok":' + $ok + ',"type":"web","qrcodeUrl":"' + $esc + '"}'
      $ctx.Response.StatusCode = 200
      $ctx.Response.ContentType = "application/json; charset=utf-8"
      $bytes = [Text.Encoding]::UTF8.GetBytes($jsonBody)
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      $ctx.Response.Close()
      continue
    }
    # POST /api/login/cancel
    if ($method -eq 'POST' -and $path -eq '/api/login/cancel') {
      if ($script:loginProc -and !$script:loginProc.HasExited) { try { $script:loginProc.Kill() } catch {} }
      json $ctx @{ ok=$true }; continue
    }
    # GET /api/qrcode
    if ($method -eq 'GET' -and $path -eq '/api/qrcode') {
      if (-not (Test-Path $qrfile)) { json $ctx @{ error='No QR code' } 404; continue }
      $img = [System.IO.File]::ReadAllBytes($qrfile)
      $ctx.Response.ContentType = "image/png"; $ctx.Response.Headers.Add("Cache-Control", "no-cache")
      $ctx.Response.OutputStream.Write($img, 0, $img.Length); $ctx.Response.Close(); continue
    }
    # GET /api/config
    if ($method -eq 'GET' -and $path -eq '/api/config') {
      json $ctx @{ downloadDir=$script:downloadDir }; continue
    }
    # POST /api/config
    if ($method -eq 'POST' -and $path -eq '/api/config') {
      $body = read-body $ctx
      if (-not $body.downloadDir) { json $ctx @{ error='Missing downloadDir' } 400; continue }
      try {
        $dir = [IO.Path]::GetFullPath([string]$body.downloadDir)
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $cfgJson = @{ downloadDir=$dir } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($configfile, $cfgJson, (New-Object System.Text.UTF8Encoding($false)))
        $script:downloadDir = $dir
        json $ctx @{ ok=$true; downloadDir=$dir }
      } catch { json $ctx @{ error=$_.Exception.Message } 500 }
      continue
    }
    # POST /api/browse  弹出本机文件夹选择框（以当前前台窗口即浏览器为 owner，浮于网页之上）
    if ($method -eq 'POST' -and $path -eq '/api/browse') {
      try {
        Add-Type -AssemblyName System.Windows.Forms
        if (-not ('BBWin32' -as [type])) {
          Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class BBWin32 {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static IntPtr Active() { return GetForegroundWindow(); }
}
public class BBWin32Window : NativeWindow {}
'@ -ReferencedAssemblies System.Windows.Forms
        }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择下载目录'
        $dlg.SelectedPath = $script:downloadDir
        $dlg.ShowNewFolderButton = $true
        $result = $null
        $hwnd = [BBWin32]::Active()
        if ($hwnd -ne [IntPtr]::Zero) {
          $owner = New-Object BBWin32Window
          try { $owner.AssignHandle($hwnd); $result = $dlg.ShowDialog($owner) }
          catch { $result = $dlg.ShowDialog() }
          finally { $owner.ReleaseHandle() }
        } else {
          $result = $dlg.ShowDialog()
        }
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
          json $ctx @{ path = $dlg.SelectedPath }
        } else {
          json $ctx @{ path = '' }
        }
      } catch { json $ctx @{ error=$_.Exception.Message } 500 }
      continue
    }
    # POST /api/info
    if ($method -eq 'POST' -and $path -eq '/api/info') {
      $body = read-body $ctx
      if (-not $body.url) { json $ctx @{ error='Missing url' } 400; continue }
      if ($body.apiMode -eq 'tv') {
        $result = run-bbdown $body.url '-info' '--show-all' '--use-tv-api'
      } elseif ($body.apiMode -eq 'app') {
        $result = run-bbdown $body.url '-info' '--show-all' '--use-app-api'
      } elseif ($body.apiMode -eq 'intl') {
        $result = run-bbdown $body.url '-info' '--show-all' '--use-intl-api'
      } else {
        $result = run-bbdown $body.url '-info' '--show-all'
      }
      if ($result.code -ne 0) { json $ctx @{ error=($result.stderr, $result.stdout, "cmd: $($result.cmd)", "exit: $($result.code)" | ? {$_} | Select -First 1) } 500; continue }
      $info = parse-info $result.stdout
      $info.cmd = $result.cmd
      json $ctx $info; continue
    }
    # POST /api/download (SSE)
    if ($method -eq 'POST' -and $path -eq '/api/download') {
      $body = read-body $ctx
      if (-not $body.url) { json $ctx @{ error='Missing url' } 400; continue }
      $dlArgs = @($body.url, '--work-dir', $script:downloadDir, '--ffmpeg-path', $ffmpeg)

      # API mode
      if ($body.apiMode -eq 'tv') { $dlArgs += '--use-tv-api' }
      elseif ($body.apiMode -eq 'app') { $dlArgs += '--use-app-api' }
      elseif ($body.apiMode -eq 'intl') { $dlArgs += '--use-intl-api' }

      # Download mode
      if ($body.videoOnly) { $dlArgs += '--video-only' }
      if ($body.audioOnly) { $dlArgs += '--audio-only' }
      if ($body.danmakuOnly) { $dlArgs += '--danmaku-only' }
      if ($body.subOnly) { $dlArgs += '--sub-only' }
      if ($body.coverOnly) { $dlArgs += '--cover-only' }

      # Stream selection
      if ($body.dfnPriority) { $dlArgs += @('-q', $body.dfnPriority) }
      if ($body.encodingPriority) { $dlArgs += @('-e', $body.encodingPriority) }

      # Extra downloads
      if ($body.downloadDanmaku) { $dlArgs += '-dd' }

      # Skip flags
      if ($body.skipMux) { $dlArgs += '--skip-mux' }
      if ($body.skipSubtitle) { $dlArgs += '--skip-subtitle' }
      if ($body.skipCover) { $dlArgs += '--skip-cover' }

      # File naming
      if ($body.filePattern) { $dlArgs += @('-F', "$($body.filePattern).raw") }
      else {$dlArgs += @('-F', '<videoTitle>.raw')}
      if ($body.multiFilePattern) { $dlArgs += @('-M', $body.multiFilePattern) }

      # Page selection
      if ($body.selectPage) { $dlArgs += @('-p', $body.selectPage) }

      # Advanced
      if ($body.userAgent) { $dlArgs += @('-ua', $body.userAgent) }
      if ($body.cookie) { $dlArgs += @('-c', $body.cookie) }
      if ($body.language) { $dlArgs += @('--language', $body.language) }
      if ($body.delayPerPage) { $dlArgs += @('--delay-per-page', $body.delayPerPage) }
      if ($body.videoAscending) { $dlArgs += '--video-ascending' }
      if ($body.audioAscending) { $dlArgs += '--audio-ascending' }
      if ($body.allowPcdn) { $dlArgs += '--allow-pcdn' }
      if ($body.saveArchives) { $dlArgs += '--save-archives-to-file' }

      $sw = sse-start $ctx
      $q = $dlArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
      sse-send $sw 'status' @{ msg='Starting...'; cmd=([string]::Join(' ', $q)) }
      $pinfo = New-Object System.Diagnostics.ProcessStartInfo
      $pinfo.FileName = $bbdown; $pinfo.Arguments = [string]::Join(' ', $q)
      $pinfo.WorkingDirectory = $workDir; $pinfo.RedirectStandardOutput = $true; $pinfo.RedirectStandardError = $true
      $pinfo.UseShellExecute = $false; $pinfo.CreateNoWindow = $true
      $enc = [Text.Encoding]::GetEncoding('gb2312')
      $pinfo.StandardOutputEncoding = $enc; $pinfo.StandardErrorEncoding = $enc
      $proc = [System.Diagnostics.Process]::Start($pinfo)
      try {
        # 纯 .NET 异步读取（ReadAsync + Task 轮询），不用 PS 事件回调（PS5.1 会栈溢出），
        # 也不阻塞读空管道；进度条以 \r 结尾，按 \r/\n 切行即时上报
        # 文件增长监控（BBDown 1.6.3 不输出百分比，靠下载目录体积估算进度/速度）
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        $baseBytes = dir-size $script:downloadDir
        $lastBytes = 0
        $lastTick = 0
        $outReader = $proc.StandardOutput
        $errReader = $proc.StandardError
        $outChars = New-Object char[] 8192; $errChars = New-Object char[] 8192
        $outTask = $outReader.ReadAsync($outChars, 0, $outChars.Length)
        $errTask = $errReader.ReadAsync($errChars, 0, $errChars.Length)
        $outEOF = $false; $errEOF = $false
        $pending = ''
        $idle = 0
        while ($true) {
          $gotData = $false
          if (-not $outEOF -and $outTask.IsCompleted) {
            $n = $outTask.Result
            if ($n -gt 0) { $pending += [string]::new($outChars, 0, $n); $gotData = $true; $outTask = $outReader.ReadAsync($outChars, 0, $outChars.Length) }
            else { $outEOF = $true }
          }
          if (-not $errEOF -and $errTask.IsCompleted) {
            $n = $errTask.Result
            if ($n -gt 0) { $pending += [string]::new($errChars, 0, $n); $gotData = $true; $errTask = $errReader.ReadAsync($errChars, 0, $errChars.Length) }
            else { $errEOF = $true }
          }
          $lines = $pending -split "\r?\n|\r"
          if ($lines.Count -gt 1) {
            $pending = $lines[-1]
            for ($i = 0; $i -lt $lines.Count - 1; $i++) { send-bbdown-line $sw $lines[$i] }
          }
          if ($proc.HasExited) {
            if (-not $gotData) { $idle++ } else { $idle = 0 }
            if ($outEOF -and $errEOF -and -not $pending.Trim()) { break }
            if ($idle -ge 30) { break }   # 退出后再等最多 3 秒排空，防子进程占管道
          } else { $idle = 0 }
          # 每 0.5 秒上报一次字节进度
          $elapsed = $sw2.Elapsed.TotalSeconds
          if (($elapsed - $lastTick) -ge 0.5) {
            $cur = (dir-size $script:downloadDir) - $baseBytes
            if ($cur -gt 0 -or $lastBytes -gt 0) {
              $rate = [Math]::Max(0, [int64](($cur - $lastBytes) / [Math]::Max(0.001, ($elapsed - $lastTick))))
              sse-send $sw 'progress' @{ bytes=$cur; speed=$rate }
            }
            $lastBytes = $cur; $lastTick = $elapsed
          }
          Start-Sleep -Milliseconds 100
        }
        $proc.WaitForExit()
        if ($body.formatting -ne 'none') {sse-send $sw "正在转换格式..."}
        # 转换格式
        convert-format -format $body.formatting -dir $script:downloadDir
        if ($pending.Trim()) { send-bbdown-line $sw $pending }
        if ($proc.ExitCode -eq 0) { sse-send $sw 'done' @{ success=$true } } else { sse-send $sw 'error' @{ msg="exit: $($proc.ExitCode)" } }
        $sw.Close(); $ctx.Response.Close()
      } catch {
        try { $_.Exception.ToString() | Out-File (Join-Path $workDir 'dl-error.log') -Append } catch {}
        # 客户端断开或出错时结束 BBDown，避免孤儿进程
        try { $proc.Kill() } catch {}
        $sw.Dispose()
      }
      continue
    }
    # GET /api/files
    if ($method -eq 'GET' -and $path -eq '/api/files') {
      $files = Get-ChildItem $script:downloadDir -Recurse -File | ? { $_.Extension -match '\.(mp4|flv|mkv|m4a|mp3|ass|xml)$' } | Sort LastWriteTime -Desc | % {
        $rel = $_.FullName.Substring(([IO.Path]::GetFullPath($script:downloadDir)).Length).TrimStart('\','/')
        @{ name=$rel; size=$_.Length; mtime=$_.LastWriteTime.ToString('o') }
      }
      json $ctx @($files); continue
    }
    # GET /api/file/:name   （支持子目录相对路径，防路径穿越）
    if ($method -eq 'GET' -and $path -match '^/api/file/(.+)$') {
      $fname = [Uri]::UnescapeDataString($Matches[1])
      $fpath = [IO.Path]::GetFullPath((Join-Path $script:downloadDir $fname))
      $dl = ([IO.Path]::GetFullPath($script:downloadDir)).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
      if (-not $fpath.StartsWith($dl, [StringComparison]::OrdinalIgnoreCase)) { json $ctx @{ error='Forbidden' } 403; continue }
      if (-not (Test-Path $fpath)) { json $ctx @{ error='Not found' } 404; continue }
      $fname = [System.IO.Path]::GetFileName($fname)
      $bytes = [System.IO.File]::ReadAllBytes($fpath)
      if ($req.QueryString['view'] -eq '1') {
        if ($fname -match '\.(mp4|flv|mkv)$') { $ctx.Response.ContentType = 'video/mp4' }
        elseif ($fname -match '\.(mp3|m4a)$') { $ctx.Response.ContentType = 'audio/mp4' }
        elseif ($fname -match '\.(ass|xml)$') { $ctx.Response.ContentType = 'text/plain; charset=utf-8' }
        else { $ctx.Response.ContentType = 'application/octet-stream' }
      } else {
        $ctx.Response.ContentType = "application/octet-stream"
        $ctx.Response.Headers.Add("Content-Disposition", "attachment; filename*=UTF-8''$([Uri]::EscapeDataString($fname))")
      }
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close(); continue
    }
    # DELETE /api/file/:name
    if ($method -eq 'DELETE' -and $path -match '^/api/file/(.+)$') {
      $fname = [Uri]::UnescapeDataString($Matches[1])
      $fpath = [IO.Path]::GetFullPath((Join-Path $script:downloadDir $fname))
      $dl = ([IO.Path]::GetFullPath($script:downloadDir)).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
      if (-not $fpath.StartsWith($dl, [StringComparison]::OrdinalIgnoreCase)) { json $ctx @{ error='Forbidden' } 403; continue }
      if (-not (Test-Path $fpath)) { json $ctx @{ error='Not found' } 404; continue }
      Remove-Item $fpath -Force
      json $ctx @{ ok=$true }; continue
    }
    json $ctx @{ error='Not found' } 404
  } catch { try { json $ctx @{ error=$_.Exception.Message } 500 } catch {} }
}
$listener.Stop()
