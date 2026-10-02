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
  --bg:#080b10;--panel:#0f151f;--panel2:#141c28;--panel3:#192331;
  --line:#243143;--line2:#1c2735;--text:#eef3fa;--muted:#8796aa;
  --soft:#b6c2d2;--accent:#6ca7ff;--good:#75d59a;--warn:#f0c56e;--bad:#ef8080;
  font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Arial,sans-serif;
}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text)}
body{min-height:100vh}
.wrap{max-width:1800px;margin:auto;padding:20px}
header{display:flex;align-items:flex-start;justify-content:space-between;gap:20px;margin-bottom:14px}
.brand h1{margin:0;font-size:23px;letter-spacing:-.03em}
.brand p{margin:5px 0 0;font-size:12px;color:var(--muted)}
.badge{padding:7px 11px;border:1px solid var(--line);border-radius:999px;background:var(--panel2);font-size:11px;font-weight:700;letter-spacing:.08em}
.badge.live{color:var(--good)}
.badge.offline{color:var(--bad)}
.toolbar{
  position:sticky;top:0;z-index:20;
  display:flex;gap:8px;align-items:center;flex-wrap:wrap;
  padding:10px 0 13px;background:rgba(8,11,16,.93);backdrop-filter:blur(14px)
}
button,select,input{
  font:inherit;color:var(--text);background:var(--panel);border:1px solid var(--line);
  border-radius:9px;min-height:38px
}
button{padding:8px 12px;cursor:pointer}
button:hover{background:var(--panel2)}
button.primary{background:#17243a;border-color:#31507b}
button.danger{border-color:#54323a}
input{padding:8px 11px;outline:none}
.search{flex:1;min-width:240px}
select{padding:7px 9px}
.section-title{display:flex;align-items:end;justify-content:space-between;gap:15px;margin:20px 0 9px}
.section-title h2{font-size:14px;margin:0;letter-spacing:.02em}
.section-title .hint{font-size:11px;color:var(--muted)}
.overview{
 display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:8px;margin-bottom:16px
}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:13px;padding:12px}
.kpi .name{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
.kpi .value{font-size:21px;font-weight:750;margin-top:5px;font-variant-numeric:tabular-nums}
.kpi .sub{font-size:10px;color:var(--muted);margin-top:3px}
.pin-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(315px,1fr));gap:10px}
.pin-card{
 background:linear-gradient(180deg,var(--panel2),var(--panel));
 border:1px solid var(--line);border-radius:15px;overflow:hidden;min-width:0
}
.pin-head{display:flex;justify-content:space-between;gap:10px;align-items:flex-start;padding:12px 12px 8px}
.pin-title{min-width:0}
.pin-title .label{font-weight:700;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pin-title .sensor{font-size:10px;color:var(--muted);margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pin-actions{display:flex;gap:5px}
.iconbtn{padding:5px 8px;min-height:28px;border-radius:7px;font-size:11px}
.pin-main{display:flex;align-items:end;justify-content:space-between;gap:10px;padding:0 12px 10px}
.big-value{font-size:31px;font-weight:800;letter-spacing:-.03em;font-variant-numeric:tabular-nums}
.unit{font-size:11px;color:var(--muted);margin-left:4px;font-weight:500}
.pin-mode{font-size:10px;color:var(--muted);margin-top:2px}
.stats4{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:var(--line2);border-top:1px solid var(--line2);border-bottom:1px solid var(--line2)}
.mini{background:var(--panel);padding:7px 8px;min-width:0}
.mini .n{font-size:9px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.mini .v{font-size:12px;font-weight:650;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.chart-wrap{height:110px;padding:7px 9px 9px;position:relative}
.chart-wrap canvas{width:100%;height:100%;display:block}
.chart-meta{position:absolute;left:11px;bottom:8px;font-size:9px;color:var(--muted);pointer-events:none}
.card-controls{display:flex;align-items:center;gap:6px;padding:8px 10px;border-top:1px solid var(--line2)}
.card-controls select{font-size:10px;min-height:30px;padding:4px 6px}
.card-controls label{font-size:10px;color:var(--muted);display:flex;align-items:center;gap:4px}
.card-controls input[type=checkbox]{min-height:auto}
.empty-pins{
 border:1px dashed var(--line);border-radius:13px;padding:22px;text-align:center;color:var(--muted);font-size:12px
}
.fps-lab{
 display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:8px;margin:10px 0 17px
}
.metric{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:11px}
.metric .n{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.metric .v{font-size:19px;font-weight:750;margin-top:4px;font-variant-numeric:tabular-nums}
.metric .d{font-size:9px;color:var(--muted);margin-top:3px;line-height:1.35}
.sensor-groups{display:grid;gap:8px}
.group{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.group-head{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:10px 12px;background:var(--panel2);cursor:pointer}
.group-title{font-weight:700;font-size:12px}
.group-count{font-size:10px;color:var(--muted)}
table{border-collapse:collapse;width:100%;font-size:11px}
th,td{border-top:1px solid var(--line2);padding:7px 9px;text-align:right;font-variant-numeric:tabular-nums}
th{font-size:9px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;background:#0d131c}
th:first-child,td:first-child{text-align:center;width:38px}
th:nth-child(2),td:nth-child(2){text-align:left;width:43%}
.sensor-label{color:#c8d2df}
.star{border:0;background:transparent;padding:2px 4px;min-height:0;font-size:16px;line-height:1;opacity:.55}
.star.on{opacity:1}
.hidden{display:none!important}
.err{padding:13px;border-radius:11px;background:#2b171c;border:1px solid #62323a;color:#f4c3ca;margin-bottom:12px}
.note{font-size:10px;color:var(--muted);line-height:1.45}
.session-bar{display:flex;gap:12px;align-items:center;flex-wrap:wrap;font-size:10px;color:var(--muted);margin-bottom:8px}
.session-bar strong{color:var(--soft);font-weight:650}
@media(max-width:760px){
 .wrap{padding:12px}
 header{flex-direction:column}
 .stats4{grid-template-columns:repeat(2,1fr)}
 th:nth-child(n+4),td:nth-child(n+4){display:none}
}
</style>
</head>
<body>
<div class="wrap">
<header>
 <div class="brand">
  <h1>HWiNFO Performance Lab</h1>
  <p id="meta">Waiting for HWiNFO shared memory…</p>
 </div>
 <div class="badge" id="status">CONNECTING</div>
</header>

<div class="toolbar">
 <input class="search" id="q" placeholder="Search sensors — GPU, CPU, temperature, PresentMon, clock, power…">
 <select id="window">
  <option value="60">60 s graph</option>
  <option value="300" selected>5 min graph</option>
  <option value="900">15 min graph</option>
  <option value="1800">30 min graph</option>
 </select>
 <button id="essentials" class="primary">Pin essentials</button>
 <button id="pause">Pause</button>
 <button id="reset" class="danger">Reset session</button>
 <button id="export">Export CSV</button>
</div>

<div id="error"></div>

<div class="session-bar">
 <span>Session: <strong id="elapsed">00:00</strong></span>
 <span>Samples: <strong id="samples">0</strong></span>
 <span>Polling: <strong id="poll">—</strong></span>
 <span>History starts when a sensor is pinned.</span>
</div>

<div class="overview">
 <div class="kpi"><div class="name">FPS</div><div class="value" id="ov-fps">—</div><div class="sub">PresentMon</div></div>
 <div class="kpi"><div class="name">Frame time</div><div class="value" id="ov-ft">—</div><div class="sub">PresentMon</div></div>
 <div class="kpi"><div class="name">GPU load</div><div class="value" id="ov-gpu">—</div><div class="sub">graphics core</div></div>
 <div class="kpi"><div class="name">GPU temp</div><div class="value" id="ov-gt">—</div><div class="sub">current</div></div>
 <div class="kpi"><div class="name">CPU total</div><div class="value" id="ov-cpu">—</div><div class="sub">usage</div></div>
 <div class="kpi"><div class="name">CPU temp</div><div class="value" id="ov-ct">—</div><div class="sub">package / Tctl</div></div>
</div>

<div class="section-title">
 <div><h2>Pinned telemetry</h2><div class="hint">Your performance cockpit — each card keeps its own session history.</div></div>
</div>
<div id="pins"></div>

<div class="section-title">
 <div><h2>FPS session analysis</h2><div class="hint">Percentiles below are based on sampled HWiNFO values, not raw per-frame PresentMon events.</div></div>
</div>
<div class="fps-lab">
 <div class="metric"><div class="n">Session avg FPS</div><div class="v" id="fpsavg">—</div><div class="d">Average of collected FPS samples</div></div>
 <div class="metric"><div class="n">Sampled P1 FPS</div><div class="v" id="fpsp1">—</div><div class="d">1st percentile of collected FPS samples</div></div>
 <div class="metric"><div class="n">Sampled P0.1 FPS</div><div class="v" id="fpsp01">—</div><div class="d">0.1st percentile; needs a long session to be meaningful</div></div>
 <div class="metric"><div class="n">FPS min / max</div><div class="v" id="fpsrange">—</div><div class="d">Since last session reset</div></div>
 <div class="metric"><div class="n">Frame-time P99</div><div class="v" id="ftp99">—</div><div class="d">99th percentile of sampled frame-time values</div></div>
 <div class="metric"><div class="n">Frame-time max</div><div class="v" id="ftmax">—</div><div class="d">Largest sampled frame-time value</div></div>
</div>

<div class="section-title">
 <div><h2>All HWiNFO sensors</h2><div class="hint">★ pins any reading to the dashboard above.</div></div>
</div>
<div id="groups" class="sensor-groups"></div>
</div>

<script>
let latest=null, paused=false, timer=null;
let sessionStart=Date.now(), globalSamples=0;
let histories=new Map();
let collapsed=new Set();
let fpsKey=null, frameTimeKey=null;

const PIN_KEY='hwinfo-perf-lab-pins-v3';
const OPT_KEY='hwinfo-perf-lab-options-v3';

let pins=JSON.parse(localStorage.getItem(PIN_KEY)||'[]');
let pinOpts=JSON.parse(localStorage.getItem(OPT_KEY)||'{}');

const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const keyOf=r=>`${r.SensorIndex}:${r.ReadingId}`;
const textOf=r=>`${r.Sensor||''} ${r.SensorOriginal||''} ${r.Label||''} ${r.LabelOriginal||''} ${r.Unit||''}`.toLowerCase();
const num=v=>(v===null||v===undefined||!Number.isFinite(Number(v)))?null:Number(v);

function nice(n,u,decimals=null){
 n=num(n); if(n===null) return '—';
 let d=decimals!==null?decimals:(Math.abs(n)>=1000?0:Math.abs(n)>=100?1:2);
 return `${n.toFixed(d)}${u?` ${u}`:''}`;
}
function qtile(a,q){
 const x=a.filter(Number.isFinite).slice().sort((a,b)=>a-b);
 if(!x.length)return null;
 if(x.length===1)return x[0];
 const p=(x.length-1)*q, lo=Math.floor(p), hi=Math.ceil(p);
 return x[lo]+(x[hi]-x[lo])*(p-lo);
}
function stats(arr){
 const v=arr.map(x=>x.v).filter(Number.isFinite);
 if(!v.length)return {cur:null,min:null,max:null,avg:null,count:0};
 return {cur:v[v.length-1],min:Math.min(...v),max:Math.max(...v),avg:v.reduce((a,b)=>a+b,0)/v.length,count:v.length};
}
function findReading(regexes){
 if(!latest?.Ok)return null;
 for(const re of regexes){
   const x=latest.Readings.find(r=>re.test(`${r.Sensor||''} ${r.Label||''}`));
   if(x)return x;
 }
 return null;
}
function rememberPin(k){
 if(!pins.includes(k)){pins.push(k);localStorage.setItem(PIN_KEY,JSON.stringify(pins));}
 if(!pinOpts[k])pinOpts[k]={mode:'all',graph:true};
 localStorage.setItem(OPT_KEY,JSON.stringify(pinOpts));
}
function unpin(k){
 pins=pins.filter(x=>x!==k);
 localStorage.setItem(PIN_KEY,JSON.stringify(pins));
 render();
}
function setMode(k,v){ pinOpts[k]=pinOpts[k]||{}; pinOpts[k].mode=v; localStorage.setItem(OPT_KEY,JSON.stringify(pinOpts)); renderPins(); }
function setGraph(k,v){ pinOpts[k]=pinOpts[k]||{}; pinOpts[k].graph=v; localStorage.setItem(OPT_KEY,JSON.stringify(pinOpts)); renderPins(); }

function addSample(k,v){
 v=num(v); if(v===null)return;
 if(!histories.has(k))histories.set(k,[]);
 const a=histories.get(k), now=Date.now();
 a.push({t:now,v});
 const keep=60*60*1000;
 while(a.length && now-a[0].t>keep)a.shift();
}

function drawChart(canvas, arr, unit){
 const ctx=canvas.getContext('2d');
 const rect=canvas.getBoundingClientRect();
 const dpr=Math.max(1,window.devicePixelRatio||1);
 const w=Math.max(1,Math.floor(rect.width*dpr)), h=Math.max(1,Math.floor(rect.height*dpr));
 if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h}
 ctx.clearRect(0,0,w,h);
 const seconds=Number(document.getElementById('window').value)||300;
 const cutoff=Date.now()-seconds*1000;
 const pts=arr.filter(x=>x.t>=cutoff&&Number.isFinite(x.v));
 if(pts.length<2)return;
 let vals=pts.map(x=>x.v), lo=Math.min(...vals), hi=Math.max(...vals);
 if(lo===hi){lo-=1;hi+=1}
 const pad=(hi-lo)*.12; lo-=pad;hi+=pad;
 const x0=4*dpr,y0=4*dpr,x1=w-4*dpr,y1=h-12*dpr;
 ctx.strokeStyle='rgba(135,150,170,.18)';ctx.lineWidth=1*dpr;
 for(let i=0;i<3;i++){const y=y0+(y1-y0)*i/2;ctx.beginPath();ctx.moveTo(x0,y);ctx.lineTo(x1,y);ctx.stroke()}
 ctx.strokeStyle='rgba(108,167,255,.95)';ctx.lineWidth=1.6*dpr;ctx.beginPath();
 const t0=pts[0].t,t1=pts[pts.length-1].t||t0+1;
 pts.forEach((p,i)=>{
   const x=x0+(x1-x0)*(p.t-t0)/Math.max(1,t1-t0);
   const y=y1-(y1-y0)*(p.v-lo)/(hi-lo);
   if(i===0)ctx.moveTo(x,y);else ctx.lineTo(x,y);
 });
 ctx.stroke();
 ctx.fillStyle='rgba(135,150,170,.8)';ctx.font=`${9*dpr}px Segoe UI`;
 ctx.fillText(nice(hi,unit),5*dpr,10*dpr);
 ctx.fillText(nice(lo,unit),5*dpr,h-2*dpr);
}

function renderOverview(){
 const fps=findReading([/presentmon.*framerate presented.*avg/i,/framerate presented.*avg/i,/framerate presented/i]);
 const ft=findReading([/presentmon.*frame time/i,/frame time/i]);
 const gpu=findReading([/gpu core load/i,/gpu utilization/i]);
 const gt=findReading([/^gpu.*temperature/i]);
 const cpu=findReading([/total cpu usage/i,/cpu total/i]);
 const ct=findReading([/cpu \(tctl\/tdie\)/i,/cpu package.*temperature/i,/cpu.*temperature/i]);

 fpsKey=fps?keyOf(fps):fpsKey; frameTimeKey=ft?keyOf(ft):frameTimeKey;
 const put=(id,r)=>document.getElementById(id).textContent=r?nice(r.Value,r.Unit):'—';
 put('ov-fps',fps);put('ov-ft',ft);put('ov-gpu',gpu);put('ov-gt',gt);put('ov-cpu',cpu);put('ov-ct',ct);
}

function renderFpsLab(){
 const fa=fpsKey?(histories.get(fpsKey)||[]):[];
 const fta=frameTimeKey?(histories.get(frameTimeKey)||[]):[];
 const fv=fa.map(x=>x.v).filter(Number.isFinite);
 const tv=fta.map(x=>x.v).filter(Number.isFinite);
 const set=(id,val)=>document.getElementById(id).textContent=val;

 if(fv.length){
   const av=fv.reduce((a,b)=>a+b,0)/fv.length;
   set('fpsavg',nice(av,'FPS'));
   set('fpsp1',fv.length>=20?nice(qtile(fv,.01),'FPS'):'collecting…');
   set('fpsp01',fv.length>=100?nice(qtile(fv,.001),'FPS'):'collecting…');
   set('fpsrange',`${nice(Math.min(...fv),'')} / ${nice(Math.max(...fv),' FPS')}`);
 }else{
   ['fpsavg','fpsp1','fpsp01','fpsrange'].forEach(id=>set(id,'—'));
 }
 if(tv.length){
   set('ftp99',tv.length>=20?nice(qtile(tv,.99),'ms'):'collecting…');
   set('ftmax',nice(Math.max(...tv),'ms'));
 }else{
   set('ftp99','—');set('ftmax','—');
 }
}

function readingByKey(k){return latest?.Readings?.find(r=>keyOf(r)===k)||null}

function renderPins(){
 const host=document.getElementById('pins');
 if(!latest?.Ok){host.innerHTML='';return}
 const active=pins.map(k=>[k,readingByKey(k)]).filter(x=>x[1]);
 if(!active.length){
   host.innerHTML=`<div class="empty-pins">Nothing pinned yet. Click ★ next to any sensor below, or use <b>Pin essentials</b>.</div>`;
   return;
 }
 host.className='pin-grid';
 host.innerHTML=active.map(([k,r])=>{
   const st=stats(histories.get(k)||[]);
   const opt=pinOpts[k]||{mode:'all',graph:true};
   let primary=r.Value;
   if(opt.mode==='min')primary=st.min;
   if(opt.mode==='max')primary=st.max;
   if(opt.mode==='avg')primary=st.avg;
   const showStats=opt.mode==='all';
   return `<article class="pin-card">
    <div class="pin-head">
      <div class="pin-title"><div class="label">${esc(r.Label)}</div><div class="sensor">${esc(r.Sensor)}</div></div>
      <div class="pin-actions"><button class="iconbtn" onclick="unpin('${k}')">Unpin</button></div>
    </div>
    <div class="pin-main">
      <div>
       <div class="big-value">${esc(nice(primary,r.Unit))}</div>
       <div class="pin-mode">${opt.mode==='current'?'Current':opt.mode==='min'?'Session minimum':opt.mode==='max'?'Session maximum':opt.mode==='avg'?'Session average':'Current'}</div>
      </div>
    </div>
    <div class="stats4 ${showStats?'':'hidden'}">
      <div class="mini"><div class="n">Current</div><div class="v">${esc(nice(r.Value,r.Unit))}</div></div>
      <div class="mini"><div class="n">Min</div><div class="v">${esc(nice(st.min,r.Unit))}</div></div>
      <div class="mini"><div class="n">Average</div><div class="v">${esc(nice(st.avg,r.Unit))}</div></div>
      <div class="mini"><div class="n">Max</div><div class="v">${esc(nice(st.max,r.Unit))}</div></div>
    </div>
    <div class="chart-wrap ${opt.graph===false?'hidden':''}">
      <canvas data-chart="${k}"></canvas><div class="chart-meta">${st.count} samples</div>
    </div>
    <div class="card-controls">
      <select onchange="setMode('${k}',this.value)">
       <option value="all" ${opt.mode==='all'?'selected':''}>All values</option>
       <option value="current" ${opt.mode==='current'?'selected':''}>Current</option>
       <option value="min" ${opt.mode==='min'?'selected':''}>Session min</option>
       <option value="avg" ${opt.mode==='avg'?'selected':''}>Session average</option>
       <option value="max" ${opt.mode==='max'?'selected':''}>Session max</option>
      </select>
      <label><input type="checkbox" ${opt.graph===false?'':'checked'} onchange="setGraph('${k}',this.checked)"> graph</label>
    </div>
   </article>`;
 }).join('');
 requestAnimationFrame(()=>{
   document.querySelectorAll('canvas[data-chart]').forEach(c=>{
     const k=c.dataset.chart,r=readingByKey(k); if(r)drawChart(c,histories.get(k)||[],r.Unit);
   });
 });
}

function renderGroups(){
 if(!latest?.Ok)return;
 const q=document.getElementById('q').value.trim().toLowerCase();
 const grouped=new Map();
 latest.Readings.forEach(r=>{
   if(q&&!textOf(r).includes(q))return;
   const g=r.Sensor||`Sensor ${r.SensorIndex}`;
   if(!grouped.has(g))grouped.set(g,[]);
   grouped.get(g).push(r);
 });
 let html='';
 for(const [g,rows] of grouped){
  const closed=collapsed.has(g);
  html+=`<section class="group" data-group="${esc(g)}">
   <div class="group-head" onclick="toggleGroup(this)">
    <div class="group-title">${esc(g)}</div><div class="group-count">${rows.length} readings ${closed?'▸':'▾'}</div>
   </div>
   <div class="${closed?'hidden':''}">
    <table><thead><tr><th>Pin</th><th>Reading</th><th>Current</th><th>HWiNFO min</th><th>HWiNFO max</th><th>HWiNFO avg</th></tr></thead><tbody>
    ${rows.map(r=>{
      const k=keyOf(r),on=pins.includes(k);
      return `<tr>
       <td><button class="star ${on?'on':''}" title="${on?'Unpin':'Pin'}" onclick="event.stopPropagation();togglePin('${k}')">${on?'★':'☆'}</button></td>
       <td class="sensor-label">${esc(r.Label)}</td>
       <td>${esc(nice(r.Value,r.Unit))}</td><td>${esc(nice(r.Min,r.Unit))}</td>
       <td>${esc(nice(r.Max,r.Unit))}</td><td>${esc(nice(r.Avg,r.Unit))}</td>
      </tr>`;
    }).join('')}
    </tbody></table>
   </div>
  </section>`;
 }
 document.getElementById('groups').innerHTML=html||`<div class="empty-pins">No sensors match your search.</div>`;
}

function render(){
 if(!latest)return;
 const err=document.getElementById('error');
 if(!latest.Ok){
   err.innerHTML=`<div class="err">${esc(latest.Error||'HWiNFO data unavailable')}</div>`;
   document.getElementById('status').className='badge offline';
   document.getElementById('status').textContent='NO DATA';
   return;
 }
 err.innerHTML='';
 document.getElementById('status').className='badge live';
 document.getElementById('status').textContent=paused?'PAUSED':'LIVE';
 document.getElementById('poll').textContent=latest.PollingPeriodMs?`${latest.PollingPeriodMs} ms`:'—';
 document.getElementById('meta').textContent=`${latest.Readings.length} live readings • Shared Memory v${latest.Version}.${latest.Revision}`;
 renderOverview();renderPins();renderFpsLab();renderGroups();
}

function sample(){
 if(!latest?.Ok||paused)return;
 globalSamples++;
 const now=Date.now();
 // Always collect FPS and frame time so session analysis works without pinning them.
 const fps=findReading([/presentmon.*framerate presented.*avg/i,/framerate presented.*avg/i,/framerate presented/i]);
 const ft=findReading([/presentmon.*frame time/i,/frame time/i]);
 if(fps){fpsKey=keyOf(fps);addSample(fpsKey,fps.Value)}
 if(ft){frameTimeKey=keyOf(ft);addSample(frameTimeKey,ft.Value)}
 pins.forEach(k=>{
   const r=readingByKey(k);
   if(r && k!==fpsKey && k!==frameTimeKey)addSample(k,r.Value);
 });
 document.getElementById('samples').textContent=globalSamples;
}

async function update(){
 if(paused)return;
 try{
   const r=await fetch('/api/sensors',{cache:'no-store'});
   latest=await r.json();
   sample();render();
 }catch(e){
   document.getElementById('status').className='badge offline';
   document.getElementById('status').textContent='OFFLINE';
   document.getElementById('error').innerHTML=`<div class="err">${esc(e.message)}</div>`;
 }
}

window.togglePin=function(k){
 if(pins.includes(k))unpin(k);else{rememberPin(k);render()}
};
window.unpin=unpin; window.setMode=setMode; window.setGraph=setGraph;
window.toggleGroup=function(el){
 const group=el.closest('.group'),g=group.dataset.group;
 if(collapsed.has(g))collapsed.delete(g);else collapsed.add(g);
 renderGroups();
};

function pinEssentials(){
 if(!latest?.Ok)return;
 const patterns=[
  /presentmon.*framerate presented.*avg/i,/presentmon.*frame time/i,
  /gpu core load/i,/^gpu.*temperature/i,/^gpu.*power/i,
  /total cpu usage/i,/cpu \(tctl\/tdie\)/i,/cpu package.*temperature/i,/cpu package power/i,
  /physical memory load/i,/gpu memory.*allocated/i,/gpu memory usage/i
 ];
 patterns.forEach(re=>{
   const r=latest.Readings.find(x=>re.test(`${x.Sensor||''} ${x.Label||''}`));
   if(r)rememberPin(keyOf(r));
 });
 render();
}

function resetSession(){
 if(!confirm('Reset local session history, graphs, min/max/average and sampled FPS percentiles? HWiNFO itself is not reset.'))return;
 histories=new Map();globalSamples=0;sessionStart=Date.now();
 document.getElementById('samples').textContent='0';
 render();
}

function exportCsv(){
 if(!latest?.Ok)return;
 const keys=[...new Set([...pins, fpsKey, frameTimeKey].filter(Boolean))];
 let rows=['timestamp,sensor,label,value,unit'];
 keys.forEach(k=>{
   const r=readingByKey(k); if(!r)return;
   (histories.get(k)||[]).forEach(p=>{
     const safe=s=>`"${String(s??'').replaceAll('"','""')}"`;
     rows.push([new Date(p.t).toISOString(),safe(r.Sensor),safe(r.Label),p.v,safe(r.Unit)].join(','));
   });
 });
 const blob=new Blob([rows.join('\n')],{type:'text/csv'});
 const a=document.createElement('a');a.href=URL.createObjectURL(blob);
 a.download=`hwinfo-session-${new Date().toISOString().replace(/[:.]/g,'-')}.csv`;a.click();
 setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}

document.getElementById('q').addEventListener('input',renderGroups);
document.getElementById('window').addEventListener('change',renderPins);
document.getElementById('essentials').addEventListener('click',pinEssentials);
document.getElementById('reset').addEventListener('click',resetSession);
document.getElementById('export').addEventListener('click',exportCsv);
document.getElementById('pause').addEventListener('click',()=>{
 paused=!paused;
 document.getElementById('pause').textContent=paused?'Resume':'Pause';
 if(!paused)update(); else render();
});

setInterval(()=>{
 const s=Math.floor((Date.now()-sessionStart)/1000),m=Math.floor(s/60),ss=s%60,h=Math.floor(m/60),mm=m%60;
 document.getElementById('elapsed').textContent=h?`${String(h).padStart(2,'0')}:${String(mm).padStart(2,'0')}:${String(ss).padStart(2,'0')}`:`${String(mm).padStart(2,'0')}:${String(ss).padStart(2,'0')}`;
},1000);

window.addEventListener('resize',()=>renderPins());
update();timer=setInterval(update,1000);
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
Write-Host " HWiNFO PERFORMANCE LAB v3" -ForegroundColor Green
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
