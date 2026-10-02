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
<title>HWiNFO Performance Lab</title>
<style>
:root{
  color-scheme:dark;
  --bg:#070a0f;--panel:#0e141d;--panel2:#121a26;--panel3:#182333;
  --line:#223043;--line-soft:#192534;--text:#eef4fb;--muted:#8392a8;
  --accent:#6ea8ff;--accent2:#8bc1ff;--good:#74d49a;--warn:#efc56c;--bad:#ee7a86;
  --shadow:0 12px 35px rgba(0,0,0,.20);
  font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Arial,sans-serif;
}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);min-height:100%}
body{min-height:100vh}
button,input,select{font:inherit}
button,select,input[type="text"]{
  background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:9px;
}
button{cursor:pointer;padding:8px 11px;min-height:36px}
button:hover{background:var(--panel2)}
button.primary{background:#162642;border-color:#315682}
button.danger{border-color:#63343d}
button.ghost{background:transparent}
button:disabled{opacity:.45;cursor:not-allowed}
select{padding:7px 9px;min-height:36px}
input[type="text"]{padding:8px 11px;min-height:36px;outline:none}
.wrap{max-width:1900px;margin:auto;padding:18px 20px 34px}
header{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;margin-bottom:12px}
.brand h1{font-size:23px;margin:0;letter-spacing:-.035em}.brand p{font-size:12px;color:var(--muted);margin:5px 0 0}
.livebox{display:flex;align-items:center;gap:8px;flex-wrap:wrap;justify-content:flex-end}
.badge{font-size:10px;font-weight:800;letter-spacing:.09em;border:1px solid var(--line);padding:7px 9px;border-radius:999px;background:var(--panel2)}
.badge.live{color:var(--good)}.badge.stale{color:var(--warn)}.badge.offline{color:var(--bad)}
.age{font-size:11px;color:var(--muted)}
.toolbar{position:sticky;top:0;z-index:40;background:rgba(7,10,15,.94);backdrop-filter:blur(14px);padding:9px 0 11px;border-bottom:1px solid rgba(34,48,67,.45);margin-bottom:12px}
.toolbar-row{display:flex;gap:7px;align-items:center;flex-wrap:wrap}.toolbar-row+.toolbar-row{margin-top:7px}
.search{flex:1;min-width:250px}.spacer{flex:1}
.sep{height:24px;width:1px;background:var(--line);margin:0 2px}.label-mini{font-size:10px;color:var(--muted)}
.err{background:#2c161c;border:1px solid #62313b;color:#f2c3cb;padding:12px 13px;border-radius:11px;margin-bottom:11px}
.sessionbar{display:flex;gap:13px;align-items:center;flex-wrap:wrap;color:var(--muted);font-size:10px;margin:10px 0}
.sessionbar strong{color:#c9d3e0;font-weight:650}.dot{width:5px;height:5px;border-radius:99px;background:var(--line);display:inline-block}
.overview{display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:8px;margin:9px 0 16px}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:11px 12px;box-shadow:var(--shadow)}
.kpi .k{font-size:9px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.kpi .v{font-size:21px;font-weight:780;letter-spacing:-.025em;margin-top:5px;font-variant-numeric:tabular-nums}
.kpi .s{font-size:9px;color:var(--muted);margin-top:2px}
.sectionhead{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;margin:20px 0 8px}
.sectionhead h2{font-size:14px;margin:0}.sectionhead p{font-size:10px;color:var(--muted);margin:3px 0 0}
.global-card-controls{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
.dropzone{border:1px dashed #304761;border-radius:13px;padding:11px;text-align:center;color:var(--muted);font-size:10px;margin-bottom:9px;transition:.15s background,.15s border}
.dropzone.dragover{background:#101e31;border-color:#6ea8ff;color:#cfe3ff}
.pingrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:10px}
.pin-card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:var(--shadow);min-width:0;transition:.15s border,.15s transform}
.pin-card.dragging{opacity:.55}.pin-card.drag-target{border-color:var(--accent);transform:translateY(-2px)}
.pin-head{display:flex;align-items:flex-start;justify-content:space-between;gap:9px;padding:10px 11px 7px}
.pin-left{display:flex;gap:8px;align-items:flex-start;min-width:0}.draghandle{font-size:16px;line-height:1;color:#68798f;cursor:grab;padding-top:2px;user-select:none}
.pin-title{min-width:0}.pin-title .l{font-size:12px;font-weight:750;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.pin-title .g{font-size:9px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.pin-actions{display:flex;gap:4px}.iconbtn{padding:4px 7px;min-height:27px;font-size:10px;border-radius:7px}
.pin-primary{display:flex;align-items:flex-end;justify-content:space-between;gap:8px;padding:0 11px 9px}
.big{font-size:29px;font-weight:800;letter-spacing:-.035em;font-variant-numeric:tabular-nums}.smallmode{font-size:9px;color:var(--muted);margin-top:2px}
.statgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:var(--line-soft);border-top:1px solid var(--line-soft);border-bottom:1px solid var(--line-soft)}
.sbox{background:var(--panel);padding:6px 7px;min-width:0}.sbox .k{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}.sbox .v{font-size:11px;font-weight:650;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.chartbox{height:126px;position:relative;padding:6px 8px 8px;touch-action:none}
.chartbox canvas{width:100%;height:100%;display:block}
.chart-legend{position:absolute;left:10px;bottom:7px;font-size:8px;color:var(--muted);pointer-events:none}
.chart-tooltip{position:fixed;z-index:100;display:none;pointer-events:none;background:#0a1019;border:1px solid #31445e;border-radius:8px;padding:7px 8px;box-shadow:0 10px 30px rgba(0,0,0,.35);font-size:10px;line-height:1.4;min-width:118px}
.chart-tooltip .time{color:var(--muted)}.chart-tooltip .val{font-size:13px;font-weight:750;margin-top:2px}
.pin-foot{display:flex;align-items:center;gap:6px;flex-wrap:wrap;padding:7px 9px;border-top:1px solid var(--line-soft)}
.pin-foot select{font-size:9px;min-height:29px;padding:4px 6px}.check{font-size:9px;color:var(--muted);display:flex;gap:4px;align-items:center}.check input{margin:0}
.empty{border:1px dashed var(--line);border-radius:12px;padding:20px;text-align:center;color:var(--muted);font-size:11px}
.fpsgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:8px}
.metric{background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:10px}.metric .k{font-size:9px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}.metric .v{font-size:18px;font-weight:760;margin-top:4px;font-variant-numeric:tabular-nums}.metric .d{font-size:8px;color:var(--muted);margin-top:3px;line-height:1.35}
.groups{display:grid;gap:7px}.group{background:var(--panel);border:1px solid var(--line);border-radius:11px;overflow:hidden}
.group-head{display:flex;justify-content:space-between;align-items:center;gap:8px;background:var(--panel2);padding:9px 11px;cursor:pointer}.group-name{font-size:11px;font-weight:700}.group-count{font-size:9px;color:var(--muted)}
table{border-collapse:collapse;width:100%;font-size:10px}th,td{padding:6px 8px;border-top:1px solid var(--line-soft);text-align:right;font-variant-numeric:tabular-nums}th{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em;background:#0c121a}th:first-child,td:first-child{text-align:center;width:30px}th:nth-child(2),td:nth-child(2){text-align:left;width:43%}.sensorlabel{color:#c8d3e0}.star{background:transparent;border:0;min-height:0;padding:1px 3px;font-size:14px;opacity:.55}.star.on{opacity:1}.sensor-row{cursor:grab}.sensor-row.dragging{opacity:.45}
.hidden{display:none!important}
.flash{animation:flash .38s ease}@keyframes flash{0%{box-shadow:0 0 0 0 rgba(110,168,255,.45)}100%{box-shadow:0 0 0 10px rgba(110,168,255,0)}}
@media(max-width:800px){.wrap{padding:11px}.pingrid{grid-template-columns:1fr}.statgrid{grid-template-columns:repeat(2,1fr)}header{flex-direction:column}.livebox{justify-content:flex-start}.sep{display:none}th:nth-child(n+4),td:nth-child(n+4){display:none}}
</style>
</head>
<body>
<div class="wrap">
<header>
 <div class="brand"><h1>HWiNFO Performance Lab</h1><p id="meta">Connecting to HWiNFO shared memory…</p></div>
 <div class="livebox"><span class="badge" id="status">CONNECTING</span><span class="age" id="age">—</span></div>
</header>

<div class="toolbar">
 <div class="toolbar-row">
  <input class="search" type="text" id="search" placeholder="Search all readings — GPU, CPU, PresentMon, VRAM, SSD, temperature…">
  <span class="label-mini">Graph</span>
  <select id="window"><option value="60">60 s</option><option value="300" selected>5 min</option><option value="900">15 min</option><option value="1800">30 min</option><option value="3600">60 min</option></select>
  <span class="label-mini">Browser poll</span>
  <select id="clientPoll"><option value="250">250 ms</option><option value="500" selected>500 ms</option><option value="1000">1 s</option><option value="2000">2 s</option></select>
  <button class="primary" id="essentials">Pin essentials</button>
  <button id="pause">Pause</button>
  <button class="danger" id="reset">Reset session</button>
  <button id="export">Export CSV</button>
 </div>
 <div class="toolbar-row">
  <span class="label-mini">All sensor groups</span>
  <button id="expandAll">Expand</button><button id="collapseAll">Collapse</button>
  <span class="sep"></span>
  <span class="label-mini">All pinned cards</span>
  <button id="graphsOn">Graphs on</button><button id="graphsOff">Graphs off</button>
  <select id="globalMode"><option value="all">Show all stats</option><option value="current">Current only</option><option value="min">Session min</option><option value="avg">Session average</option><option value="max">Session max</option></select>
  <button id="applyMode">Apply mode</button>
  <span class="spacer"></span>
  <button class="danger" id="clearPins">Clear pins</button>
 </div>
</div>

<div id="error"></div>
<div class="sessionbar">
 <span>Session <strong id="elapsed">00:00</strong></span><span class="dot"></span>
 <span>Client samples <strong id="sampleCount">0</strong></span><span class="dot"></span>
 <span>HWiNFO poll <strong id="sourcePoll">—</strong></span><span class="dot"></span>
 <span>Last source update <strong id="sourceUpdate">—</strong></span>
</div>

<div class="overview">
 <div class="kpi"><div class="k">FPS</div><div class="v" id="ovFps">—</div><div class="s">PresentMon</div></div>
 <div class="kpi"><div class="k">Frame time</div><div class="v" id="ovFt">—</div><div class="s">PresentMon</div></div>
 <div class="kpi"><div class="k">GPU load</div><div class="v" id="ovGpu">—</div><div class="s">core load</div></div>
 <div class="kpi"><div class="k">GPU temp</div><div class="v" id="ovGt">—</div><div class="s">current</div></div>
 <div class="kpi"><div class="k">CPU total</div><div class="v" id="ovCpu">—</div><div class="s">usage</div></div>
 <div class="kpi"><div class="k">CPU temp</div><div class="v" id="ovCt">—</div><div class="s">package / Tctl</div></div>
</div>

<div class="sectionhead"><div><h2>Pinned telemetry</h2><p>Drag cards to reorder. Drag any row from the sensor list into this area to pin it.</p></div></div>
<div class="dropzone" id="dropzone">Drop a sensor here to pin it • pin order is saved in this browser</div>
<div id="pinHost" class="pingrid"></div>

<div class="sectionhead"><div><h2>FPS session analysis</h2><p>Based on HWiNFO polling samples. For exact per-frame 1% / 0.1% lows we would integrate raw PresentMon next.</p></div></div>
<div class="fpsgrid">
 <div class="metric"><div class="k">Average FPS</div><div class="v" id="fpsAvg">—</div><div class="d">Session sample average</div></div>
 <div class="metric"><div class="k">Sampled P5 FPS</div><div class="v" id="fpsP5">—</div><div class="d">5th percentile</div></div>
 <div class="metric"><div class="k">Sampled P1 FPS</div><div class="v" id="fpsP1">—</div><div class="d">1st percentile</div></div>
 <div class="metric"><div class="k">Sampled P0.1 FPS</div><div class="v" id="fpsP01">—</div><div class="d">Needs a long run</div></div>
 <div class="metric"><div class="k">FPS range</div><div class="v" id="fpsRange">—</div><div class="d">Session min / max</div></div>
 <div class="metric"><div class="k">Frame-time P95</div><div class="v" id="ftP95">—</div><div class="d">Sample percentile</div></div>
 <div class="metric"><div class="k">Frame-time P99</div><div class="v" id="ftP99">—</div><div class="d">Sample percentile</div></div>
 <div class="metric"><div class="k">Frame-time max</div><div class="v" id="ftMax">—</div><div class="d">Largest sampled value</div></div>
</div>

<div class="sectionhead">
 <div><h2>All HWiNFO sensors</h2><p>Current cells update in place — opening a dropdown or selecting text is no longer interrupted by refreshes.</p></div>
</div>
<div id="groups" class="groups"></div>
</div>
<div class="chart-tooltip" id="tooltip"><div class="time"></div><div class="val"></div></div>

<script>
'use strict';
const S={
 latest:null, paused:false, inFlight:false, pollTimer:null, lastFetchAt:0, lastSourcePoll:0,
 sessionStart:Date.now(), samples:0, histories:new Map(), collapsed:new Set(),
 topology:'', fpsKey:null, ftKey:null, draggingKey:null, hoverCharts:new Map(),
 pins:JSON.parse(localStorage.getItem('hpl-v4-pins')||'[]'),
 opts:JSON.parse(localStorage.getItem('hpl-v4-opts')||'{}')
};
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const keyOf=r=>`${r.SensorIndex}:${r.ReadingId}`;
const finite=v=>v!==null&&v!==undefined&&Number.isFinite(Number(v));
const n=v=>finite(v)?Number(v):null;
const textOf=r=>`${r.Sensor||''} ${r.SensorOriginal||''} ${r.Label||''} ${r.LabelOriginal||''} ${r.Unit||''}`.toLowerCase();
const save=()=>{localStorage.setItem('hpl-v4-pins',JSON.stringify(S.pins));localStorage.setItem('hpl-v4-opts',JSON.stringify(S.opts));};
function fmt(v,u,short=false){v=n(v);if(v===null)return '—';let d=Math.abs(v)>=1000?0:Math.abs(v)>=100?1:2;if(short&&Math.abs(v)>=100)d=0;return `${v.toFixed(d)}${u?' '+u:''}`}
function qtile(values,q){const a=values.filter(Number.isFinite).slice().sort((a,b)=>a-b);if(!a.length)return null;if(a.length===1)return a[0];const p=(a.length-1)*q,lo=Math.floor(p),hi=Math.ceil(p);return a[lo]+(a[hi]-a[lo])*(p-lo)}
function calc(a){const v=(a||[]).map(x=>x.v).filter(Number.isFinite);if(!v.length)return{cur:null,min:null,max:null,avg:null,count:0};return{cur:v[v.length-1],min:Math.min(...v),max:Math.max(...v),avg:v.reduce((x,y)=>x+y,0)/v.length,count:v.length}}
function reading(k){return S.latest?.Readings?.find(r=>keyOf(r)===k)||null}
function find(regexes){if(!S.latest?.Ok)return null;for(const re of regexes){const r=S.latest.Readings.find(x=>re.test(`${x.Sensor||''} ${x.Label||''}`));if(r)return r}return null}
function sourceAgeMs(){if(!S.latest?.PollTimeUnix)return null;return Math.max(0,Date.now()-Number(S.latest.PollTimeUnix)*1000)}

function ensureOpt(k){if(!S.opts[k])S.opts[k]={mode:'all',graph:true,smooth:false};return S.opts[k]}
function pin(k,index=null){if(!k||S.pins.includes(k))return;ensureOpt(k);if(index===null||index<0||index>S.pins.length)S.pins.push(k);else S.pins.splice(index,0,k);save();syncPinsStructure();syncGroupStars();updateDynamic()}
function unpin(k){S.pins=S.pins.filter(x=>x!==k);save();syncPinsStructure();syncGroupStars();updateDynamic()}
function reorder(k,beforeKey=null){const old=S.pins.indexOf(k);if(old>=0)S.pins.splice(old,1);if(beforeKey&&S.pins.includes(beforeKey))S.pins.splice(S.pins.indexOf(beforeKey),0,k);else S.pins.push(k);save();syncPinsStructure();updateDynamic()}
function setOpt(k,key,val){ensureOpt(k)[key]=val;save();const card=document.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`);if(card){applyCardPresentation(card,k);drawOneCard(card,k)}}

function addSample(k,val){val=n(val);if(val===null)return;if(!S.histories.has(k))S.histories.set(k,[]);const a=S.histories.get(k),now=Date.now();a.push({t:now,v:val});const keep=3600e3;while(a.length&&now-a[0].t>keep)a.shift()}
function sample(){if(!S.latest?.Ok||S.paused)return;S.samples++;const fps=find([/presentmon.*framerate presented.*avg/i,/framerate presented.*avg/i,/framerate presented/i]);const ft=find([/presentmon.*frame time/i,/frame time/i]);if(fps){S.fpsKey=keyOf(fps);addSample(S.fpsKey,fps.Value)}if(ft){S.ftKey=keyOf(ft);addSample(S.ftKey,ft.Value)}for(const k of S.pins){if(k===S.fpsKey||k===S.ftKey)continue;const r=reading(k);if(r)addSample(k,r.Value)}}

function topologySignature(){if(!S.latest?.Ok)return '';return S.latest.Readings.map(r=>`${keyOf(r)}|${r.Sensor}|${r.Label}|${r.Unit}`).join('~')}
function renderGroupsStructure(force=false){if(!S.latest?.Ok)return;const sig=topologySignature();const q=$('search').value.trim().toLowerCase();const fullSig=sig+'|q='+q;if(!force&&S.topology===fullSig)return;S.topology=fullSig;const grouped=new Map();for(const r of S.latest.Readings){if(q&&!textOf(r).includes(q))continue;const g=r.Sensor||`Sensor ${r.SensorIndex}`;(grouped.get(g)||grouped.set(g,[]).get(g)).push(r)}let html='';for(const [g,rows] of grouped){const closed=S.collapsed.has(g);html+=`<section class="group" data-group="${esc(g)}"><div class="group-head"><div class="group-name">${esc(g)}</div><div class="group-count">${rows.length} readings <span class="chev">${closed?'▸':'▾'}</span></div></div><div class="group-body ${closed?'hidden':''}"><table><thead><tr><th>Pin</th><th>Reading</th><th>Current</th><th>HWiNFO min</th><th>HWiNFO max</th><th>HWiNFO avg</th></tr></thead><tbody>${rows.map(r=>{const k=keyOf(r);return `<tr class="sensor-row" draggable="true" data-key="${k}"><td><button class="star ${S.pins.includes(k)?'on':''}" data-star="${k}">${S.pins.includes(k)?'★':'☆'}</button></td><td class="sensorlabel">${esc(r.Label)}</td><td data-cell="value" data-key="${k}">—</td><td data-cell="min" data-key="${k}">—</td><td data-cell="max" data-key="${k}">—</td><td data-cell="avg" data-key="${k}">—</td></tr>`}).join('')}</tbody></table></div></section>`} $('groups').innerHTML=html||'<div class="empty">No readings match the current search.</div>';bindGroupEvents();updateSensorCells()}
function bindGroupEvents(){document.querySelectorAll('.group-head').forEach(h=>h.onclick=()=>{const g=h.closest('.group'),name=g.dataset.group,body=g.querySelector('.group-body'),chev=g.querySelector('.chev');if(body.classList.toggle('hidden')){S.collapsed.add(name);chev.textContent='▸'}else{S.collapsed.delete(name);chev.textContent='▾'}});document.querySelectorAll('.star').forEach(b=>b.onclick=e=>{e.stopPropagation();const k=b.dataset.star;S.pins.includes(k)?unpin(k):pin(k)});document.querySelectorAll('.sensor-row').forEach(row=>{row.ondragstart=e=>{S.draggingKey=row.dataset.key;row.classList.add('dragging');e.dataTransfer.effectAllowed='copyMove';e.dataTransfer.setData('text/plain',S.draggingKey)};row.ondragend=()=>{row.classList.remove('dragging');S.draggingKey=null}})}
function syncGroupStars(){document.querySelectorAll('[data-star]').forEach(b=>{const on=S.pins.includes(b.dataset.star);b.classList.toggle('on',on);b.textContent=on?'★':'☆'})}
function updateSensorCells(){if(!S.latest?.Ok)return;for(const r of S.latest.Readings){const k=keyOf(r);for(const [field,val] of [['value',r.Value],['min',r.Min],['max',r.Max],['avg',r.Avg]]){const el=document.querySelector(`[data-cell="${field}"][data-key="${CSS.escape(k)}"]`);if(el)el.textContent=fmt(val,r.Unit)}}}

function cardHtml(k,r){const o=ensureOpt(k);return `<article class="pin-card" draggable="true" data-key="${k}"><div class="pin-head"><div class="pin-left"><div class="draghandle" title="Drag to reorder">⋮⋮</div><div class="pin-title"><div class="l">${esc(r.Label)}</div><div class="g">${esc(r.Sensor)}</div></div></div><div class="pin-actions"><button class="iconbtn" data-unpin="${k}">Unpin</button></div></div><div class="pin-primary"><div><div class="big" data-pin-primary="${k}">—</div><div class="smallmode" data-pin-mode-label="${k}">Current</div></div></div><div class="statgrid" data-statgrid="${k}"><div class="sbox"><div class="k">Current</div><div class="v" data-pin-stat="cur" data-key="${k}">—</div></div><div class="sbox"><div class="k">Session min</div><div class="v" data-pin-stat="min" data-key="${k}">—</div></div><div class="sbox"><div class="k">Session avg</div><div class="v" data-pin-stat="avg" data-key="${k}">—</div></div><div class="sbox"><div class="k">Session max</div><div class="v" data-pin-stat="max" data-key="${k}">—</div></div></div><div class="chartbox" data-chartbox="${k}"><canvas data-chart="${k}"></canvas><div class="chart-legend" data-chartlegend="${k}">0 samples</div></div><div class="pin-foot"><select data-mode="${k}"><option value="all">All stats</option><option value="current">Current</option><option value="min">Session min</option><option value="avg">Session average</option><option value="max">Session max</option></select><label class="check"><input type="checkbox" data-graph="${k}"> graph</label><label class="check"><input type="checkbox" data-smooth="${k}"> 5s avg</label></div></article>`}
function syncPinsStructure(){const host=$('pinHost');const valid=S.pins.filter(k=>reading(k));if(!valid.length){host.innerHTML='<div class="empty" style="grid-column:1/-1">Nothing pinned. Drag a sensor here, click ☆, or use <b>Pin essentials</b>.</div>';return}const existing=[...host.querySelectorAll('.pin-card')].map(x=>x.dataset.key);if(existing.join('|')===valid.join('|'))return;host.innerHTML=valid.map(k=>cardHtml(k,reading(k))).join('');bindPinEvents();for(const k of valid)applyCardPresentation(host.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`),k)}
function bindPinEvents(){document.querySelectorAll('.pin-card').forEach(card=>{const k=card.dataset.key;card.ondragstart=e=>{S.draggingKey=k;card.classList.add('dragging');e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',k)};card.ondragend=()=>{card.classList.remove('dragging');document.querySelectorAll('.drag-target').forEach(x=>x.classList.remove('drag-target'));S.draggingKey=null};card.ondragover=e=>{e.preventDefault();card.classList.add('drag-target');e.dataTransfer.dropEffect='move'};card.ondragleave=()=>card.classList.remove('drag-target');card.ondrop=e=>{e.preventDefault();e.stopPropagation();card.classList.remove('drag-target');const k2=e.dataTransfer.getData('text/plain')||S.draggingKey;if(!k2)return;if(!S.pins.includes(k2))pin(k2,S.pins.indexOf(k));else if(k2!==k)reorder(k2,k)};const sel=card.querySelector(`[data-mode="${CSS.escape(k)}"]`);sel.onchange=()=>setOpt(k,'mode',sel.value);const gr=card.querySelector(`[data-graph="${CSS.escape(k)}"]`);gr.onchange=()=>setOpt(k,'graph',gr.checked);const sm=card.querySelector(`[data-smooth="${CSS.escape(k)}"]`);sm.onchange=()=>setOpt(k,'smooth',sm.checked);const un=card.querySelector(`[data-unpin="${CSS.escape(k)}"]`);un.onclick=()=>unpin(k);const canvas=card.querySelector('canvas');bindChartHover(canvas,k)});}
function applyCardPresentation(card,k){if(!card)return;const o=ensureOpt(k);const sel=card.querySelector('[data-mode]');if(sel&&sel.value!==o.mode)sel.value=o.mode;const graph=card.querySelector('[data-graph]');if(graph)graph.checked=o.graph!==false;const smooth=card.querySelector('[data-smooth]');if(smooth)smooth.checked=!!o.smooth;card.querySelector('[data-statgrid]').classList.toggle('hidden',o.mode!=='all');card.querySelector('[data-chartbox]').classList.toggle('hidden',o.graph===false);const label=card.querySelector('[data-pin-mode-label]');label.textContent=o.mode==='current'?'Current':o.mode==='min'?'Session minimum':o.mode==='avg'?'Session average':o.mode==='max'?'Session maximum':'Current'}

function visibleHistory(k){const a=S.histories.get(k)||[],sec=Number($('window').value)||300,cut=Date.now()-sec*1000;return a.filter(p=>p.t>=cut&&Number.isFinite(p.v))}
function rolling(points,ms=5000){const out=[];let left=0,sum=0;for(let i=0;i<points.length;i++){sum+=points[i].v;while(points[i].t-points[left].t>ms){sum-=points[left].v;left++}out.push({t:points[i].t,v:sum/(i-left+1)})}return out}
function drawCanvas(canvas,k,hoverIndex=null){const r=reading(k);if(!r)return;const raw=visibleHistory(k),o=ensureOpt(k),pts=o.smooth?rolling(raw):raw;const box=canvas.getBoundingClientRect(),dpr=Math.max(1,window.devicePixelRatio||1),w=Math.max(1,Math.floor(box.width*dpr)),h=Math.max(1,Math.floor(box.height*dpr));if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h}const c=canvas.getContext('2d');c.clearRect(0,0,w,h);if(pts.length<2){S.hoverCharts.set(k,{pts:[],plot:null});return}let vals=pts.map(x=>x.v),lo=Math.min(...vals),hi=Math.max(...vals);if(lo===hi){lo-=1;hi+=1}const pad=(hi-lo)*.10;lo-=pad;hi+=pad;const L=5*dpr,T=5*dpr,R=w-5*dpr,B=h-13*dpr;c.lineWidth=1*dpr;c.strokeStyle='rgba(131,146,168,.15)';for(let i=0;i<4;i++){const y=T+(B-T)*i/3;c.beginPath();c.moveTo(L,y);c.lineTo(R,y);c.stroke()}const t0=pts[0].t,t1=pts.at(-1).t||t0+1;c.strokeStyle='rgba(110,168,255,.95)';c.lineWidth=1.6*dpr;c.beginPath();pts.forEach((p,i)=>{const x=L+(R-L)*(p.t-t0)/Math.max(1,t1-t0),y=B-(B-T)*(p.v-lo)/(hi-lo);i?c.lineTo(x,y):c.moveTo(x,y)});c.stroke();c.font=`${8*dpr}px Segoe UI`;c.fillStyle='rgba(131,146,168,.78)';c.fillText(fmt(hi,r.Unit,true),6*dpr,10*dpr);c.fillText(fmt(lo,r.Unit,true),6*dpr,h-2*dpr);if(hoverIndex!==null&&hoverIndex>=0&&hoverIndex<pts.length){const p=pts[hoverIndex],x=L+(R-L)*(p.t-t0)/Math.max(1,t1-t0),y=B-(B-T)*(p.v-lo)/(hi-lo);c.strokeStyle='rgba(238,244,251,.40)';c.lineWidth=1*dpr;c.beginPath();c.moveTo(x,T);c.lineTo(x,B);c.stroke();c.fillStyle='rgba(238,244,251,.95)';c.beginPath();c.arc(x,y,3*dpr,0,Math.PI*2);c.fill()}S.hoverCharts.set(k,{pts,plot:{L,R,T,B,t0,t1,lo,hi}})}
function bindChartHover(canvas,k){canvas.onpointermove=e=>{const meta=S.hoverCharts.get(k);if(!meta?.pts?.length||!meta.plot)return;const rect=canvas.getBoundingClientRect(),x=e.clientX-rect.left,ratio=Math.max(0,Math.min(1,x/Math.max(1,rect.width)));const target=meta.plot.t0+(meta.plot.t1-meta.plot.t0)*ratio;let best=0,bd=Infinity;meta.pts.forEach((p,i)=>{const d=Math.abs(p.t-target);if(d<bd){bd=d;best=i}});drawCanvas(canvas,k,best);const p=meta.pts[best],r=reading(k),tip=$('tooltip');tip.querySelector('.time').textContent=new Date(p.t).toLocaleTimeString();tip.querySelector('.val').textContent=fmt(p.v,r?.Unit||'');tip.style.display='block';let tx=e.clientX+12,ty=e.clientY+12;if(tx+150>innerWidth)tx=e.clientX-155;if(ty+70>innerHeight)ty=e.clientY-75;tip.style.left=tx+'px';tip.style.top=ty+'px'};canvas.onpointerleave=()=>{$('tooltip').style.display='none';drawCanvas(canvas,k,null)}}
function drawOneCard(card,k){const r=reading(k);if(!r)return;const st=calc(S.histories.get(k)||[]),o=ensureOpt(k);const primary=o.mode==='min'?st.min:o.mode==='avg'?st.avg:o.mode==='max'?st.max:r.Value;card.querySelector('[data-pin-primary]').textContent=fmt(primary,r.Unit);for(const [field,val] of [['cur',r.Value],['min',st.min],['avg',st.avg],['max',st.max]])card.querySelector(`[data-pin-stat="${field}"]`).textContent=fmt(val,r.Unit);card.querySelector('[data-chartlegend]').textContent=`${st.count} samples${o.smooth?' • 5s rolling average':''}`;if(o.graph!==false)drawCanvas(card.querySelector('canvas'),k,null)}
function updatePins(){syncPinsStructure();document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key))}

function updateOverview(){const fps=find([/presentmon.*framerate presented.*avg/i,/framerate presented.*avg/i,/framerate presented/i]),ft=find([/presentmon.*frame time/i,/frame time/i]),gpu=find([/gpu core load/i,/gpu utilization/i]),gt=find([/^gpu.*temperature/i]),cpu=find([/total cpu usage/i,/cpu total/i]),ct=find([/cpu \(tctl\/tdie\)/i,/cpu package.*temperature/i,/cpu.*temperature/i]);if(fps)S.fpsKey=keyOf(fps);if(ft)S.ftKey=keyOf(ft);for(const [id,r] of [['ovFps',fps],['ovFt',ft],['ovGpu',gpu],['ovGt',gt],['ovCpu',cpu],['ovCt',ct]])$(id).textContent=r?fmt(r.Value,r.Unit):'—'}
function updateFps(){const fv=(S.histories.get(S.fpsKey)||[]).map(x=>x.v).filter(Number.isFinite),tv=(S.histories.get(S.ftKey)||[]).map(x=>x.v).filter(Number.isFinite);const set=(id,x)=>$(id).textContent=x;if(fv.length){set('fpsAvg',fmt(fv.reduce((a,b)=>a+b,0)/fv.length,'FPS'));set('fpsP5',fv.length>=20?fmt(qtile(fv,.05),'FPS'):'collecting…');set('fpsP1',fv.length>=50?fmt(qtile(fv,.01),'FPS'):'collecting…');set('fpsP01',fv.length>=500?fmt(qtile(fv,.001),'FPS'):'collecting…');set('fpsRange',`${fmt(Math.min(...fv),'')} / ${fmt(Math.max(...fv),' FPS')}`)}else['fpsAvg','fpsP5','fpsP1','fpsP01','fpsRange'].forEach(id=>set(id,'—'));if(tv.length){set('ftP95',tv.length>=20?fmt(qtile(tv,.95),'ms'):'collecting…');set('ftP99',tv.length>=50?fmt(qtile(tv,.99),'ms'):'collecting…');set('ftMax',fmt(Math.max(...tv),'ms'))}else['ftP95','ftP99','ftMax'].forEach(id=>set(id,'—'))}
function updateStatus(){if(!S.latest?.Ok){$('status').className='badge offline';$('status').textContent='NO DATA';return}const age=sourceAgeMs();let cls='live',txt=S.paused?'PAUSED':'LIVE';if(age!==null&&age>Math.max(3000,(S.latest.PollingPeriodMs||1000)*3)){cls='stale';txt='SOURCE STALE'}$('status').className='badge '+cls;$('status').textContent=txt;$('age').textContent=S.lastFetchAt?`browser ${Math.round(Date.now()-S.lastFetchAt)} ms ago`:'—';$('sourcePoll').textContent=S.latest.PollingPeriodMs?`${S.latest.PollingPeriodMs} ms`:'—';$('sourceUpdate').textContent=age===null?'—':age<1500?'now':`${(age/1000).toFixed(1)} s ago`;if(age!==null&&age>3000)$('sourceUpdate').style.color='var(--warn)';else $('sourceUpdate').style.color=''}
function updateDynamic(){if(!S.latest?.Ok)return;updateOverview();updatePins();updateFps();updateSensorCells();updateStatus();$('sampleCount').textContent=S.samples}

async function fetchOnce(){if(S.paused||S.inFlight)return;S.inFlight=true;try{const ctl=new AbortController(),to=setTimeout(()=>ctl.abort(),4000);const res=await fetch(`/api/sensors?_=${Date.now()}`,{cache:'no-store',signal:ctl.signal});clearTimeout(to);if(!res.ok)throw new Error(`HTTP ${res.status}`);const data=await res.json();S.latest=data;S.lastFetchAt=Date.now();if(!data.Ok){$('error').innerHTML=`<div class="err">${esc(data.Error||'HWiNFO data unavailable')}</div>`;updateStatus();return}$('error').innerHTML='';sample();renderGroupsStructure(false);updateDynamic();$('meta').textContent=`${data.Readings.length} live readings • Shared Memory v${data.Version}.${data.Revision}`;}catch(e){$('error').innerHTML=`<div class="err">Dashboard polling error: ${esc(e.message)}. Local server may still be running.</div>`;$('status').className='badge offline';$('status').textContent='OFFLINE'}finally{S.inFlight=false}}
function schedulePoll(){clearTimeout(S.pollTimer);const delay=Number($('clientPoll').value)||500;S.pollTimer=setTimeout(async()=>{await fetchOnce();schedulePoll()},delay)}

function pinEssentials(){if(!S.latest?.Ok)return;const patterns=[/presentmon.*framerate presented.*avg/i,/presentmon.*frame time/i,/gpu core load/i,/^gpu.*temperature/i,/^gpu.*power/i,/gpu.*clock/i,/gpu memory.*allocated/i,/gpu memory usage/i,/total cpu usage/i,/cpu \(tctl\/tdie\)/i,/cpu package.*temperature/i,/cpu package power/i,/core effective clocks.*avg/i,/physical memory load/i];for(const re of patterns){const r=S.latest.Readings.find(x=>re.test(`${x.Sensor||''} ${x.Label||''}`));if(r&&!S.pins.includes(keyOf(r)))S.pins.push(keyOf(r))}save();syncPinsStructure();syncGroupStars();updateDynamic();$('dropzone').classList.add('flash');setTimeout(()=>$('dropzone').classList.remove('flash'),450)}
function collapseAll(collapse){document.querySelectorAll('.group').forEach(g=>{const name=g.dataset.group,body=g.querySelector('.group-body'),chev=g.querySelector('.chev');body.classList.toggle('hidden',collapse);chev.textContent=collapse?'▸':'▾';collapse?S.collapsed.add(name):S.collapsed.delete(name)})}
function applyAllGraphs(on){for(const k of S.pins){ensureOpt(k).graph=on}save();document.querySelectorAll('.pin-card').forEach(c=>{applyCardPresentation(c,c.dataset.key);drawOneCard(c,c.dataset.key)})}
function applyAllMode(){const mode=$('globalMode').value;for(const k of S.pins)ensureOpt(k).mode=mode;save();document.querySelectorAll('.pin-card').forEach(c=>{applyCardPresentation(c,c.dataset.key);drawOneCard(c,c.dataset.key)})}
function resetSession(){if(!confirm('Reset local session history, graphs, session min/max/average and sampled FPS percentiles? HWiNFO built-in statistics are left untouched.'))return;S.histories=new Map();S.samples=0;S.sessionStart=Date.now();$('sampleCount').textContent='0';updateDynamic()}
function clearPins(){if(!S.pins.length)return;if(!confirm('Remove all pinned cards?'))return;S.pins=[];save();syncPinsStructure();syncGroupStars()}
function exportCsv(){const keys=[...new Set([...S.pins,S.fpsKey,S.ftKey].filter(Boolean))];const rows=['timestamp,sensor,label,value,unit'];for(const k of keys){const r=reading(k);if(!r)continue;for(const p of S.histories.get(k)||[]){const q=s=>`"${String(s??'').replaceAll('"','""')}"`;rows.push([new Date(p.t).toISOString(),q(r.Sensor),q(r.Label),p.v,q(r.Unit)].join(','))}}const blob=new Blob([rows.join('\n')],{type:'text/csv'}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=`hwinfo-performance-${new Date().toISOString().replace(/[:.]/g,'-')}.csv`;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000)}

function bindGlobalDnD(){const dz=$('dropzone');for(const el of [dz,$('pinHost')]){el.ondragover=e=>{e.preventDefault();dz.classList.add('dragover');e.dataTransfer.dropEffect=S.pins.includes(S.draggingKey)?'move':'copy'};el.ondragleave=e=>{if(!dz.contains(e.relatedTarget))dz.classList.remove('dragover')};el.ondrop=e=>{e.preventDefault();dz.classList.remove('dragover');const k=e.dataTransfer.getData('text/plain')||S.draggingKey;if(!k)return;S.pins.includes(k)?reorder(k,null):pin(k)}}}

$('search').addEventListener('input',()=>renderGroupsStructure(true));
$('window').addEventListener('change',()=>document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key)));
$('clientPoll').addEventListener('change',schedulePoll);
$('essentials').onclick=pinEssentials;
$('pause').onclick=()=>{S.paused=!S.paused;$('pause').textContent=S.paused?'Resume':'Pause';updateStatus();if(!S.paused){fetchOnce();schedulePoll()}};
$('reset').onclick=resetSession;$('export').onclick=exportCsv;
$('expandAll').onclick=()=>collapseAll(false);$('collapseAll').onclick=()=>collapseAll(true);
$('graphsOn').onclick=()=>applyAllGraphs(true);$('graphsOff').onclick=()=>applyAllGraphs(false);
$('applyMode').onclick=applyAllMode;$('clearPins').onclick=clearPins;
bindGlobalDnD();
setInterval(()=>{const s=Math.floor((Date.now()-S.sessionStart)/1000),h=Math.floor(s/3600),m=Math.floor((s%3600)/60),ss=s%60;$('elapsed').textContent=h?`${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:${String(ss).padStart(2,'0')}`:`${String(m).padStart(2,'0')}:${String(ss).padStart(2,'0')}`;updateStatus()},500);
window.addEventListener('resize',()=>document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key)));
fetchOnce();schedulePoll();
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
Write-Host " HWiNFO PERFORMANCE LAB v4" -ForegroundColor Green
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
