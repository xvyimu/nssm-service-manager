# 打穿测试：酒馆视角发一条最小 TTS 请求给 shim，看转发链路
$body = @{
  model           = 'stepaudio-2.5-tts'
  input           = '测试'
  voice           = 'lengyanyujie'
  response_format = 'mp3'
} | ConvertTo-Json
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8001/v1/audio/speech' -Method Post `
    -ContentType 'application/json; charset=utf-8' -Body $body -UseBasicParsing -TimeoutSec 120
  "HTTP $($r.StatusCode); content-type: $($r.Headers['Content-Type']); bytes: $($r.RawContentLength)"
} catch {
  $resp = $_.Exception.Response
  if ($resp) {
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    $txt = $sr.ReadToEnd()
    "HTTP $([int]$resp.StatusCode)"
    $txt.Substring(0, [Math]::Min(300, $txt.Length))
  } else {
    "NO RESPONSE: $($_.Exception.Message)"
  }
}
