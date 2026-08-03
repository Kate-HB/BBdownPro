# BBDown web 扫码登录工作进程
# 直接调 B站 passport 接口，从 Set-Cookie 取 SESSDATA，绕开 BBDown 1.6.3 的假登录 bug
param([string]$WorkDir)

$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
$statusFile = Join-Path $WorkDir "login-status.txt"
$qrUrlFile  = Join-Path $WorkDir "qrcode_url.txt"
$dataFile   = Join-Path $WorkDir "BBDown.data"

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# 1) 生成二维码
try {
  $gen = Invoke-RestMethod -Uri "https://passport.bilibili.com/x/passport-login/web/qrcode/generate" `
    -WebSession $session -UserAgent $ua -UseBasicParsing -TimeoutSec 15
} catch {
  Set-Content $statusFile "ERROR: 生成二维码失败 $($_.Exception.Message)" -Encoding UTF8
  exit 1
}
if ($gen.code -ne 0 -or -not $gen.data.qrcode_key) {
  Set-Content $statusFile "ERROR: 二维码接口返回异常" -Encoding UTF8
  exit 1
}
# 先写二维码文件，避免慢步骤拖累显示
[IO.File]::WriteAllText($qrUrlFile, [string]$gen.data.url)

# 0) 访问首页种 buvid3 模拟真实浏览器会话（不阻塞二维码显示）
try {
  Invoke-WebRequest -Uri "https://www.bilibili.com" -WebSession $session -UserAgent $ua -UseBasicParsing -TimeoutSec 15 | Out-Null
} catch { }

# 2) 轮询扫码结果
for ($i = 0; $i -lt 85; $i++) {
  Start-Sleep -Milliseconds 2000
  try {
    $resp = Invoke-WebRequest -Uri "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=$($gen.data.qrcode_key)&source=main-fe-header&web_location=333.934" `
      -WebSession $session -UserAgent $ua -UseBasicParsing -TimeoutSec 15
    $d = (($resp.Content | ConvertFrom-Json).data)
    if ($null -eq $d -or $null -eq $d.code) { continue }
    if ($d.code -eq 0) {
      # 扫码确认成功：从 session 的 Set-Cookie 提取 cookie
      $seen = @{}; $list = @()
      foreach ($h in @('https://www.bilibili.com', 'https://passport.bilibili.com', 'https://bilibili.com')) {
        foreach ($c in $session.Cookies.GetCookies($h)) {
          if (-not $seen.ContainsKey($c.Name)) {
            $seen[$c.Name] = $true
            $list += "$($c.Name)=$($c.Value)"
          }
        }
      }
      if (-not $seen.ContainsKey('SESSDATA')) {
        Set-Content $statusFile "ERROR: 未取到 SESSDATA" -Encoding UTF8
        exit 1
      }
      [IO.File]::WriteAllText($dataFile, ($list -join ';'))
      Set-Content $statusFile "OK" -Encoding UTF8
      exit 0
    } elseif ($d.code -eq 86038) {
      Set-Content $statusFile "EXPIRED" -Encoding UTF8
      exit 1
    }
  } catch {
    # 网络抖动，继续轮询
  }
}
Set-Content $statusFile "TIMEOUT" -Encoding UTF8
exit 1
