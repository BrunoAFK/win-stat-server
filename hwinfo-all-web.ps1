param(
    [int]$Port = 8080
)

$ErrorActionPreference = "Stop"

# -----------------------------
# HWiNFO Shared Memory Reader
# -----------------------------
$cs = @"
using System;
using System.Collections.Generic;
using System.IO.MemoryMappedFiles;
using System.Text;
using System.Threading;

namespace HwInfoWeb
{
    public sealed class SensorInfo
    {
        public uint Index { get; set; }
        public uint Id { get; set; }
        public uint Instance { get; set; }
        public string Name { get; set; }
        public string NameOriginal { get; set; }
    }

    public sealed class ReadingInfo
    {
        public uint SensorIndex { get; set; }
        public uint ReadingId { get; set; }
        public uint Type { get; set; }
        public string Sensor { get; set; }
        public string SensorOriginal { get; set; }
        public string Label { get; set; }
        public string LabelOriginal { get; set; }
        public string Unit { get; set; }
        public double? Value { get; set; }
        public double? Min { get; set; }
        public double? Max { get; set; }
        public double? Avg { get; set; }
    }

    public sealed class Snapshot
    {
        public bool Ok { get; set; }
        public string Error { get; set; }
        public string Timestamp { get; set; }
        public uint Signature { get; set; }
        public uint Version { get; set; }
        public uint Revision { get; set; }
        public long PollTimeUnix { get; set; }
        public uint PollingPeriodMs { get; set; }
        public List<SensorInfo> Sensors { get; set; }
        public List<ReadingInfo> Readings { get; set; }

        public Snapshot()
        {
            Sensors = new List<SensorInfo>();
            Readings = new List<ReadingInfo>();
        }
    }

    public static class Reader
    {
        private const string MapName = @"Global\HWiNFO_SENS_SM2";
        private const string MutexName = @"Global\HWiNFO_SM2_MUTEX";
        private const uint ExpectedSignature = 0x53695748; // "HWiS"

        private static string ReadAnsi(MemoryMappedViewAccessor a, long offset, int length)
        {
            byte[] buf = new byte[length];
            a.ReadArray(offset, buf, 0, length);
            int n = Array.IndexOf(buf, (byte)0);
            if (n < 0) n = length;
            return Encoding.Default.GetString(buf, 0, n).Trim();
        }

        private static double? SafeDouble(double v)
        {
            if (Double.IsNaN(v) || Double.IsInfinity(v)) return null;
            return v;
        }

        private static string Prefer(string user, string original)
        {
            return String.IsNullOrWhiteSpace(user) ? original : user;
        }

        public static Snapshot Read()
        {
            Snapshot result = new Snapshot();
            result.Timestamp = DateTimeOffset.Now.ToString("o");

            Mutex mutex = null;
            bool locked = false;

            try
            {
                try
                {
                    mutex = Mutex.OpenExisting(MutexName);
                    try
                    {
                        locked = mutex.WaitOne(150);
                    }
                    catch (AbandonedMutexException)
                    {
                        locked = true;
                    }
                }
                catch
                {
                    // We can still take a best-effort snapshot if the mutex
                    // cannot be opened because of privilege boundaries.
                }

                using (MemoryMappedFile mmf = MemoryMappedFile.OpenExisting(
                    MapName, MemoryMappedFileRights.Read))
                using (MemoryMappedViewAccessor a = mmf.CreateViewAccessor(
                    0, 0, MemoryMappedFileAccess.Read))
                {
                    if (a.Capacity < 44)
                        throw new InvalidOperationException("HWiNFO shared memory mapping is too small.");

                    uint signature = a.ReadUInt32(0);
                    uint version = a.ReadUInt32(4);
                    uint revision = a.ReadUInt32(8);
                    long pollTime = a.ReadInt64(12);

                    uint sensorOffset = a.ReadUInt32(20);
                    uint sensorSize = a.ReadUInt32(24);
                    uint sensorCount = a.ReadUInt32(28);

                    uint readingOffset = a.ReadUInt32(32);
                    uint readingSize = a.ReadUInt32(36);
                    uint readingCount = a.ReadUInt32(40);

                    uint pollingPeriod = 0;
                    if (revision >= 1 && a.Capacity >= 48)
                        pollingPeriod = a.ReadUInt32(44);

                    result.Signature = signature;
                    result.Version = version;
                    result.Revision = revision;
                    result.PollTimeUnix = pollTime;
                    result.PollingPeriodMs = pollingPeriod;

                    if (signature != ExpectedSignature)
                        throw new InvalidOperationException(
                            "HWiNFO shared memory is not active. Signature: 0x" +
                            signature.ToString("X8"));

                    // Published HWiNFO SM2 base layouts are 264-byte sensor entries
                    // and 316-byte reading entries. Use the offsets/sizes advertised
                    // in the mapping so future extensions can append data safely.
                    if (sensorSize < 264)
                        throw new InvalidOperationException("Unexpected HWiNFO sensor element size: " + sensorSize);
                    if (readingSize < 316)
                        throw new InvalidOperationException("Unexpected HWiNFO reading element size: " + readingSize);

                    Dictionary<uint, SensorInfo> sensorMap = new Dictionary<uint, SensorInfo>();

                    for (uint i = 0; i < sensorCount; i++)
                    {
                        long p = (long)sensorOffset + ((long)sensorSize * i);
                        if (p < 0 || p + 264 > a.Capacity) break;

                        uint id = a.ReadUInt32(p + 0);
                        uint instance = a.ReadUInt32(p + 4);
                        string orig = ReadAnsi(a, p + 8, 128);
                        string user = ReadAnsi(a, p + 136, 128);

                        SensorInfo s = new SensorInfo {
                            Index = i,
                            Id = id,
                            Instance = instance,
                            NameOriginal = orig,
                            Name = Prefer(user, orig)
                        };

                        result.Sensors.Add(s);
                        sensorMap[i] = s;
                    }

                    for (uint i = 0; i < readingCount; i++)
                    {
                        long p = (long)readingOffset + ((long)readingSize * i);
                        if (p < 0 || p + 316 > a.Capacity) break;

                        uint type = a.ReadUInt32(p + 0);
                        uint sensorIndex = a.ReadUInt32(p + 4);
                        uint readingId = a.ReadUInt32(p + 8);

                        string labelOrig = ReadAnsi(a, p + 12, 128);
                        string labelUser = ReadAnsi(a, p + 140, 128);
                        string unit = ReadAnsi(a, p + 268, 16);

                        double value = a.ReadDouble(p + 284);
                        double min = a.ReadDouble(p + 292);
                        double max = a.ReadDouble(p + 300);
                        double avg = a.ReadDouble(p + 308);

                        SensorInfo s;
                        sensorMap.TryGetValue(sensorIndex, out s);

                        result.Readings.Add(new ReadingInfo {
                            SensorIndex = sensorIndex,
                            ReadingId = readingId,
                            Type = type,
                            Sensor = s == null ? ("Sensor " + sensorIndex) : s.Name,
                            SensorOriginal = s == null ? "" : s.NameOriginal,
                            LabelOriginal = labelOrig,
                            Label = Prefer(labelUser, labelOrig),
                            Unit = unit,
                            Value = SafeDouble(value),
                            Min = SafeDouble(min),
                            Max = SafeDouble(max),
                            Avg = SafeDouble(avg)
                        });
                    }

                    result.Ok = true;
                    return result;
                }
            }
            catch (Exception ex)
            {
                result.Ok = false;
                result.Error = ex.Message;
                return result;
            }
            finally
            {
                if (locked && mutex != null)
                {
                    try { mutex.ReleaseMutex(); } catch { }
                }
                if (mutex != null) mutex.Dispose();
            }
        }
    }
}
"@

try {
    Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
}
catch {
    Write-Host "Unable to initialise HWiNFO reader:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# -----------------------------
# Dashboard
# -----------------------------
$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HWiNFO Live Remote</title>
<style>
:root{
  color-scheme:dark;
  --bg:#090c11;--panel:#101620;--panel2:#151d29;--line:#222e3d;
  --text:#edf2f8;--muted:#8795aa;--good:#8ee6a8;--warn:#ffd37a;
  font-family:Inter,Segoe UI,system-ui,Arial,sans-serif
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text)}
.wrap{max-width:1700px;margin:auto;padding:20px}
header{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;margin-bottom:14px}
h1{margin:0;font-size:23px;letter-spacing:-.02em}
.sub{font-size:12px;color:var(--muted);margin-top:5px}
.status{font-size:12px;padding:7px 11px;border-radius:999px;background:var(--panel2);white-space:nowrap}
.toolbar{position:sticky;top:0;z-index:5;background:rgba(9,12,17,.94);backdrop-filter:blur(10px);
 display:flex;gap:8px;align-items:center;padding:10px 0 14px}
input{width:min(600px,100%);background:var(--panel);border:1px solid var(--line);
 color:var(--text);border-radius:10px;padding:10px 12px;outline:none}
button{border:1px solid var(--line);background:var(--panel);color:var(--text);
 border-radius:9px;padding:9px 11px;cursor:pointer}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px;margin-bottom:13px}
.stat{padding:12px;background:var(--panel);border:1px solid var(--line);border-radius:12px}
.stat .k{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.stat .v{font-size:20px;font-weight:700;margin-top:4px}
.err{background:#2a161b;border:1px solid #65303a;padding:14px;border-radius:12px;margin-bottom:12px}
.sensor{background:var(--panel);border:1px solid var(--line);border-radius:13px;margin:9px 0;overflow:hidden}
.sensor-head{display:flex;justify-content:space-between;align-items:center;padding:11px 13px;background:var(--panel2);cursor:pointer}
.sensor-title{font-weight:650;font-size:14px}.count{font-size:11px;color:var(--muted)}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{text-align:right;padding:7px 11px;border-top:1px solid #1d2734;font-variant-numeric:tabular-nums}
th{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;background:#0e141d}
th:first-child,td:first-child{text-align:left;width:44%}
td:first-child{color:#c7d0dd}
.unit{color:var(--muted);font-size:10px;margin-left:3px}
.hidden{display:none}
.empty{padding:30px;color:var(--muted);text-align:center}
.hot{color:var(--warn)}
@media(max-width:720px){
  .wrap{padding:12px} header{flex-direction:column}
  th:nth-child(3),td:nth-child(3),th:nth-child(4),td:nth-child(4),th:nth-child(5),td:nth-child(5){display:none}
}
</style>
</head>
<body>
<div class="wrap">
<header>
  <div>
    <h1>HWiNFO Live Remote</h1>
    <div class="sub" id="meta">Waiting for HWiNFO shared memory…</div>
  </div>
  <div class="status" id="status">CONNECTING</div>
</header>

<div class="toolbar">
  <input id="q" placeholder="Search everything — GPU, CPU, temperature, FPS, clock, SSD…">
  <button id="expand">Expand all</button>
</div>

<div id="error"></div>
<div class="stats">
  <div class="stat"><div class="k">Sensor groups</div><div class="v" id="sensorCount">—</div></div>
  <div class="stat"><div class="k">Live readings</div><div class="v" id="readingCount">—</div></div>
  <div class="stat"><div class="k">Poll interval</div><div class="v" id="poll">—</div></div>
  <div class="stat"><div class="k">FPS</div><div class="v" id="fps">—</div></div>
  <div class="stat"><div class="k">GPU load</div><div class="v" id="gpu">—</div></div>
  <div class="stat"><div class="k">CPU total</div><div class="v" id="cpu">—</div></div>
</div>

<div id="list"></div>
</div>

<script>
let latest=null;
let collapsed=new Set();
let manualExpand=false;
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const fmt=(n,u)=>{
 if(n===null||n===undefined||Number.isNaN(n)) return '—';
 let d=Math.abs(n)>=1000?0:(Math.abs(n)>=100?1:2);
 return `${Number(n).toFixed(d)}${u?` <span class="unit">${esc(u)}</span>`:''}`;
};
const txt=x=>`${x.Sensor||''} ${x.SensorOriginal||''} ${x.Label||''} ${x.LabelOriginal||''} ${x.Unit||''}`.toLowerCase();

function pick(readings, regexes){
 for(const re of regexes){
   const x=readings.find(r=>re.test(`${r.Sensor} ${r.Label}`));
   if(x) return x;
 }
 return null;
}

function render(){
 if(!latest) return;
 const d=latest;
 const e=document.getElementById('error');
 if(!d.Ok){
   e.innerHTML=`<div class="err">${esc(d.Error||'HWiNFO data unavailable')}</div>`;
   document.getElementById('status').textContent='NO DATA';
   return;
 }
 e.innerHTML='';
 document.getElementById('status').textContent='LIVE';
 document.getElementById('sensorCount').textContent=d.Sensors.length;
 document.getElementById('readingCount').textContent=d.Readings.length;
 document.getElementById('poll').textContent=d.PollingPeriodMs?`${d.PollingPeriodMs} ms`:'—';
 document.getElementById('meta').textContent=`Shared Memory v${d.Version}, revision ${d.Revision} • ${new Date(d.Timestamp).toLocaleTimeString()}`;

 const fps=pick(d.Readings,[/presentmon.*framerate presented.*avg/i,/framerate presented.*avg/i,/framerate presented/i]);
 const gpu=pick(d.Readings,[/gpu.*gpu core load/i,/gpu core load/i,/gpu utilization/i]);
 const cpu=pick(d.Readings,[/total cpu usage/i,/cpu total/i]);
 document.getElementById('fps').innerHTML=fps?fmt(fps.Value,fps.Unit):'—';
 document.getElementById('gpu').innerHTML=gpu?fmt(gpu.Value,gpu.Unit):'—';
 document.getElementById('cpu').innerHTML=cpu?fmt(cpu.Value,cpu.Unit):'—';

 const q=document.getElementById('q').value.trim().toLowerCase();
 const grouped=new Map();
 for(const r of d.Readings){
   if(q && !txt(r).includes(q)) continue;
   const k=r.Sensor||`Sensor ${r.SensorIndex}`;
   if(!grouped.has(k)) grouped.set(k,[]);
   grouped.get(k).push(r);
 }

 let html='';
 for(const [name,rows] of grouped){
   const key=name;
   const isCollapsed=!manualExpand && collapsed.has(key);
   html+=`<section class="sensor" data-key="${esc(key)}">
     <div class="sensor-head" onclick="toggleGroup(this)">
       <div class="sensor-title">${esc(name)}</div>
       <div class="count">${rows.length} readings ${isCollapsed?'▸':'▾'}</div>
     </div>
     <div class="sensor-body ${isCollapsed?'hidden':''}">
       <table>
         <thead><tr><th>Reading</th><th>Current</th><th>Minimum</th><th>Maximum</th><th>Average</th></tr></thead>
         <tbody>
         ${rows.map(r=>`<tr>
           <td title="${esc(r.LabelOriginal||'')}">${esc(r.Label)}</td>
           <td>${fmt(r.Value,r.Unit)}</td>
           <td>${fmt(r.Min,r.Unit)}</td>
           <td>${fmt(r.Max,r.Unit)}</td>
           <td>${fmt(r.Avg,r.Unit)}</td>
         </tr>`).join('')}
         </tbody>
       </table>
     </div>
   </section>`;
 }
 document.getElementById('list').innerHTML=html||'<div class="empty">No readings match the filter.</div>';
}

window.toggleGroup=function(el){
 const section=el.closest('.sensor');
 const key=section.dataset.key;
 const body=section.querySelector('.sensor-body');
 const c=section.querySelector('.count');
 if(body.classList.contains('hidden')){
   body.classList.remove('hidden'); collapsed.delete(key);
 }else{
   body.classList.add('hidden'); collapsed.add(key);
 }
 manualExpand=false;
 render();
};

document.getElementById('q').addEventListener('input',render);
document.getElementById('expand').addEventListener('click',()=>{
 collapsed.clear(); manualExpand=true; render();
 setTimeout(()=>manualExpand=false,50);
});

async function update(){
 try{
   const r=await fetch('/api/sensors',{cache:'no-store'});
   latest=await r.json();
   render();
 }catch(err){
   document.getElementById('status').textContent='OFFLINE';
   document.getElementById('error').innerHTML=`<div class="err">${esc(err.message)}</div>`;
 }
}
update();
setInterval(update,1000);
</script>
</body>
</html>
'@

function Send-Response {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$Code,
        [string]$Type,
        [string]$Body
    )
    $status = if ($Code -eq 200) { "OK" } else { "Not Found" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $headers = "HTTP/1.1 $Code $status`r`n" +
               "Content-Type: $Type; charset=utf-8`r`n" +
               "Content-Length: $($bytes.Length)`r`n" +
               "Cache-Control: no-store`r`n" +
               "Access-Control-Allow-Origin: *`r`n" +
               "Connection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($hb, 0, $hb.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Get-SnapshotJson {
    $snap = [HwInfoWeb.Reader]::Read()
    return ($snap | ConvertTo-Json -Depth 7 -Compress)
}

# Bind a dual-stack socket so clients resolving "localhost" to either
# 127.0.0.1 (IPv4) or ::1 (IPv6) can reach us. We still reject any
# non-loopback client below, so the bridge itself is not exposed to the LAN.
$listener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::IPv6Any, $Port
)
$listener.Server.DualMode = $true

function Test-IsLoopbackAddress {
    param([System.Net.IPAddress]$Address)

    if ([System.Net.IPAddress]::IsLoopback($Address)) { return $true }

    if ($Address.IsIPv4MappedToIPv6) {
        return [System.Net.IPAddress]::IsLoopback($Address.MapToIPv4())
    }

    return $false
}

try {
    $listener.Start()
}
catch {
    Write-Host ""
    Write-Host "Cannot listen on localhost:$Port (IPv4/IPv6 dual stack)" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "If another app uses 8080, run:" -ForegroundColor Yellow
    Write-Host "powershell -ExecutionPolicy Bypass -File .\hwinfo-all-web.ps1 -Port 8081"
    exit 1
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor DarkGray
Write-Host " HWiNFO ALL-SENSORS WEB BRIDGE" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Local dashboard : http://localhost:$Port/  (127.0.0.1 + ::1)" -ForegroundColor Cyan
Write-Host "JSON API       : http://127.0.0.1:$Port/api/sensors" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "Then expose it with:" -ForegroundColor Yellow
Write-Host "  tmole.exe $Port" -ForegroundColor White
Write-Host ""
Write-Host "Requirements:" -ForegroundColor DarkGray
Write-Host "  - HWiNFO Sensors window must be running"
Write-Host "  - HWiNFO Shared Memory Support must be enabled"
Write-Host ""
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $remote = $client.Client.RemoteEndPoint
            if ($remote -is [System.Net.IPEndPoint]) {
                if (-not (Test-IsLoopbackAddress $remote.Address)) {
                    $client.Close()
                    continue
                }
            }

            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader(
                $stream, [System.Text.Encoding]::ASCII, $false, 4096, $true
            )

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }

            while ($true) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($line)) { break }
            }

            $parts = $requestLine.Split(' ')
            $path = if ($parts.Length -ge 2) { $parts[1].Split('?')[0] } else { "/" }

            switch ($path) {
                "/" {
                    Send-Response $stream 200 "text/html" $html
                }
                "/index.html" {
                    Send-Response $stream 200 "text/html" $html
                }
                "/api/sensors" {
                    Send-Response $stream 200 "application/json" (Get-SnapshotJson)
                }
                "/health" {
                    Send-Response $stream 200 "text/plain" "ok"
                }
                default {
                    Send-Response $stream 404 "text/plain" "Not found"
                }
            }
        }
        catch {
            # A browser/tunnel disconnect must not stop the server.
        }
        finally {
            if ($client) { $client.Close() }
        }
    }
}
finally {
    $listener.Stop()
}
