# HWiNFO Web Bridge
# Reads HWiNFO "Report value in Gadget" sensors from the Windows Registry
# and exposes a lightweight dashboard at http://127.0.0.1:8080/
#
# Requires: Windows PowerShell 5.1+ and HWiNFO running.
# No admin rights, no modules, no .NET SDK required.

param(
    [int]$Port = 8080
)

$ErrorActionPreference = "Stop"

function Get-HwInfoSnapshot {
    $paths = @(
        "HKCU:\Software\HWiNFO64\VSB",
        "HKLM:\Software\HWiNFO64\VSB",
        "HKCU:\Software\HWiNFO32\VSB",
        "HKLM:\Software\HWiNFO32\VSB"
    )

    $path = $null
    foreach ($p in $paths) {
        if (Test-Path $p) { $path = $p; break }
    }

    if (-not $path) {
        return @{
            ok = $false
            error = "HWiNFO VSB registry key not found. In HWiNFO Sensors -> Configure -> HWiNFO Gadget, enable 'Report value in Gadget' for the sensors you want."
            source = $null
            timestamp = (Get-Date).ToString("o")
            sensors = @()
        }
    }

    try {
        $data = Get-ItemProperty -Path $path
        $names = $data.PSObject.Properties.Name
        $indices = @()

        foreach ($name in $names) {
            if ($name -match '^Label(\d+)$') {
                $indices += [int]$Matches[1]
            }
        }
        $indices = $indices | Sort-Object -Unique

        $sensors = @()
        foreach ($i in $indices) {
            $sensorName = $data.PSObject.Properties["Sensor$i"].Value
            $label      = $data.PSObject.Properties["Label$i"].Value
            $value      = $data.PSObject.Properties["Value$i"].Value
            $raw        = $data.PSObject.Properties["ValueRaw$i"].Value

            if ($null -eq $label) { continue }

            $sensors += [pscustomobject]@{
                index  = $i
                sensor = [string]$sensorName
                label  = [string]$label
                value  = [string]$value
                raw    = [string]$raw
            }
        }

        return @{
            ok = $true
            error = $null
            source = $path
            timestamp = (Get-Date).ToString("o")
            sensors = $sensors
        }
    }
    catch {
        return @{
            ok = $false
            error = $_.Exception.Message
            source = $path
            timestamp = (Get-Date).ToString("o")
            sensors = @()
        }
    }
}

$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HWiNFO Remote Monitor</title>
<style>
:root{color-scheme:dark;background:#0b0e13;color:#e9edf5;font-family:Inter,Segoe UI,Arial,sans-serif}
*{box-sizing:border-box}
body{margin:0;padding:24px;max-width:1500px;margin:auto}
header{display:flex;justify-content:space-between;gap:20px;align-items:center;margin-bottom:18px}
h1{font-size:22px;margin:0}.muted{color:#8893a7;font-size:13px}
#status{padding:7px 11px;border-radius:999px;background:#151b25;font-size:12px}
.summary{display:grid;grid-template-columns:repeat(auto-fit,minmax(165px,1fr));gap:10px;margin-bottom:18px}
.metric,.group{background:#111722;border:1px solid #222c3b;border-radius:14px}
.metric{padding:14px}.metric .name{color:#98a5ba;font-size:12px}.metric .value{font-size:28px;font-weight:700;margin-top:5px}
.groups{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px}
.group{padding:14px}.group h2{font-size:14px;margin:0 0 10px;color:#cdd5e3}
.row{display:flex;justify-content:space-between;gap:15px;padding:7px 0;border-top:1px solid #1d2633}
.row:first-of-type{border-top:0}.label{color:#b4bdcc;font-size:13px;overflow:hidden;text-overflow:ellipsis}.val{font-variant-numeric:tabular-nums;font-weight:600;white-space:nowrap}
.warn{padding:15px;background:#29191b;border:1px solid #603036;border-radius:12px;margin-bottom:15px}
</style>
</head>
<body>
<header>
  <div><h1>HWiNFO Remote Monitor</h1><div class="muted" id="source">Waiting for HWiNFO…</div></div>
  <div id="status">connecting…</div>
</header>
<div id="error"></div>
<div class="summary" id="summary"></div>
<div class="groups" id="groups"></div>

<script>
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));

function find(sensors, patterns){
  for(const p of patterns){
    const x=sensors.find(s=>p.test((s.label||'')+' '+(s.sensor||'')));
    if(x) return x;
  }
  return null;
}
function metric(name, s){
  return `<div class="metric"><div class="name">${esc(name)}</div><div class="value">${s?esc(s.value):'—'}</div>${s?`<div class="muted">${esc(s.label)}</div>`:''}</div>`;
}
async function update(){
  try{
    const r=await fetch('/api/sensors',{cache:'no-store'});
    const d=await r.json();
    document.getElementById('status').textContent=d.ok?'LIVE':'NO DATA';
    document.getElementById('source').textContent=d.source||'HWiNFO registry not found';

    if(!d.ok){
      document.getElementById('error').innerHTML=`<div class="warn">${esc(d.error)}</div>`;
      document.getElementById('summary').innerHTML='';
      document.getElementById('groups').innerHTML='';
      return;
    }
    document.getElementById('error').innerHTML='';
    const s=d.sensors||[];

    const fps=find(s,[/Framerate Presented.*avg/i,/Framerate \(Presented\)/i,/Framerate Presented/i]);
    const ft=find(s,[/Frame Time/i]);
    const gpu=find(s,[/GPU Core Load/i,/GPU Utilization/i]);
    const gt=find(s,[/^GPU Temperature/i,/GPU.*Temperature/i]);
    const gp=find(s,[/^GPU Power/i,/GPU.*Power/i]);
    const cpu=find(s,[/Total CPU Usage/i]);
    const ct=find(s,[/CPU \(Tctl\/Tdie\)/i,/CPU Package.*Temperature/i,/CPU.*Temperature/i]);
    const cp=find(s,[/CPU Package Power/i]);
    const ram=find(s,[/Physical Memory Load/i,/Physical Memory Used/i]);

    document.getElementById('summary').innerHTML=
      metric('FPS',fps)+metric('Frame time',ft)+metric('GPU load',gpu)+metric('GPU temp',gt)+
      metric('GPU power',gp)+metric('CPU load',cpu)+metric('CPU temp',ct)+metric('CPU power',cp)+metric('RAM',ram);

    const by={};
    for(const x of s){
      const g=x.sensor||'Other';
      (by[g]??=[]).push(x);
    }
    document.getElementById('groups').innerHTML=Object.entries(by).map(([g,arr])=>
      `<section class="group"><h2>${esc(g)}</h2>`+
      arr.map(x=>`<div class="row"><div class="label">${esc(x.label)}</div><div class="val">${esc(x.value)}</div></div>`).join('')+
      `</section>`
    ).join('');
  }catch(e){
    document.getElementById('status').textContent='OFFLINE';
    document.getElementById('error').innerHTML=`<div class="warn">${esc(e.message)}</div>`;
  }
}
update(); setInterval(update,1000);
</script>
</body>
</html>
'@

function Send-HttpResponse {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [string]$ContentType,
        [string]$Body
    )
    $statusText = if ($StatusCode -eq 200) { "OK" } else { "Not Found" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $statusText`r`nContent-Type: $ContentType; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)

try {
    $listener.Start()
} catch {
    Write-Host ""
    Write-Host "Could not bind to 127.0.0.1:$Port" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "HWiNFO Web Bridge is running." -ForegroundColor Green
Write-Host "Local dashboard: http://127.0.0.1:$Port/" -ForegroundColor Cyan
Write-Host "API:             http://127.0.0.1:$Port/api/sensors" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "Now run: tmole.exe $Port" -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
            $requestLine = $reader.ReadLine()
            if (-not $requestLine) { continue }

            while ($true) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($line)) { break }
            }

            $parts = $requestLine.Split(' ')
            $path = if ($parts.Length -ge 2) { $parts[1].Split('?')[0] } else { "/" }

            if ($path -eq "/" -or $path -eq "/index.html") {
                Send-HttpResponse $stream 200 "text/html" $html
            }
            elseif ($path -eq "/api/sensors") {
                $snapshot = Get-HwInfoSnapshot
                $json = $snapshot | ConvertTo-Json -Depth 8 -Compress
                Send-HttpResponse $stream 200 "application/json" $json
            }
            elseif ($path -eq "/health") {
                Send-HttpResponse $stream 200 "text/plain" "ok"
            }
            else {
                Send-HttpResponse $stream 404 "text/plain" "Not found"
            }
        }
        catch {
            # Ignore one failed browser/tunnel request and keep serving.
        }
        finally {
            if ($client) { $client.Close() }
        }
    }
}
finally {
    $listener.Stop()
}
