# BBDown Web Server - zero deps, PowerShell only
$workDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bbdown = Join-Path $workDir "BBDown.exe"
$ffmpeg = Join-Path $workDir "ffmpeg.exe"
$qrfile = Join-Path $workDir "qrcode.png"
$datafile = Join-Path $workDir "BBDown.data"
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
      $dlArgs = @($body.url, '--work-dir', $workDir, '--ffmpeg-path', $ffmpeg)

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
      if ($body.filePattern) { $dlArgs += @('-F', $body.filePattern) }
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
      $buffer = ''
      while (!$proc.HasExited) {
        while ($proc.StandardOutput.Peek() -ge 0) { $buffer += [char]$proc.StandardOutput.Read() }
        while ($proc.StandardError.Peek() -ge 0) { $buffer += [char]$proc.StandardError.Read() }
        $lines = $buffer -split "\r?\n"
        if ($lines.Count -gt 1) {
          $buffer = $lines[-1]
          for ($i = 0; $i -lt $lines.Count - 1; $i++) {
            $t = $lines[$i].Trim()
            if (-not $t) { continue }
            if ($t -match '(\d+\.?\d*)%') { sse-send $sw 'progress' @{ percent=[double]$Matches[1] } }
            elseif ($t -match '下载完成|合并|合成|完成') { sse-send $sw 'status' @{ msg=$t } }
            else { sse-send $sw 'log' @{ msg=$t } }
          }
        }
        Start-Sleep -Milliseconds 100
      }
      while ($proc.StandardOutput.Peek() -ge 0) { $buffer += [char]$proc.StandardOutput.Read() }
      while ($proc.StandardError.Peek() -ge 0) { $buffer += [char]$proc.StandardError.Read() }
      if ($proc.ExitCode -eq 0) { sse-send $sw 'done' @{ success=$true } } else { sse-send $sw 'error' @{ msg="exit: $($proc.ExitCode)" } }
      $sw.Close(); $ctx.Response.Close(); continue
    }
    # GET /api/files
    if ($method -eq 'GET' -and $path -eq '/api/files') {
      $files = Get-ChildItem $workDir | ? { $_.Extension -match '\.(mp4|flv|mkv|m4a|mp3|ass|xml)$' } | Sort LastWriteTime -Desc | % { @{ name=$_.Name; size=$_.Length; mtime=$_.LastWriteTime.ToString('o') } }
      json $ctx @($files); continue
    }
    # GET /api/file/:name
    if ($method -eq 'GET' -and $path -match '^/api/file/(.+)$') {
      $fname = [Uri]::UnescapeDataString($Matches[1])
      $fname = [System.IO.Path]::GetFileName($fname)
      $fpath = Join-Path $workDir $fname
      if (-not (Test-Path $fpath)) { json $ctx @{ error='Not found' } 404; continue }
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
      $fname = [System.IO.Path]::GetFileName($fname)
      $fpath = Join-Path $workDir $fname
      if (-not (Test-Path $fpath)) { json $ctx @{ error='Not found' } 404; continue }
      Remove-Item $fpath -Force
      json $ctx @{ ok=$true }; continue
    }
    json $ctx @{ error='Not found' } 404
  } catch { try { json $ctx @{ error=$_.Exception.Message } 500 } catch {} }
}
$listener.Stop()
