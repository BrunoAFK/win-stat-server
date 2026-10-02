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
<title>HWiNFO Performance Lab v6.2</title>
<style>
:root{
  color-scheme:dark;
  --bg:#070a0f;--panel:#0e141d;--panel2:#121a26;--panel3:#182333;
  --line:#223043;--line-soft:#192534;--text:#eef4fb;--muted:#8392a8;
  --accent:#6ea8ff;--accent2:#8bc1ff;--good:#74d49a;--warn:#efc56c;--bad:#ee7a86;
  --tooltip:#0a1019;--toolbar:rgba(7,10,15,.94);--shadow:0 12px 35px rgba(0,0,0,.20);
  --chart-grid:rgba(131,146,168,.18);--chart-line:rgba(110,168,255,.96);--chart-hover:rgba(238,244,251,.55);
  font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Arial,sans-serif;
}
html[data-theme="light"]{
  color-scheme:light;
  --bg:#f4f7fb;--panel:#ffffff;--panel2:#f4f7fb;--panel3:#eaf0f7;
  --line:#d5deea;--line-soft:#e7edf4;--text:#172033;--muted:#6b788d;
  --accent:#236ed8;--accent2:#1558b2;--good:#167a43;--warn:#a66505;--bad:#b63b4d;
  --tooltip:#ffffff;--toolbar:rgba(244,247,251,.94);--shadow:0 8px 28px rgba(25,45,75,.08);
  --chart-grid:rgba(70,88,112,.14);--chart-line:rgba(35,110,216,.96);--chart-hover:rgba(23,32,51,.45);
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
button.primary{background:color-mix(in srgb,var(--accent) 17%,var(--panel));border-color:color-mix(in srgb,var(--accent) 55%,var(--line))}
button.danger{border-color:color-mix(in srgb,var(--bad) 60%,var(--line))}
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
.toolbar{position:sticky;top:0;z-index:40;background:var(--toolbar);backdrop-filter:blur(14px);padding:9px 0 11px;border-bottom:1px solid var(--line-soft);margin-bottom:12px}
.toolbar-row{display:flex;gap:7px;align-items:center;flex-wrap:wrap}.toolbar-row+.toolbar-row{margin-top:7px}
.search{flex:1;min-width:270px}.spacer{flex:1}
.sep{height:24px;width:1px;background:var(--line);margin:0 2px}.label-mini{font-size:10px;color:var(--muted)}
.err{background:color-mix(in srgb,var(--bad) 12%,var(--panel));border:1px solid color-mix(in srgb,var(--bad) 45%,var(--line));color:var(--text);padding:12px 13px;border-radius:11px;margin-bottom:11px}
.toast{position:fixed;right:18px;bottom:18px;z-index:200;background:var(--tooltip);border:1px solid var(--line);box-shadow:var(--shadow);padding:10px 12px;border-radius:10px;font-size:11px;display:none;max-width:370px}
.sessionbar{display:flex;gap:13px;align-items:center;flex-wrap:wrap;color:var(--muted);font-size:10px;margin:10px 0}
.sessionbar strong{color:var(--text);font-weight:650}.dot{width:5px;height:5px;border-radius:99px;background:var(--line);display:inline-block}
.category-overview{display:grid;grid-template-columns:repeat(4,minmax(230px,1fr));gap:9px;margin:9px 0 17px}
.cat-panel{background:var(--panel);border:1px solid var(--line);border-radius:13px;overflow:hidden;box-shadow:var(--shadow)}
.cat-head{display:flex;align-items:center;justify-content:space-between;padding:9px 11px;background:var(--panel2);border-bottom:1px solid var(--line-soft)}
.cat-head strong{font-size:11px;letter-spacing:.04em}.cat-head span{font-size:9px;color:var(--muted)}
.cat-metrics{display:grid;grid-template-columns:repeat(2,1fr)}
.cat-metric{padding:9px 10px;border-right:1px solid var(--line-soft);border-bottom:1px solid var(--line-soft);min-width:0}
.cat-metric:nth-child(even){border-right:0}.cat-metric:nth-last-child(-n+2){border-bottom:0}
.cat-metric .k{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.cat-metric .v{font-size:16px;font-weight:760;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.sectionhead{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;margin:20px 0 8px}
.sectionhead h2{font-size:14px;margin:0}.sectionhead p{font-size:10px;color:var(--muted);margin:3px 0 0}
.global-card-controls{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
.dropzone{border:1px dashed color-mix(in srgb,var(--accent) 35%,var(--line));border-radius:13px;padding:11px;text-align:center;color:var(--muted);font-size:10px;margin-bottom:9px;transition:.15s background,.15s border}
.dropzone.dragover{background:color-mix(in srgb,var(--accent) 8%,var(--panel));border-color:var(--accent);color:var(--text)}
.pingrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:10px}
.pin-card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:var(--shadow);min-width:0;transition:.15s border,.15s transform}
.pin-card.dragging{opacity:.55}.pin-card.drag-target{border-color:var(--accent);transform:translateY(-2px)}
.pin-head{display:flex;align-items:flex-start;justify-content:space-between;gap:9px;padding:10px 11px 7px}
.pin-left{display:flex;gap:8px;align-items:flex-start;min-width:0}.draghandle{font-size:16px;line-height:1;color:var(--muted);cursor:grab;padding-top:2px;user-select:none}
.pin-title{min-width:0}.pin-title .l{font-size:12px;font-weight:750;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.pin-title .g{font-size:9px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.catbadge{display:inline-flex;align-items:center;padding:2px 6px;border:1px solid var(--line);border-radius:999px;font-size:8px;color:var(--muted);margin-top:5px}
.pin-actions{display:flex;gap:4px}.iconbtn{padding:4px 7px;min-height:27px;font-size:10px;border-radius:7px}
.pin-primary{display:flex;align-items:flex-end;justify-content:space-between;gap:8px;padding:0 11px 9px}
.big{font-size:29px;font-weight:800;letter-spacing:-.035em;font-variant-numeric:tabular-nums}.smallmode{font-size:9px;color:var(--muted);margin-top:2px}
.statgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:var(--line-soft);border-top:1px solid var(--line-soft);border-bottom:1px solid var(--line-soft)}
.sbox{background:var(--panel);padding:6px 7px;min-width:0}.sbox .k{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}.sbox .v{font-size:11px;font-weight:650;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.chartbox{height:126px;position:relative;padding:6px 8px 8px;touch-action:none}
.chartbox canvas{width:100%;height:100%;display:block}
.chart-legend{position:absolute;left:10px;bottom:7px;font-size:8px;color:var(--muted);pointer-events:none}
.chart-tooltip{position:fixed;z-index:100;display:none;pointer-events:none;background:var(--tooltip);border:1px solid var(--line);border-radius:8px;padding:7px 8px;box-shadow:var(--shadow);font-size:10px;line-height:1.4;min-width:118px}
.chart-tooltip .time{color:var(--muted)}.chart-tooltip .val{font-size:13px;font-weight:750;margin-top:2px}
.pin-foot{display:flex;align-items:center;gap:6px;flex-wrap:wrap;padding:7px 9px;border-top:1px solid var(--line-soft)}
.pin-foot select{font-size:9px;min-height:29px;padding:4px 6px}.check{font-size:9px;color:var(--muted);display:flex;gap:4px;align-items:center}.check input{margin:0}
.empty{border:1px dashed var(--line);border-radius:12px;padding:20px;text-align:center;color:var(--muted);font-size:11px}
.sourcebar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:8px 10px;margin-bottom:8px}
.sourcebar .source-group{display:flex;gap:6px;align-items:center;min-width:0}.sourcebar label{font-size:9px;color:var(--muted);white-space:nowrap}
.sourcebar select{max-width:440px;min-width:250px;font-size:9px;min-height:31px}
.source-state{font-size:9px;color:var(--muted)}.source-state.ok{color:var(--good)}.source-state.warn{color:var(--warn)}
.fpsgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:8px}
.metric{background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:10px}.metric .k{font-size:9px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}.metric .v{font-size:18px;font-weight:760;margin-top:4px;font-variant-numeric:tabular-nums}.metric .d{font-size:8px;color:var(--muted);margin-top:3px;line-height:1.35}
.filterchips{display:flex;gap:5px;flex-wrap:wrap}.filterchips button{min-height:28px;padding:4px 8px;font-size:9px}.filterchips button.active{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 12%,var(--panel))}
.groups{display:grid;gap:7px}.group{background:var(--panel);border:1px solid var(--line);border-radius:11px;overflow:hidden}
.group-head{display:flex;justify-content:space-between;align-items:center;gap:8px;background:var(--panel2);padding:9px 11px;cursor:pointer}.group-name{font-size:11px;font-weight:700}.group-count{font-size:9px;color:var(--muted)}
table{border-collapse:collapse;width:100%;font-size:10px}th,td{padding:6px 8px;border-top:1px solid var(--line-soft);text-align:right;font-variant-numeric:tabular-nums}th{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em;background:var(--panel2)}th:first-child,td:first-child{text-align:center;width:30px}th:nth-child(2),td:nth-child(2){text-align:left;width:43%}.sensorlabel{color:var(--text)}.star{background:transparent;border:0;min-height:0;padding:1px 3px;font-size:14px;opacity:.55}.star.on{opacity:1}.sensor-row{cursor:grab}.sensor-row.dragging{opacity:.45}
.hidden{display:none!important}
.flash{animation:flash .38s ease}@keyframes flash{0%{box-shadow:0 0 0 0 color-mix(in srgb,var(--accent) 45%,transparent)}100%{box-shadow:0 0 0 10px transparent}}
@media(max-width:1150px){.category-overview{grid-template-columns:repeat(2,minmax(230px,1fr))}}
@media(max-width:800px){.wrap{padding:11px}.pingrid{grid-template-columns:1fr}.statgrid{grid-template-columns:repeat(2,1fr)}header{flex-direction:column}.livebox{justify-content:flex-start}.sep{display:none}.category-overview{grid-template-columns:1fr}.sourcebar select{min-width:180px;max-width:100%}th:nth-child(n+4),td:nth-child(n+4){display:none}}

/* v6 compact command bar */
.toolbar{
  padding:8px 0 10px;
  background:var(--toolbar);
  border-bottom:1px solid var(--line-soft);
  overflow:visible;
}
.commandbar{
  display:flex;
  align-items:center;
  gap:7px;
  min-height:44px;
  overflow:visible;
}
.search-shell{
  position:relative;
  flex:1;
  min-width:300px;
}
.search-shell .search{
  width:100%;
  padding-left:37px;
  min-height:40px;
  background:color-mix(in srgb,var(--panel) 94%,transparent);
  border-color:var(--line);
}
.search-shell .search:focus{
  border-color:color-mix(in srgb,var(--accent) 55%,var(--line));
  box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 10%,transparent);
}
.search-icon{
  position:absolute;
  left:12px;
  top:50%;
  width:15px;
  height:15px;
  transform:translateY(-50%);
  fill:none;
  stroke:var(--muted);
  stroke-width:1.8;
  stroke-linecap:round;
  pointer-events:none;
}
.menu-wrap{position:relative;flex:0 0 auto}
.menu-trigger{
  min-height:40px;
  padding:8px 13px;
  display:flex;
  align-items:center;
  gap:8px;
  border-radius:10px;
  background:transparent;
  white-space:nowrap;
  font-size:11px;
  font-weight:650;
  color:var(--soft);
}
.menu-trigger::after{
  content:"";
  width:6px;
  height:6px;
  border-right:1.5px solid currentColor;
  border-bottom:1.5px solid currentColor;
  transform:rotate(45deg) translateY(-2px);
  opacity:.7;
  transition:transform .15s ease;
}
.menu-wrap.open>.menu-trigger{
  background:var(--panel2);
  color:var(--text);
  border-color:color-mix(in srgb,var(--accent) 28%,var(--line));
}
.menu-wrap.open>.menu-trigger::after{transform:rotate(225deg) translate(-1px,-1px)}
.settings-trigger{padding-right:12px}
.menu-panel{
  display:none;
  position:absolute;
  top:calc(100% + 7px);
  right:0;
  width:340px;
  max-width:min(92vw,380px);
  background:color-mix(in srgb,var(--panel) 97%,transparent);
  border:1px solid var(--line);
  border-radius:14px;
  box-shadow:0 18px 55px rgba(0,0,0,.28);
  padding:8px;
  z-index:150;
  backdrop-filter:blur(18px);
}
html[data-theme="light"] .menu-panel{box-shadow:0 16px 45px rgba(30,50,80,.16)}
.menu-panel-wide{width:420px}
.menu-panel-settings{width:400px}
.menu-wrap.open>.menu-panel{display:block;animation:menuIn .12s ease-out}
@keyframes menuIn{from{opacity:0;transform:translateY(-5px) scale(.985)}to{opacity:1;transform:translateY(0) scale(1)}}
.menu-head{
  padding:8px 9px 10px;
  border-bottom:1px solid var(--line-soft);
  margin-bottom:4px;
}
.menu-head strong{display:block;font-size:11px}
.menu-head span{display:block;font-size:9px;line-height:1.45;color:var(--muted);margin-top:2px}
.menu-section{
  padding:9px 7px;
  border-bottom:1px solid var(--line-soft);
}
.menu-section-last{border-bottom:0;padding-bottom:5px}
.menu-section-title{
  font-size:8px;
  text-transform:uppercase;
  letter-spacing:.09em;
  color:var(--muted);
  margin:0 2px 7px;
  font-weight:700;
}
.segmented-actions{
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:5px;
}
.segmented-actions button{
  min-height:33px;
  font-size:10px;
  padding:6px 8px;
}
.menu-field{
  display:flex;
  align-items:center;
  justify-content:space-between;
  gap:13px;
  padding:7px 2px;
}
.menu-field>span{min-width:0}
.menu-field strong{display:block;font-size:10px;font-weight:650}
.menu-field small{display:block;font-size:8px;color:var(--muted);line-height:1.35;margin-top:2px;font-weight:400}
.menu-field select{min-width:122px;max-width:145px;font-size:9px;min-height:31px;padding:4px 7px}
.menu-action{
  width:100%;
  min-height:44px;
  display:flex;
  align-items:center;
  justify-content:space-between;
  gap:12px;
  text-align:left;
  padding:8px 9px;
  margin:2px 0;
  border-color:transparent;
  background:transparent;
}
.menu-action:hover{
  background:var(--panel2);
  border-color:var(--line-soft);
}
.menu-action>span:first-child{min-width:0}
.menu-action strong{display:block;font-size:10px;font-weight:650}
.menu-action small{display:block;font-size:8px;color:var(--muted);line-height:1.35;margin-top:2px;font-weight:400}
.menu-action>span:last-child{color:var(--muted);font-size:13px}
.primary-action{
  background:color-mix(in srgb,var(--accent) 10%,var(--panel));
  border-color:color-mix(in srgb,var(--accent) 30%,var(--line));
}
.danger-action strong{color:color-mix(in srgb,var(--bad) 78%,var(--text))}
.preset-grid{
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:6px;
  padding:5px 0 8px;
}
.preset-card{
  min-height:72px;
  padding:10px;
  text-align:left;
  display:flex;
  flex-direction:column;
  align-items:flex-start;
  justify-content:flex-start;
  gap:3px;
  border-radius:10px;
}
.preset-card strong{font-size:10px}
.preset-card span{font-size:8px;line-height:1.35;color:var(--muted)}
@media(max-width:900px){
  .commandbar{flex-wrap:wrap}
  .search-shell{flex:1 1 100%;min-width:100%}
  .menu-wrap{flex:1 1 auto}
  .menu-trigger{width:100%;justify-content:center}
  .menu-panel,.menu-panel-wide,.menu-panel-settings{
    position:fixed;
    left:12px;
    right:12px;
    top:auto;
    width:auto;
    max-width:none;
  }
}
@media(max-width:520px){
  .preset-grid{grid-template-columns:1fr}
  .commandbar{gap:5px}
  .menu-trigger{font-size:10px;padding:7px 8px}
}


/* v6.2 health-state styling */
.health-warn{
  color:var(--warn)!important;
  font-weight:780!important;
}
.health-bad{
  color:var(--bad)!important;
  font-weight:820!important;
}
.switch{
  display:inline-flex;
  align-items:center;
  flex:0 0 auto;
  cursor:pointer;
}
.switch input{
  position:absolute;
  opacity:0;
  pointer-events:none;
}
.switch-track{
  width:38px;
  height:22px;
  border-radius:999px;
  border:1px solid var(--line);
  background:var(--panel3);
  display:block;
  padding:2px;
  transition:background .15s ease,border-color .15s ease;
}
.switch-thumb{
  display:block;
  width:16px;
  height:16px;
  border-radius:50%;
  background:var(--muted);
  transition:transform .15s ease,background .15s ease;
}
.switch input:checked + .switch-track{
  background:color-mix(in srgb,var(--accent) 25%,var(--panel3));
  border-color:color-mix(in srgb,var(--accent) 55%,var(--line));
}
.switch input:checked + .switch-track .switch-thumb{
  transform:translateX(16px);
  background:var(--accent);
}

</style>
</head>
<body>
<div class="wrap">
<header>
 <div class="brand"><h1>HWiNFO Performance Lab <span style="color:var(--muted);font-size:11px">v5</span></h1><p id="meta">Connecting to HWiNFO shared memory…</p></div>
 <div class="livebox"><span class="badge" id="status">CONNECTING</span><span class="age" id="age">—</span></div>
</header>

<div class="toolbar">
 <div class="commandbar">
  <div class="search-shell">
   <svg class="search-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="m21 21-4.35-4.35m1.35-5.65a7 7 0 1 1-14 0 7 7 0 0 1 14 0Z"/></svg>
   <input class="search" type="text" id="search" placeholder="Search sensors, readings, temperatures, clocks…">
  </div>

  <div class="menu-wrap">
   <button class="menu-trigger" type="button" data-menu-trigger="menuPresets">Presets</button>
   <div class="menu-panel menu-panel-wide" id="menuPresets">
    <div class="menu-head">
     <div><strong>Essential presets</strong><span>Build a useful debug dashboard in one click.</span></div>
    </div>
    <div class="preset-grid">
     <button class="preset-card" data-preset="gaming" data-menu-action><strong>Gaming</strong><span>FPS, frame time, GPU busy and latency</span></button>
     <button class="preset-card" data-preset="gpu" data-menu-action><strong>GPU</strong><span>Load, temperature, power, clocks and VRAM</span></button>
     <button class="preset-card" data-preset="cpu" data-menu-action><strong>CPU</strong><span>Usage, temperature, package power and clocks</span></button>
     <button class="preset-card" data-preset="memory" data-menu-action><strong>Memory</strong><span>RAM, VRAM and memory pressure</span></button>
    </div>
    <button class="menu-action primary-action" data-preset="all" data-menu-action>
     <span><strong>All essentials</strong><small>Gaming + GPU + CPU + Memory</small></span><span>→</span>
    </button>
   </div>
  </div>

  <div class="menu-wrap">
   <button class="menu-trigger" type="button" data-menu-trigger="menuDashboard">Dashboard</button>
   <div class="menu-panel" id="menuDashboard">
    <div class="menu-head"><div><strong>Dashboard view</strong><span>Control cards and sensor groups.</span></div></div>

    <div class="menu-section">
     <div class="menu-section-title">Sensor groups</div>
     <div class="segmented-actions">
      <button id="expandAll" data-menu-action>Expand all</button>
      <button id="collapseAll" data-menu-action>Collapse all</button>
     </div>
    </div>

    <div class="menu-section">
     <div class="menu-section-title">Pinned graphs</div>
     <div class="segmented-actions">
      <button id="graphsOn" data-menu-action>Show all</button>
      <button id="graphsOff" data-menu-action>Hide all</button>
     </div>
    </div>

    <div class="menu-section">
     <label class="menu-field">
      <span><strong>Large card value</strong><small>The four Current / Min / Avg / Max values always stay visible.</small></span>
      <select id="globalMode">
       <option value="current">Current</option>
       <option value="min">Session minimum</option>
       <option value="avg">Session average</option>
       <option value="max">Session maximum</option>
      </select>
     </label>
     <button class="menu-action" id="applyMode" data-menu-action>
      <span><strong>Apply to every pinned card</strong><small>Changes only the large headline number.</small></span><span>→</span>
     </button>
    </div>

    <div class="menu-section menu-section-last">
     <button class="menu-action danger-action" id="clearPins" data-menu-action>
      <span><strong>Clear pinned dashboard</strong><small>Does not delete collected HWiNFO data.</small></span>
     </button>
    </div>
   </div>
  </div>

  <div class="menu-wrap">
   <button class="menu-trigger" type="button" data-menu-trigger="menuSession">Session</button>
   <div class="menu-panel" id="menuSession">
    <div class="menu-head"><div><strong>Debug session</strong><span>Control collection and export telemetry.</span></div></div>

    <button class="menu-action" id="pause">
     <span><strong data-pause-title>Pause collection</strong><small data-pause-sub>Freeze browser polling without clearing history.</small></span><span>Ⅱ</span>
    </button>

    <button class="menu-action danger-action" id="reset" data-menu-action>
     <span><strong>Reset session</strong><small>Clear local graphs, session statistics and sampled FPS percentiles.</small></span>
    </button>

    <div class="menu-section menu-section-last">
     <button class="menu-action" id="exportCsv" data-menu-action>
      <span><strong>Export telemetry CSV</strong><small>Download the collected pinned-sensor history.</small></span><span>↓</span>
     </button>
    </div>
   </div>
  </div>

  <div class="menu-wrap">
   <button class="menu-trigger settings-trigger" type="button" data-menu-trigger="menuSettings">Settings</button>
   <div class="menu-panel menu-panel-settings" id="menuSettings">
    <div class="menu-head"><div><strong>Performance Lab settings</strong><span>Display, refresh and portable dashboard configuration.</span></div></div>

    <div class="menu-section">
     <label class="menu-field">
      <span><strong>Graph history</strong><small>Visible time window for pinned charts.</small></span>
      <select id="window">
       <option value="60">60 seconds</option>
       <option value="300" selected>5 minutes</option>
       <option value="900">15 minutes</option>
       <option value="1800">30 minutes</option>
       <option value="3600">60 minutes</option>
      </select>
     </label>

     <label class="menu-field">
      <span><strong>Browser refresh</strong><small>How often the dashboard checks for a new HWiNFO source update.</small></span>
      <select id="clientPoll">
       <option value="250">250 ms</option>
       <option value="500" selected>500 ms</option>
       <option value="1000">1 second</option>
       <option value="2000">2 seconds</option>
      </select>
     </label>

     <label class="menu-field">
      <span><strong>Appearance</strong><small>Follow the operating system or force a theme.</small></span>
      <select id="theme">
       <option value="system">System</option>
       <option value="dark">Dark</option>
       <option value="light">Light</option>
      </select>
     </label>

     <label class="menu-field">
      <span><strong>Health colors</strong><small>Only abnormal values are colored. Normal values stay neutral.</small></span>
      <label class="switch">
       <input id="healthColors" type="checkbox" checked>
       <span class="switch-track"><span class="switch-thumb"></span></span>
      </label>
     </label>

     <label class="menu-field">
      <span><strong>Target FPS</strong><small>Used for FPS, frame-time and frame-budget health thresholds.</small></span>
      <select id="targetFps">
       <option value="30">30 FPS</option>
       <option value="60" selected>60 FPS</option>
       <option value="90">90 FPS</option>
       <option value="120">120 FPS</option>
       <option value="144">144 FPS</option>
       <option value="165">165 FPS</option>
       <option value="240">240 FPS</option>
       <option value="360">360 FPS</option>
      </select>
     </label>
    </div>

    <div class="menu-section menu-section-last">
     <div class="menu-section-title">Portable setup</div>
     <button class="menu-action" id="exportSetup" data-menu-action>
      <span><strong>Export dashboard setup</strong><small>Save pins, order, card options, graph settings, theme and FPS sources.</small></span><span>↓</span>
     </button>
     <button class="menu-action" id="importSetup" data-menu-action>
      <span><strong>Import dashboard setup</strong><small>Restore the layout on this or another PC.</small></span><span>↑</span>
     </button>
     <input id="importFile" type="file" accept=".json,application/json" class="hidden">
    </div>
   </div>
  </div>
 </div>
</div>

<div id="error"></div>
<div class="sessionbar">
 <span>Session <strong id="elapsed">00:00</strong></span><span class="dot"></span>
 <span>Source samples <strong id="sampleCount">0</strong></span><span class="dot"></span>
 <span>HWiNFO poll <strong id="sourcePoll">—</strong></span><span class="dot"></span>
 <span>Last source update <strong id="sourceUpdate">—</strong></span>
</div>

<div class="category-overview">
 <section class="cat-panel"><div class="cat-head"><strong>Gaming</strong><span id="gamingTargetLabel">PresentMon frame pipeline</span></div><div class="cat-metrics">
  <div class="cat-metric"><div class="k">FPS</div><div class="v" id="ovFps">—</div></div>
  <div class="cat-metric"><div class="k">Frame time</div><div class="v" id="ovFt">—</div></div>
  <div class="cat-metric"><div class="k">CPU busy</div><div class="v" id="ovCpuBusy">—</div></div>
  <div class="cat-metric"><div class="k">CPU wait</div><div class="v" id="ovCpuWait">—</div></div>
  <div class="cat-metric"><div class="k">GPU busy</div><div class="v" id="ovGpuBusy">—</div></div>
  <div class="cat-metric"><div class="k">GPU wait</div><div class="v" id="ovGpuWait">—</div></div>
  <div class="cat-metric"><div class="k">GPU latency</div><div class="v" id="ovGpuLatency">—</div></div>
  <div class="cat-metric"><div class="k">Display latency</div><div class="v" id="ovDisplayLatency">—</div></div>
 </div></section>
 <section class="cat-panel"><div class="cat-head"><strong>GPU</strong><span>graphics</span></div><div class="cat-metrics">
  <div class="cat-metric"><div class="k">Load</div><div class="v" id="ovGpu">—</div></div>
  <div class="cat-metric"><div class="k">Temperature</div><div class="v" id="ovGt">—</div></div>
  <div class="cat-metric"><div class="k">Power</div><div class="v" id="ovGp">—</div></div>
  <div class="cat-metric"><div class="k">Clock</div><div class="v" id="ovGc">—</div></div>
 </div></section>
 <section class="cat-panel"><div class="cat-head"><strong>CPU</strong><span>processor</span></div><div class="cat-metrics">
  <div class="cat-metric"><div class="k">Total usage</div><div class="v" id="ovCpu">—</div></div>
  <div class="cat-metric"><div class="k">Temperature</div><div class="v" id="ovCt">—</div></div>
  <div class="cat-metric"><div class="k">Package power</div><div class="v" id="ovCp">—</div></div>
  <div class="cat-metric"><div class="k">Effective clock</div><div class="v" id="ovCc">—</div></div>
 </div></section>
 <section class="cat-panel"><div class="cat-head"><strong>Memory</strong><span>RAM / VRAM</span></div><div class="cat-metrics">
  <div class="cat-metric"><div class="k">RAM load</div><div class="v" id="ovRamLoad">—</div></div>
  <div class="cat-metric"><div class="k">RAM used</div><div class="v" id="ovRamUsed">—</div></div>
  <div class="cat-metric"><div class="k">VRAM used</div><div class="v" id="ovVram">—</div></div>
  <div class="cat-metric"><div class="k">VRAM load</div><div class="v" id="ovVramLoad">—</div></div>
 </div></section>
</div>

<div class="sectionhead">
 <div><h2>Pinned telemetry</h2><p>Drag cards to reorder. Drag any sensor row here to pin it. Card mode changes only the large number; Current / Min / Avg / Max always remain visible.</p></div>
 <div class="global-card-controls"></div>
</div>
<div class="dropzone" id="dropzone">Drop a sensor here to pin it</div>
<div class="pingrid" id="pinHost"></div>

<div class="sectionhead"><div><h2>FPS session analysis</h2><p>Uses one sample per HWiNFO source update. Percentiles are sampled telemetry, not raw per-frame PresentMon 1% / 0.1% lows.</p></div></div>
<div class="sourcebar">
 <div class="source-group"><label for="fpsSource">FPS source</label><select id="fpsSource"><option value="">Auto detect</option></select></div>
 <div class="source-group"><label for="ftSource">Frame-time source</label><select id="ftSource"><option value="">Auto detect</option></select></div>
 <span class="source-state" id="fpsSourceState">waiting for HWiNFO…</span>
</div>
<div class="fpsgrid">
 <div class="metric"><div class="k">Average FPS</div><div class="v" id="fpsAvg">—</div><div class="d">Session sample average</div></div>
 <div class="metric"><div class="k">Sampled P5 FPS</div><div class="v" id="fpsP5">—</div><div class="d">5th percentile</div></div>
 <div class="metric"><div class="k">Sampled P1 FPS</div><div class="v" id="fpsP1">—</div><div class="d">1st percentile</div></div>
 <div class="metric"><div class="k">Sampled P0.1 FPS</div><div class="v" id="fpsP01">—</div><div class="d">Needs a longer run</div></div>
 <div class="metric"><div class="k">FPS range</div><div class="v" id="fpsRange">—</div><div class="d">Session min / max</div></div>
 <div class="metric"><div class="k">Frame-time P95</div><div class="v" id="ftP95">—</div><div class="d">Sample percentile</div></div>
 <div class="metric"><div class="k">Frame-time P99</div><div class="v" id="ftP99">—</div><div class="d">Sample percentile</div></div>
 <div class="metric"><div class="k">Frame-time max</div><div class="v" id="ftMax">—</div><div class="d">Worst sampled value</div></div>
</div>

<div class="sectionhead">
 <div><h2>All HWiNFO sensors</h2><p>★ pin, or drag a row into Pinned telemetry. HWiNFO Min/Max/Avg below are HWiNFO's own counters.</p></div>
 <div class="filterchips" id="filters">
  <button data-filter="all" class="active">All</button><button data-filter="gaming">Gaming</button><button data-filter="gpu">GPU</button><button data-filter="cpu">CPU</button><button data-filter="memory">Memory</button><button data-filter="other">Other</button>
 </div>
</div>
<div class="groups" id="groups"></div>
</div>

<div class="chart-tooltip" id="tooltip"><div class="time"></div><div class="val"></div></div>
<div class="toast" id="toast"></div>

<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const norm=s=>String(s??'').toLowerCase().replace(/[\(\)\[\]\-_:/\\]+/g,' ').replace(/\s+/g,' ').trim();
const keyOf=r=>`${r.SensorIndex}:${r.ReadingId}`;
const readingText=r=>norm(`${r.Sensor||''} ${r.SensorOriginal||''} ${r.Label||''} ${r.LabelOriginal||''} ${r.Unit||''}`);
const n=v=>(v===null||v===undefined||!Number.isFinite(Number(v)))?null:Number(v);
const fmt=(v,u,compact=false)=>{v=n(v);if(v===null)return '—';let d=compact?(Math.abs(v)>=100?0:1):(Math.abs(v)>=1000?0:Math.abs(v)>=100?1:2);return `${v.toFixed(d)}${u?` ${u}`:''}`};
const qtile=(a,q)=>{const x=a.filter(Number.isFinite).slice().sort((a,b)=>a-b);if(!x.length)return null;if(x.length===1)return x[0];const p=(x.length-1)*q,l=Math.floor(p),h=Math.ceil(p);return x[l]+(x[h]-x[l])*(p-l)};
const calc=a=>{const v=a.map(x=>x.v).filter(Number.isFinite);return v.length?{cur:v.at(-1),min:Math.min(...v),max:Math.max(...v),avg:v.reduce((x,y)=>x+y,0)/v.length,count:v.length}:{cur:null,min:null,max:null,avg:null,count:0}};

function targetFrameMs(){return 1000/Math.max(1,Number(S.targetFps)||60)}

function healthRule(r,value){
 if(!S.healthColors)return null;
 value=n(value);if(value===null||!r)return null;

 const t=readingText(r),unit=String(r.Unit||'').trim().toLowerCase();
 const target=Math.max(1,Number(S.targetFps)||60),budget=1000/target;

 // Frame delivery: relative to the user's chosen target FPS.
 if(unit==='fps'||/\bframerate\b/.test(t)){
   if(value<=0)return {level:'bad',reason:`No rendered FPS; target is ${target} FPS`};
   if(value<target*.75)return {level:'bad',reason:`Below 75% of ${target} FPS target`};
   if(value<target*.90)return {level:'warn',reason:`Below 90% of ${target} FPS target`};
   return null;
 }
 if((unit==='ms'||unit==='milliseconds')&&/\bframe time\b|\bframetime\b/.test(t)){
   if(value>budget*1.50)return {level:'bad',reason:`Frame time exceeds 150% of ${budget.toFixed(2)} ms target frame budget`};
   if(value>budget*1.15)return {level:'warn',reason:`Frame time exceeds 115% of ${budget.toFixed(2)} ms target frame budget`};
   return null;
 }

 // PresentMon CPU/GPU busy: high busy time relative to the target frame budget
 // means that stage alone is consuming nearly/all of the available frame budget.
 if((unit==='ms'||unit==='milliseconds')&&/\bcpu busy\b|\bgpu busy\b/.test(t)){
   if(value>budget*1.15)return {level:'bad',reason:`Busy time exceeds 115% of ${budget.toFixed(2)} ms frame budget`};
   if(value>budget*.90)return {level:'warn',reason:`Busy time is using over 90% of ${budget.toFixed(2)} ms frame budget`};
   return null;
 }

 // Wait times are diagnostically meaningful, but "high = unhealthy" is not
 // universally true (it can simply identify the opposite side of a bottleneck).
 if(/\bcpu wait\b|\bgpu wait\b/.test(t))return null;

 // Latency heuristics scale with the target frame budget.
 if((unit==='ms'||unit==='milliseconds')&&/\bgpu latency\b|\brender latency\b|\bpresent latency\b/.test(t)){
   if(value>budget*3)return {level:'bad',reason:`Latency exceeds 3× the ${budget.toFixed(2)} ms frame budget`};
   if(value>budget*2)return {level:'warn',reason:`Latency exceeds 2× the ${budget.toFixed(2)} ms frame budget`};
   return null;
 }
 if((unit==='ms'||unit==='milliseconds')&&/\bdisplay latency\b|\bclick to photon\b/.test(t)){
   if(value>budget*5)return {level:'bad',reason:`Display latency exceeds 5× the ${budget.toFixed(2)} ms frame budget`};
   if(value>budget*3)return {level:'warn',reason:`Display latency exceeds 3× the ${budget.toFixed(2)} ms frame budget`};
   return null;
 }

 // Temperature rules. These are deliberately generic troubleshooting thresholds,
 // not replacements for component-specific manufacturer limits.
 const isTemp=unit.includes('°c')||unit==='c'||/\btemperature\b|\btemp\b|\btctl\b|\btdie\b|\bhot spot\b|\bjunction\b/.test(t);
 if(isTemp){
   // "Distance to TjMAX"/thermal margin works in the opposite direction.
   if(/distance to tjmax|thermal margin/.test(t)){
     if(value<5)return {level:'bad',reason:'Less than 5 °C thermal headroom'};
     if(value<15)return {level:'warn',reason:'Less than 15 °C thermal headroom'};
     return null;
   }
   if(/gpu.*hot spot|hot spot|junction/.test(t)){
     if(value>=105)return {level:'bad',reason:'GPU hotspot/junction at or above 105 °C'};
     if(value>=95)return {level:'warn',reason:'GPU hotspot/junction at or above 95 °C'};
     return null;
   }
   if(/gpu/.test(t)){
     if(value>=90)return {level:'bad',reason:'GPU core temperature at or above 90 °C'};
     if(value>=82)return {level:'warn',reason:'GPU core temperature at or above 82 °C'};
     return null;
   }
   if(/nvme|ssd|drive/.test(t)){
     if(value>=80)return {level:'bad',reason:'Storage temperature at or above 80 °C'};
     if(value>=70)return {level:'warn',reason:'Storage temperature at or above 70 °C'};
     return null;
   }
   if(/cpu|package|tctl|tdie|ccd/.test(t)){
     if(value>=95)return {level:'bad',reason:'CPU temperature at or above 95 °C'};
     if(value>=85)return {level:'warn',reason:'CPU temperature at or above 85 °C'};
     return null;
   }
   if(value>=95)return {level:'bad',reason:'Temperature at or above 95 °C'};
   if(value>=85)return {level:'warn',reason:'Temperature at or above 85 °C'};
   return null;
 }

 // Memory pressure. CPU/GPU load itself is intentionally NOT marked unhealthy:
 // 99% GPU utilization while gaming is normally desirable.
 if(unit==='%'||unit==='percent'){
   if(/physical memory load|\bram load\b|committed memory load/.test(t)){
     if(value>=95)return {level:'bad',reason:'System memory pressure at or above 95%'};
     if(value>=85)return {level:'warn',reason:'System memory pressure at or above 85%'};
     return null;
   }
   if(/gpu memory load|\bvram\b.*load|dedicated memory.*usage/.test(t)){
     if(value>=98)return {level:'bad',reason:'VRAM pressure at or above 98%'};
     if(value>=90)return {level:'warn',reason:'VRAM pressure at or above 90%'};
     return null;
   }
   if(/remaining life|drive health|ssd health/.test(t)){
     if(value<=10)return {level:'bad',reason:'Remaining drive life at or below 10%'};
     if(value<=20)return {level:'warn',reason:'Remaining drive life at or below 20%'};
     return null;
   }
 }

 // Throttling, thermal/power limit and hardware-error indicators.
 // Numeric boolean sensors exposed as 1/0 are common in HWiNFO.
 if(/thermal thrott|critical temperature|power limit exceeded|performance limit thermal|prochot/.test(t)){
   if(value>0)return {level:'bad',reason:'A throttling / thermal limit indicator is active'};
 }
 if(/whea.*error|hardware error/.test(t)){
   if(value>0)return {level:'bad',reason:'Hardware error count is non-zero'};
 }

 // Clock, raw power and ordinary CPU/GPU utilization remain neutral because
 // whether they are "good" depends on the workload and the exact component.
 return null;
}

function clearHealth(el){
 if(!el)return;
 el.classList.remove('health-warn','health-bad');
 if(el.dataset.healthTitle==='1'){el.removeAttribute('title');delete el.dataset.healthTitle}
}
function applyHealth(el,r,value){
 if(!el)return;
 clearHealth(el);
 const h=healthRule(r,value);
 if(!h)return;
 el.classList.add(h.level==='bad'?'health-bad':'health-warn');
 el.title=h.reason;
 el.dataset.healthTitle='1';
}
function applySyntheticHealth(el,type,value,r=null){
 if(!el)return;
 const pseudo=r||(type==='fps'?{Sensor:'PresentMon',Label:'Framerate',Unit:'FPS'}:{Sensor:'PresentMon',Label:'Frame Time',Unit:'ms'});
 applyHealth(el,pseudo,value);
}

const S={
 latest:null,paused:false,inFlight:false,pollTimer:null,lastFetchAt:0,lastSourceToken:null,
 histories:new Map(),sessionStart:Date.now(),samples:0,collapsed:new Set(),category:'all',
 topology:'',fpsKey:null,ftKey:null,draggingKey:null,hoverCharts:new Map(),hoverRatio:new Map(),
 fpsPref:localStorage.getItem('hpl-v5-fps-source')||'',ftPref:localStorage.getItem('hpl-v5-ft-source')||'',
 themePref:localStorage.getItem('hpl-v5-theme')||'system',
 healthColors:localStorage.getItem('hpl-v62-health-colors')!=='0',
 targetFps:Number(localStorage.getItem('hpl-v62-target-fps')||60),
 pins:JSON.parse(localStorage.getItem('hpl-v5-pins')||localStorage.getItem('hpl-v4-pins')||'[]'),
 opts:JSON.parse(localStorage.getItem('hpl-v5-opts')||localStorage.getItem('hpl-v4-opts')||'{}'),
 pendingImport:null
};

function toast(msg){const t=$('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._x);t._x=setTimeout(()=>t.style.display='none',3000)}
function save(){
 localStorage.setItem('hpl-v5-pins',JSON.stringify(S.pins));
 localStorage.setItem('hpl-v5-opts',JSON.stringify(S.opts));
 localStorage.setItem('hpl-v5-fps-source',S.fpsPref||'');
 localStorage.setItem('hpl-v5-ft-source',S.ftPref||'');
 localStorage.setItem('hpl-v5-theme',S.themePref||'system');
 localStorage.setItem('hpl-v62-health-colors',S.healthColors?'1':'0');
 localStorage.setItem('hpl-v62-target-fps',String(S.targetFps||60));
}
function descriptor(r){return r?{sensor:r.Sensor||'',sensorOriginal:r.SensorOriginal||'',label:r.Label||'',labelOriginal:r.LabelOriginal||'',unit:r.Unit||''}:null}
function resolveDescriptor(d){
 if(!d||!S.latest?.Ok)return null;
 const rs=S.latest.Readings;
 const exact=rs.find(r=>(r.Sensor===d.sensor&&r.Label===d.label&&r.Unit===d.unit)||(r.SensorOriginal===d.sensorOriginal&&r.LabelOriginal===d.labelOriginal&&r.Unit===d.unit));
 if(exact)return exact;
 const byLabel=rs.find(r=>norm(r.Label)===norm(d.label)&&(!d.unit||norm(r.Unit)===norm(d.unit)));
 if(byLabel)return byLabel;
 const byOriginal=rs.find(r=>norm(r.LabelOriginal)===norm(d.labelOriginal)&&(!d.unit||norm(r.Unit)===norm(d.unit)));
 return byOriginal||null;
}
function reading(k){return S.latest?.Readings?.find(r=>keyOf(r)===k)||null}
function ensureOpt(k){const o=S.opts[k]||(S.opts[k]={mode:'current',graph:true,smooth:false});if(o.mode==='all')o.mode='current';return o}

function applyTheme(pref){
 S.themePref=pref||'system';$('theme').value=S.themePref;
 const effective=S.themePref==='system'?(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark'):S.themePref;
 document.documentElement.dataset.theme=effective;save();
 requestAnimationFrame(()=>document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key)));
}
matchMedia('(prefers-color-scheme: light)').addEventListener?.('change',()=>{if(S.themePref==='system')applyTheme('system')});

function classify(r){
 const t=readingText(r),u=norm(r.Unit);
 if(u==='fps'||/presentmon|frame time|frametime|framerate|cpu busy|cpu wait|gpu busy|gpu wait|gpu latency|render latency|display latency|present latency|click to photon/.test(t))return 'gaming';
 if(/\bgpu\b|graphics processor|hot spot|video engine|d3d|memory controller/.test(t))return 'gpu';
 if(/\bcpu\b|core effective|core clock|package power|tctl|tdie|ccd|ppt|tdc|edc/.test(t))return 'cpu';
 if(/physical memory|virtual memory|committed memory|page file|\bram\b|\bvram\b|gpu memory|memory used|memory load/.test(t))return 'memory';
 return 'other';
}

function candidateScore(r,type){
 const t=readingText(r),u=norm(r.Unit);let s=-999;
 if(type==='fps'){
  if(u==='fps')s=100;else if(/framerate/.test(t))s=55;else return -999;
  if(/presentmon/.test(t))s+=50;if(/presented/.test(t))s+=25;if(/\bavg\b|average/.test(t))s+=15;
  if(/displayed/.test(t))s+=8;if(/minimum|maximum|min|max/.test(t))s-=30;
 }else{
  if((u==='ms'||u==='milliseconds')&&/frame ?time|frametime/.test(t))s=100;else if(/frame ?time|frametime/.test(t))s=55;else return -999;
  if(/presentmon/.test(t))s+=50;if(/\bavg\b|average/.test(t))s+=10;
  if(/minimum|maximum|min|max/.test(t))s-=25;
 }
 return s;
}
function candidates(type){return (S.latest?.Readings||[]).map(r=>({r,s:candidateScore(r,type)})).filter(x=>x.s>-999).sort((a,b)=>b.s-a.s).map(x=>x.r)}
function selectedSource(type){
 const pref=type==='fps'?S.fpsPref:S.ftPref;
 if(pref&&reading(pref))return reading(pref);
 return candidates(type)[0]||null;
}
function rebuildSourceSelectors(){
 if(!S.latest?.Ok)return;
 for(const [type,id] of [['fps','fpsSource'],['ft','ftSource']]){
  const el=$(id),old=type==='fps'?S.fpsPref:S.ftPref,items=candidates(type);
  el.innerHTML='<option value="">Auto detect</option>'+items.map(r=>`<option value="${keyOf(r)}">${esc(r.Sensor)} → ${esc(r.Label)} [${esc(r.Unit)}]</option>`).join('');
  el.value=old&&reading(old)?old:'';
 }
 updateSourceState();
}
function updateSourceState(){
 const fps=selectedSource('fps'),ft=selectedSource('ft');S.fpsKey=fps?keyOf(fps):null;S.ftKey=ft?keyOf(ft):null;
 const st=$('fpsSourceState');
 if(fps&&ft){st.className='source-state ok';st.textContent=`FPS: ${fps.Label} • Frame time: ${ft.Label}`}
 else if(fps){st.className='source-state warn';st.textContent=`FPS found (${fps.Label}), but no frame-time source detected`}
 else{st.className='source-state warn';st.textContent='No FPS source detected yet — start the game and check HWiNFO PresentMon / FPS readings'}
}

function findRegex(arr){
 for(const re of arr){const r=(S.latest?.Readings||[]).find(x=>re.test(readingText(x)));if(r)return r}return null
}
function overviewReading(kind){
 const map={
  gpu:[/\bgpu core load\b/,/\bgpu utilization\b/],
  gt:[/\bgpu temperature\b/,/\bgpu hot spot\b/],
  gp:[/\bgpu power\b/,/\btotal graphics power\b/],
  gc:[/\bgpu clock\b/,/\bgpu core clock\b/],
  cpubusy:[/\bcpu busy\b/],
  cpuwait:[/\bcpu wait\b/],
  gbusy:[/\bgpu busy\b/],
  gpuwait:[/\bgpu wait\b/],
  gpulatency:[/\bgpu latency\b/],
  displaylatency:[/\bdisplay latency\b/,/\brender present latency\b/,/\brender latency\b/,/\bpresent latency\b/],
  cpu:[/\btotal cpu usage\b/,/\bcpu total\b/],
  ct:[/\bcpu tctl tdie\b/,/\bcpu package temperature\b/,/\bcpu temperature\b/],
  cp:[/\bcpu package power\b/],
  cc:[/\bcore effective clocks\b.*\bavg\b/,/\baverage effective clock\b/,/\bcore effective clock\b/],
  ramload:[/\bphysical memory load\b/],
  ramused:[/\bphysical memory used\b/,/\bmemory used\b/],
  vram:[/\bgpu memory allocated\b/,/\bdedicated memory usage\b/,/\bgpu memory used\b/],
  vramload:[/\bgpu memory load\b/,/\bmemory controller load\b/]
 };
 return findRegex(map[kind]||[]);
}

function sourceAgeMs(){if(!S.latest?.PollTimeUnix)return null;return Math.max(0,Date.now()-Number(S.latest.PollTimeUnix)*1000)}
function addSample(k,v){
 v=n(v);if(v===null||!k)return;
 if(!S.histories.has(k))S.histories.set(k,[]);
 const a=S.histories.get(k),now=Date.now();a.push({t:now,v});
 const keep=60*60*1000;while(a.length&&now-a[0].t>keep)a.shift();
}
function sampleNewSource(){
 if(!S.latest?.Ok)return;
 updateSourceState();
 const token=String(S.latest.PollTimeUnix||'');
 if(token&&token===S.lastSourceToken)return;
 S.lastSourceToken=token;S.samples++;
 const keys=new Set(S.pins);
 if(S.fpsKey)keys.add(S.fpsKey);if(S.ftKey)keys.add(S.ftKey);
 for(const k of keys){const r=reading(k);if(r)addSample(k,r.Value)}
 $('sampleCount').textContent=S.samples;
}
function rolling(arr,sec){
 if(!arr.length)return arr;const out=[];let left=0,sum=0;
 for(let i=0;i<arr.length;i++){sum+=arr[i].v;while(arr[i].t-arr[left].t>sec*1000){sum-=arr[left].v;left++}out.push({t:arr[i].t,v:sum/(i-left+1)})}
 return out;
}

function pin(k){if(!reading(k)||S.pins.includes(k))return;S.pins.push(k);ensureOpt(k);save();syncPinsStructure();syncGroupStars();updateDynamic()}
function unpin(k){S.pins=S.pins.filter(x=>x!==k);save();syncPinsStructure();syncGroupStars()}
function reorder(k,before){
 const a=S.pins.filter(x=>x!==k);const i=before?a.indexOf(before):-1;if(i<0)a.push(k);else a.splice(i,0,k);S.pins=a;save();syncPinsStructure();updateDynamic()
}
function setMode(k,v){ensureOpt(k).mode=v;save();const c=document.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`);if(c){applyCardPresentation(c,k);drawOneCard(c,k)}}
function setGraph(k,v){ensureOpt(k).graph=v;save();const c=document.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`);if(c){applyCardPresentation(c,k);drawOneCard(c,k)}}
function setSmooth(k,v){ensureOpt(k).smooth=v;save();drawOneCard(document.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`),k)}
window.__unpin=unpin;window.__setMode=setMode;window.__setGraph=setGraph;window.__setSmooth=setSmooth;

function cardHtml(k,r){
 const o=ensureOpt(k),cat=classify(r);
 return `<article class="pin-card" data-key="${k}" draggable="true">
  <div class="pin-head"><div class="pin-left"><div class="draghandle" title="Drag to reorder">⠿</div><div class="pin-title"><div class="l">${esc(r.Label)}</div><div class="g">${esc(r.Sensor)}</div><span class="catbadge">${cat}</span></div></div>
   <div class="pin-actions"><button class="iconbtn" onclick="__unpin('${k}')">Unpin</button></div></div>
  <div class="pin-primary"><div><div class="big" data-pin-primary>—</div><div class="smallmode" data-pin-mode>Current</div></div></div>
  <div class="statgrid">
   <div class="sbox"><div class="k">Current</div><div class="v" data-pin-stat="cur">—</div></div>
   <div class="sbox"><div class="k">Session min</div><div class="v" data-pin-stat="min">—</div></div>
   <div class="sbox"><div class="k">Session avg</div><div class="v" data-pin-stat="avg">—</div></div>
   <div class="sbox"><div class="k">Session max</div><div class="v" data-pin-stat="max">—</div></div>
  </div>
  <div class="chartbox"><canvas></canvas><div class="chart-legend" data-chartlegend>0 samples</div></div>
  <div class="pin-foot">
   <span class="label-mini">Large value</span>
   <select data-mode onchange="__setMode('${k}',this.value)"><option value="current">Current</option><option value="min">Session min</option><option value="avg">Session avg</option><option value="max">Session max</option></select>
   <label class="check"><input type="checkbox" data-graph onchange="__setGraph('${k}',this.checked)"> graph</label>
   <label class="check"><input type="checkbox" data-smooth onchange="__setSmooth('${k}',this.checked)"> 5s avg</label>
  </div>
 </article>`;
}
function applyCardPresentation(card,k){
 const o=ensureOpt(k);card.querySelector('[data-mode]').value=o.mode||'current';
 card.querySelector('[data-graph]').checked=o.graph!==false;card.querySelector('[data-smooth]').checked=!!o.smooth;
 card.querySelector('.chartbox').classList.toggle('hidden',o.graph===false);
 card.querySelector('[data-pin-mode]').textContent=o.mode==='min'?'Session minimum':o.mode==='avg'?'Session average':o.mode==='max'?'Session maximum':'Current';
}
function bindCardDnD(card){
 card.ondragstart=e=>{S.draggingKey=card.dataset.key;card.classList.add('dragging');e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',S.draggingKey)};
 card.ondragend=()=>{S.draggingKey=null;card.classList.remove('dragging');document.querySelectorAll('.pin-card').forEach(x=>x.classList.remove('drag-target'))};
 card.ondragover=e=>{e.preventDefault();if(S.draggingKey&&S.draggingKey!==card.dataset.key)card.classList.add('drag-target')};
 card.ondragleave=()=>card.classList.remove('drag-target');
 card.ondrop=e=>{e.preventDefault();card.classList.remove('drag-target');const k=e.dataTransfer.getData('text/plain')||S.draggingKey;if(k&&S.pins.includes(k))reorder(k,card.dataset.key);else if(k)pin(k)}
}
function syncPinsStructure(){
 const host=$('pinHost'),valid=S.pins.filter(k=>reading(k));
 if(!valid.length){host.className='';host.innerHTML='<div class="empty">Nothing pinned. Use an essential preset, click ★, or drag a sensor row here.</div>';return}
 host.className='pingrid';
 host.querySelectorAll(':scope > .empty').forEach(x=>x.remove());
 const existing=new Map([...host.querySelectorAll('.pin-card')].map(c=>[c.dataset.key,c]));
 let cursor=host.firstElementChild;
 for(const k of valid){
  const r=reading(k);let c=existing.get(k);
  if(!c){
   const t=document.createElement('template');t.innerHTML=cardHtml(k,r).trim();c=t.content.firstElementChild;
   bindCardDnD(c);bindChartHover(c.querySelector('canvas'),k);
  }
  // Move a card only when the requested order actually changed.
  if(c!==cursor)host.insertBefore(c,cursor);
  cursor=c.nextElementSibling;
  applyCardPresentation(c,k);existing.delete(k);
 }
 existing.forEach(c=>c.remove());
}

function graphColors(){
 const cs=getComputedStyle(document.documentElement);
 return {grid:cs.getPropertyValue('--chart-grid').trim(),line:cs.getPropertyValue('--chart-line').trim(),hover:cs.getPropertyValue('--chart-hover').trim(),muted:cs.getPropertyValue('--muted').trim(),text:cs.getPropertyValue('--text').trim()}
}
function drawCanvas(canvas,k,ratioOverride=null){
 if(!canvas)return;const r=reading(k),o=ensureOpt(k);if(!r||o.graph===false)return;
 const rect=canvas.getBoundingClientRect(),dpr=Math.max(1,devicePixelRatio||1),w=Math.max(1,Math.floor(rect.width*dpr)),h=Math.max(1,Math.floor(rect.height*dpr));
 if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h}
 const c=canvas.getContext('2d');c.clearRect(0,0,w,h);
 const seconds=Number($('window').value)||300,cut=Date.now()-seconds*1000;
 let pts=(S.histories.get(k)||[]).filter(p=>p.t>=cut&&Number.isFinite(p.v));if(o.smooth)pts=rolling(pts,5);if(pts.length<2){S.hoverCharts.set(k,{pts,plot:null});return}
 const vals=pts.map(p=>p.v);let lo=Math.min(...vals),hi=Math.max(...vals);if(lo===hi){lo-=1;hi+=1}const pad=(hi-lo)*.10;lo-=pad;hi+=pad;
 const L=4*dpr,R=w-4*dpr,T=4*dpr,B=h-14*dpr,colors=graphColors();
 c.strokeStyle=colors.grid;c.lineWidth=1*dpr;for(let i=0;i<3;i++){const y=T+(B-T)*i/2;c.beginPath();c.moveTo(L,y);c.lineTo(R,y);c.stroke()}
 const t0=pts[0].t,t1=pts.at(-1).t||t0+1;c.strokeStyle=colors.line;c.lineWidth=1.6*dpr;c.beginPath();
 pts.forEach((p,i)=>{const x=L+(R-L)*(p.t-t0)/Math.max(1,t1-t0),y=B-(B-T)*(p.v-lo)/(hi-lo);i?c.lineTo(x,y):c.moveTo(x,y)});c.stroke();
 c.font=`${8*dpr}px Segoe UI`;c.fillStyle=colors.muted;c.fillText(fmt(hi,r.Unit,true),6*dpr,10*dpr);c.fillText(fmt(lo,r.Unit,true),6*dpr,h-2*dpr);
 const ratio=ratioOverride!==null?ratioOverride:S.hoverRatio.get(k);
 if(ratio!==undefined&&ratio!==null){
  const target=t0+(t1-t0)*ratio;let bi=0,bd=Infinity;pts.forEach((p,i)=>{const d=Math.abs(p.t-target);if(d<bd){bd=d;bi=i}});
  const p=pts[bi],x=L+(R-L)*(p.t-t0)/Math.max(1,t1-t0),y=B-(B-T)*(p.v-lo)/(hi-lo);
  c.strokeStyle=colors.hover;c.lineWidth=1*dpr;c.beginPath();c.moveTo(x,T);c.lineTo(x,B);c.stroke();c.fillStyle=colors.text;c.beginPath();c.arc(x,y,3*dpr,0,Math.PI*2);c.fill();
 }
 S.hoverCharts.set(k,{pts,plot:{L,R,T,B,t0,t1,lo,hi}});
}
function bindChartHover(canvas,k){
 canvas.onpointermove=e=>{
  const rect=canvas.getBoundingClientRect(),ratio=Math.max(0,Math.min(1,(e.clientX-rect.left)/Math.max(1,rect.width)));S.hoverRatio.set(k,ratio);drawCanvas(canvas,k,ratio);
  const meta=S.hoverCharts.get(k);if(!meta?.pts?.length)return;const target=meta.plot.t0+(meta.plot.t1-meta.plot.t0)*ratio;let best=meta.pts[0],bd=Infinity;
  for(const p of meta.pts){const d=Math.abs(p.t-target);if(d<bd){bd=d;best=p}}
  const r=reading(k),tip=$('tooltip');tip.querySelector('.time').textContent=new Date(best.t).toLocaleTimeString();tip.querySelector('.val').textContent=fmt(best.v,r?.Unit||'');tip.style.display='block';
  let tx=e.clientX+12,ty=e.clientY+12;if(tx+160>innerWidth)tx=e.clientX-165;if(ty+75>innerHeight)ty=e.clientY-80;tip.style.left=tx+'px';tip.style.top=ty+'px';
 };
 canvas.onpointerleave=()=>{S.hoverRatio.delete(k);$('tooltip').style.display='none';drawCanvas(canvas,k,null)}
}
function drawOneCard(card,k){
 const r=reading(k);if(!card||!r)return;const st=calc(S.histories.get(k)||[]),o=ensureOpt(k);
 const primary=o.mode==='min'?st.min:o.mode==='avg'?st.avg:o.mode==='max'?st.max:r.Value;
 const primaryEl=card.querySelector('[data-pin-primary]');
 primaryEl.textContent=fmt(primary,r.Unit);applyHealth(primaryEl,r,primary);
 for(const [f,v] of [['cur',r.Value],['min',st.min],['avg',st.avg],['max',st.max]]){
   const el=card.querySelector(`[data-pin-stat="${f}"]`);
   el.textContent=fmt(v,r.Unit);applyHealth(el,r,v);
 }
 card.querySelector('[data-chartlegend]').textContent=`${st.count} source samples${o.smooth?' • 5s rolling average':''}`;
 if(o.graph!==false)drawCanvas(card.querySelector('canvas'),k,null);
}
function updatePins(){
 // IMPORTANT: never rebuild, append or move card DOM nodes during a telemetry poll.
 // Native <select> popups are closed by browsers when their element is moved/reinserted.
 // Card structure is synchronized only when pins/topology/order actually changes.
 document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key))
}

function updateOverview(){
 const fps=selectedSource('fps'),ft=selectedSource('ft');
 const vals={
  ovFps:fps,ovFt:ft,
  ovCpuBusy:overviewReading('cpubusy'),ovCpuWait:overviewReading('cpuwait'),
  ovGpuBusy:overviewReading('gbusy'),ovGpuWait:overviewReading('gpuwait'),
  ovGpuLatency:overviewReading('gpulatency'),ovDisplayLatency:overviewReading('displaylatency'),
  ovGpu:overviewReading('gpu'),ovGt:overviewReading('gt'),ovGp:overviewReading('gp'),ovGc:overviewReading('gc'),
  ovCpu:overviewReading('cpu'),ovCt:overviewReading('ct'),ovCp:overviewReading('cp'),ovCc:overviewReading('cc'),
  ovRamLoad:overviewReading('ramload'),ovRamUsed:overviewReading('ramused'),ovVram:overviewReading('vram'),ovVramLoad:overviewReading('vramload')
 };
 for(const [id,r] of Object.entries(vals)){
   const el=$(id);
   el.textContent=r?fmt(r.Value,r.Unit):'—';
   if(r)applyHealth(el,r,r.Value);else clearHealth(el);
 }
 $('gamingTargetLabel').textContent=`PresentMon frame pipeline • target ${S.targetFps} FPS`;
}
function updateFps(){
 const fv=(S.histories.get(S.fpsKey)||[]).map(x=>x.v).filter(Number.isFinite),
       tv=(S.histories.get(S.ftKey)||[]).map(x=>x.v).filter(Number.isFinite);
 const fpsR=reading(S.fpsKey),ftR=reading(S.ftKey);
 const set=(id,display,value,type,r)=>{
   const el=$(id);el.textContent=display;
   if(value===null||value===undefined||!Number.isFinite(Number(value)))clearHealth(el);
   else applySyntheticHealth(el,type,Number(value),r);
 };
 if(fv.length){
  const avg=fv.reduce((a,b)=>a+b,0)/fv.length,p5=fv.length>=20?qtile(fv,.05):null,p1=fv.length>=50?qtile(fv,.01):null,p01=fv.length>=500?qtile(fv,.001):null;
  set('fpsAvg',fmt(avg,'FPS'),avg,'fps',fpsR);
  if(p5!==null)set('fpsP5',fmt(p5,'FPS'),p5,'fps',fpsR);else{$('fpsP5').textContent='collecting…';clearHealth($('fpsP5'))}
  if(p1!==null)set('fpsP1',fmt(p1,'FPS'),p1,'fps',fpsR);else{$('fpsP1').textContent='collecting…';clearHealth($('fpsP1'))}
  if(p01!==null)set('fpsP01',fmt(p01,'FPS'),p01,'fps',fpsR);else{$('fpsP01').textContent='collecting…';clearHealth($('fpsP01'))}
  const mn=Math.min(...fv),mx=Math.max(...fv);
  // Range is kept neutral because min and max share one text node; coloring the whole
  // value would incorrectly color a healthy maximum because of an unhealthy minimum.
  $('fpsRange').textContent=`${fmt(mn,'')} / ${fmt(mx,' FPS')}`;clearHealth($('fpsRange'));
 }else ['fpsAvg','fpsP5','fpsP1','fpsP01','fpsRange'].forEach(id=>{$(id).textContent='—';clearHealth($(id))});

 if(tv.length){
  const p95=tv.length>=20?qtile(tv,.95):null,p99=tv.length>=50?qtile(tv,.99):null,mx=Math.max(...tv);
  if(p95!==null)set('ftP95',fmt(p95,'ms'),p95,'ft',ftR);else{$('ftP95').textContent='collecting…';clearHealth($('ftP95'))}
  if(p99!==null)set('ftP99',fmt(p99,'ms'),p99,'ft',ftR);else{$('ftP99').textContent='collecting…';clearHealth($('ftP99'))}
  set('ftMax',fmt(mx,'ms'),mx,'ft',ftR);
 }else ['ftP95','ftP99','ftMax'].forEach(id=>{$(id).textContent='—';clearHealth($(id))});
}

function groupTopology(){
 if(!S.latest?.Ok)return '';return S.latest.Readings.map(r=>`${keyOf(r)}|${r.Sensor}|${r.Label}|${r.Unit}`).join('~')
}
function visibleReadings(){
 const q=norm($('search').value);
 return (S.latest?.Readings||[]).filter(r=>{
  if(q&&!readingText(r).includes(q))return false;
  const cat=classify(r);return S.category==='all'||cat===S.category;
 })
}
function rowHtml(r){
 const k=keyOf(r),on=S.pins.includes(k);
 return `<tr class="sensor-row" draggable="true" data-key="${k}">
  <td><button class="star ${on?'on':''}" data-star="${k}" title="${on?'Unpin':'Pin'}">${on?'★':'☆'}</button></td>
  <td class="sensorlabel">${esc(r.Label)} <span class="catbadge">${classify(r)}</span></td>
  <td data-cell="${k}:cur">${esc(fmt(r.Value,r.Unit))}</td><td data-cell="${k}:min">${esc(fmt(r.Min,r.Unit))}</td><td data-cell="${k}:max">${esc(fmt(r.Max,r.Unit))}</td><td data-cell="${k}:avg">${esc(fmt(r.Avg,r.Unit))}</td>
 </tr>`;
}
function renderGroupsStructure(force=false){
 if(!S.latest?.Ok)return;const topo=groupTopology(),sig=`${topo}|${S.category}|${$('search').value}`;
 if(!force&&S.topology===sig)return;S.topology=sig;
 const grouped=new Map();for(const r of visibleReadings()){const g=r.Sensor||`Sensor ${r.SensorIndex}`;(grouped.get(g)||grouped.set(g,[]).get(g)).push(r)}
 let html='';for(const [g,rows] of grouped){const closed=S.collapsed.has(g);html+=`<section class="group" data-group="${esc(g)}"><div class="group-head"><div class="group-name">${esc(g)}</div><div class="group-count">${rows.length} readings <span class="chev">${closed?'▸':'▾'}</span></div></div><div class="group-body ${closed?'hidden':''}"><table><thead><tr><th>Pin</th><th>Reading</th><th>Current</th><th>HWiNFO min</th><th>HWiNFO max</th><th>HWiNFO avg</th></tr></thead><tbody>${rows.map(rowHtml).join('')}</tbody></table></div></section>`}
 $('groups').innerHTML=html||'<div class="empty">No readings match this filter.</div>';
 document.querySelectorAll('.group-head').forEach(h=>h.onclick=()=>{const g=h.closest('.group'),name=g.dataset.group,body=g.querySelector('.group-body'),closed=body.classList.toggle('hidden');closed?S.collapsed.add(name):S.collapsed.delete(name);g.querySelector('.chev').textContent=closed?'▸':'▾'});
 document.querySelectorAll('[data-star]').forEach(b=>b.onclick=e=>{e.stopPropagation();const k=b.dataset.star;S.pins.includes(k)?unpin(k):pin(k)});
 document.querySelectorAll('.sensor-row').forEach(row=>{row.ondragstart=e=>{S.draggingKey=row.dataset.key;row.classList.add('dragging');e.dataTransfer.setData('text/plain',S.draggingKey);e.dataTransfer.effectAllowed='copy'};row.ondragend=()=>{S.draggingKey=null;row.classList.remove('dragging')}});
}
function updateSensorCells(){
 if(!S.latest?.Ok)return;
 for(const r of S.latest.Readings){
   const k=keyOf(r);
   for(const [f,v] of [['cur',r.Value],['min',r.Min],['max',r.Max],['avg',r.Avg]]){
     const el=document.querySelector(`[data-cell="${CSS.escape(k+':'+f)}"]`);
     if(el){el.textContent=fmt(v,r.Unit);applyHealth(el,r,v)}
   }
 }
}
function syncGroupStars(){document.querySelectorAll('[data-star]').forEach(b=>{const on=S.pins.includes(b.dataset.star);b.classList.toggle('on',on);b.textContent=on?'★':'☆';b.title=on?'Unpin':'Pin'})}

function updateStatus(){
 if(!S.latest?.Ok){$('status').className='badge offline';$('status').textContent='NO DATA';return}
 const age=sourceAgeMs();let cls='live',txt=S.paused?'PAUSED':'LIVE';
 if(age!==null&&age>Math.max(3000,(S.latest.PollingPeriodMs||1000)*3)){cls='stale';txt='SOURCE STALE'}
 $('status').className='badge '+cls;$('status').textContent=txt;$('age').textContent=S.lastFetchAt?`browser ${Math.round(Date.now()-S.lastFetchAt)} ms ago`:'—';
 $('sourcePoll').textContent=S.latest.PollingPeriodMs?`${S.latest.PollingPeriodMs} ms`:'—';$('sourceUpdate').textContent=age===null?'—':age<1500?'now':`${(age/1000).toFixed(1)} s ago`;
 $('sourceUpdate').style.color=age!==null&&age>3000?'var(--warn)':'';
}
function updateDynamic(){
 if(!S.latest?.Ok)return;updateSourceState();updateOverview();updatePins();updateFps();updateSensorCells();updateStatus();$('sampleCount').textContent=S.samples
}

const PRESETS={
 gaming:[
  r=>candidateScore(r,'fps')>0,
  r=>candidateScore(r,'ft')>0,
  r=>/cpu busy/.test(readingText(r)),
  r=>/cpu wait/.test(readingText(r)),
  r=>/gpu busy/.test(readingText(r)),
  r=>/gpu wait/.test(readingText(r)),
  r=>/gpu latency/.test(readingText(r)),
  r=>/display latency|render present latency|render latency|present latency/.test(readingText(r))
 ],
 gpu:[
  r=>/gpu core load/.test(readingText(r)),r=>/gpu temperature/.test(readingText(r)),r=>/gpu hot spot/.test(readingText(r)),
  r=>/gpu power|total graphics power/.test(readingText(r)),r=>/gpu clock/.test(readingText(r)),
  r=>/gpu memory allocated|dedicated memory usage|gpu memory used/.test(readingText(r))
 ],
 cpu:[
  r=>/total cpu usage/.test(readingText(r)),r=>/cpu tctl tdie|cpu package temperature/.test(readingText(r)),
  r=>/cpu package power/.test(readingText(r)),r=>/core effective clocks.*avg|average effective clock/.test(readingText(r)),
  r=>/max cpu thread usage|maximum cpu core usage/.test(readingText(r))
 ],
 memory:[
  r=>/physical memory load/.test(readingText(r)),r=>/physical memory used/.test(readingText(r)),
  r=>/available physical memory/.test(readingText(r)),r=>/committed memory/.test(readingText(r)),
  r=>/gpu memory allocated|dedicated memory usage|gpu memory used/.test(readingText(r))
 ]
};
function applyPreset(which){
 if(!S.latest?.Ok)return;const cats=which==='all'?['gaming','gpu','cpu','memory']:[which];
 for(const cat of cats){for(const test of PRESETS[cat]||[]){const r=S.latest.Readings.find(test);if(r&&!S.pins.includes(keyOf(r)))S.pins.push(keyOf(r))}}
 save();syncPinsStructure();syncGroupStars();updateDynamic();$('dropzone').classList.add('flash');setTimeout(()=>$('dropzone').classList.remove('flash'),450)
}

function collapseAll(collapse){document.querySelectorAll('.group').forEach(g=>{const name=g.dataset.group,body=g.querySelector('.group-body'),chev=g.querySelector('.chev');body.classList.toggle('hidden',collapse);chev.textContent=collapse?'▸':'▾';collapse?S.collapsed.add(name):S.collapsed.delete(name)})}
function applyAllGraphs(on){for(const k of S.pins)ensureOpt(k).graph=on;save();document.querySelectorAll('.pin-card').forEach(c=>{applyCardPresentation(c,c.dataset.key);drawOneCard(c,c.dataset.key)})}
function applyAllMode(){const mode=$('globalMode').value;for(const k of S.pins)ensureOpt(k).mode=mode;save();document.querySelectorAll('.pin-card').forEach(c=>{applyCardPresentation(c,c.dataset.key);drawOneCard(c,c.dataset.key)})}
function resetSession(){if(!confirm('Reset local graph history, session min/max/average and sampled FPS percentiles? HWiNFO built-in Min/Max/Avg remain untouched.'))return;S.histories=new Map();S.samples=0;S.sessionStart=Date.now();S.lastSourceToken=null;$('sampleCount').textContent='0';updateDynamic();toast('Session history reset')}
function clearPins(){if(!S.pins.length)return;if(!confirm('Remove all pinned cards?'))return;S.pins=[];save();syncPinsStructure();syncGroupStars()}
function exportCsv(){
 const keys=[...new Set([...S.pins,S.fpsKey,S.ftKey].filter(Boolean))],rows=['timestamp,sensor,label,value,unit'];
 for(const k of keys){const r=reading(k);if(!r)continue;for(const p of S.histories.get(k)||[]){const q=s=>`"${String(s??'').replaceAll('"','""')}"`;rows.push([new Date(p.t).toISOString(),q(r.Sensor),q(r.Label),p.v,q(r.Unit)].join(','))}}
 downloadBlob(rows.join('\n'),'text/csv',`hwinfo-session-${stamp()}.csv`)
}
function stamp(){return new Date().toISOString().replace(/[:.]/g,'-')}
function downloadBlob(content,type,name){const blob=new Blob([content],{type}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000)}

function exportSetup(){
 const pinItems=S.pins.map(k=>{const r=reading(k);if(!r)return null;return {reading:descriptor(r),options:ensureOpt(k)}}).filter(Boolean);
 const cfg={
  schema:'hwinfo-performance-lab-setup',version:5,exportedAt:new Date().toISOString(),
  ui:{theme:S.themePref,graphWindow:$('window').value,clientPoll:$('clientPoll').value,category:S.category,healthColors:S.healthColors,targetFps:S.targetFps},
  pins:pinItems,
  sources:{fps:S.fpsPref?descriptor(reading(S.fpsPref)):null,frameTime:S.ftPref?descriptor(reading(S.ftPref)):null}
 };
 downloadBlob(JSON.stringify(cfg,null,2),'application/json',`hwinfo-performance-lab-setup-${stamp()}.json`);toast('Dashboard setup exported')
}
function applyImportedSetup(cfg){
 if(!cfg||cfg.schema!=='hwinfo-performance-lab-setup'){toast('This is not a Performance Lab setup file');return}
 if(!S.latest?.Ok){S.pendingImport=cfg;toast('Setup loaded; waiting for HWiNFO data');return}
 const pins=[],opts={};let unresolved=0;
 for(const item of cfg.pins||[]){const r=resolveDescriptor(item.reading);if(!r){unresolved++;continue}const k=keyOf(r);pins.push(k);opts[k]={mode:item.options?.mode==='all'?'current':(item.options?.mode||'current'),graph:item.options?.graph!==false,smooth:!!item.options?.smooth}}
 S.pins=pins;S.opts=opts;
 if(cfg.ui?.graphWindow)$('window').value=String(cfg.ui.graphWindow);
 if(cfg.ui?.clientPoll)$('clientPoll').value=String(cfg.ui.clientPoll);
 if(cfg.ui?.category){S.category=cfg.ui.category;setFilterButtons()}
 if(cfg.ui?.theme)applyTheme(cfg.ui.theme);
 if(typeof cfg.ui?.healthColors==='boolean'){S.healthColors=cfg.ui.healthColors;$('healthColors').checked=S.healthColors}
 if(cfg.ui?.targetFps){S.targetFps=Number(cfg.ui.targetFps)||60;$('targetFps').value=String(S.targetFps)}
 const fr=resolveDescriptor(cfg.sources?.fps),tr=resolveDescriptor(cfg.sources?.frameTime);S.fpsPref=fr?keyOf(fr):'';S.ftPref=tr?keyOf(tr):'';
 save();rebuildSourceSelectors();S.topology='';renderGroupsStructure(true);syncPinsStructure();updateDynamic();schedulePoll();
 toast(`Setup imported${unresolved?` • ${unresolved} sensor(s) not found on this PC`:''}`)
}
async function importSetupFile(file){try{const cfg=JSON.parse(await file.text());applyImportedSetup(cfg)}catch(e){toast('Could not import setup: '+e.message)}finally{$('importFile').value=''}}

function bindGlobalDnD(){
 const dz=$('dropzone');for(const el of [dz,$('pinHost')]){el.ondragover=e=>{e.preventDefault();dz.classList.add('dragover');e.dataTransfer.dropEffect=S.pins.includes(S.draggingKey)?'move':'copy'};el.ondragleave=e=>{if(!dz.contains(e.relatedTarget))dz.classList.remove('dragover')};el.ondrop=e=>{e.preventDefault();dz.classList.remove('dragover');const k=e.dataTransfer.getData('text/plain')||S.draggingKey;if(!k)return;S.pins.includes(k)?reorder(k,null):pin(k)}}}

function setFilterButtons(){document.querySelectorAll('[data-filter]').forEach(b=>b.classList.toggle('active',b.dataset.filter===S.category))}
function onTopologyChanged(){
 rebuildSourceSelectors();S.topology='';renderGroupsStructure(true);syncPinsStructure();
 if(S.pendingImport){const cfg=S.pendingImport;S.pendingImport=null;applyImportedSetup(cfg)}
}
async function fetchOnce(){
 if(S.paused||S.inFlight)return;S.inFlight=true;
 try{
  const ctl=new AbortController(),to=setTimeout(()=>ctl.abort(),4000);const res=await fetch(`/api/sensors?_=${Date.now()}`,{cache:'no-store',signal:ctl.signal});clearTimeout(to);
  if(!res.ok)throw new Error(`HTTP ${res.status}`);const data=await res.json();const previousTopo=S.latest?.Ok?groupTopology():'';
  S.latest=data;S.lastFetchAt=Date.now();
  if(!data.Ok){$('error').innerHTML=`<div class="err">${esc(data.Error||'HWiNFO data unavailable')}</div>`;updateStatus();return}
  $('error').innerHTML='';
  const newTopo=groupTopology();if(newTopo!==previousTopo)onTopologyChanged();
  sampleNewSource();renderGroupsStructure(false);updateDynamic();$('meta').textContent=`${data.Readings.length} live readings • Shared Memory v${data.Version}.${data.Revision}`;
 }catch(e){$('error').innerHTML=`<div class="err">Dashboard polling error: ${esc(e.message)}. Local server may still be running.</div>`;$('status').className='badge offline';$('status').textContent='OFFLINE'}
 finally{S.inFlight=false}
}
function schedulePoll(){clearTimeout(S.pollTimer);const delay=Number($('clientPoll').value)||500;S.pollTimer=setTimeout(async()=>{await fetchOnce();schedulePoll()},delay)}


function closeMenus(except=null){
 document.querySelectorAll('.menu-wrap.open').forEach(w=>{
  if(w!==except)w.classList.remove('open');
 });
}
document.querySelectorAll('[data-menu-trigger]').forEach(btn=>{
 btn.addEventListener('click',e=>{
  e.stopPropagation();
  const wrap=btn.closest('.menu-wrap');
  const opening=!wrap.classList.contains('open');
  closeMenus(wrap);
  wrap.classList.toggle('open',opening);
 });
});
document.querySelectorAll('.menu-panel').forEach(panel=>panel.addEventListener('click',e=>e.stopPropagation()));
document.querySelectorAll('[data-menu-action]').forEach(el=>el.addEventListener('click',()=>setTimeout(()=>closeMenus(),0)));
document.addEventListener('click',()=>closeMenus());
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeMenus()});

$('search').addEventListener('input',()=>{S.topology='';renderGroupsStructure(true)});
$('window').addEventListener('change',()=>document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key)));
$('clientPoll').addEventListener('change',schedulePoll);
$('theme').addEventListener('change',e=>applyTheme(e.target.value));
$('healthColors').checked=S.healthColors;
$('targetFps').value=String(S.targetFps);
$('healthColors').addEventListener('change',e=>{S.healthColors=e.target.checked;save();updateDynamic()});
$('targetFps').addEventListener('change',e=>{S.targetFps=Number(e.target.value)||60;save();updateDynamic()});
$('fpsSource').addEventListener('change',e=>{S.fpsPref=e.target.value;save();updateSourceState();updateDynamic()});
$('ftSource').addEventListener('change',e=>{S.ftPref=e.target.value;save();updateSourceState();updateDynamic()});
document.querySelectorAll('[data-preset]').forEach(b=>b.onclick=()=>applyPreset(b.dataset.preset));
$('pause').onclick=()=>{
 S.paused=!S.paused;
 const title=$('pause').querySelector('[data-pause-title]');
 const sub=$('pause').querySelector('[data-pause-sub]');
 if(title)title.textContent=S.paused?'Resume collection':'Pause collection';
 if(sub)sub.textContent=S.paused?'Continue browser polling and telemetry collection.':'Freeze browser polling without clearing history.';
 updateStatus();
 if(!S.paused){fetchOnce();schedulePoll()}
};
$('reset').onclick=resetSession;$('exportCsv').onclick=exportCsv;
$('expandAll').onclick=()=>collapseAll(false);$('collapseAll').onclick=()=>collapseAll(true);
$('graphsOn').onclick=()=>applyAllGraphs(true);$('graphsOff').onclick=()=>applyAllGraphs(false);
$('applyMode').onclick=applyAllMode;$('clearPins').onclick=clearPins;
$('exportSetup').onclick=exportSetup;$('importSetup').onclick=()=>$('importFile').click();$('importFile').onchange=e=>{if(e.target.files?.[0])importSetupFile(e.target.files[0])};
document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{S.category=b.dataset.filter;setFilterButtons();S.topology='';renderGroupsStructure(true)});
bindGlobalDnD();applyTheme(S.themePref);setFilterButtons();

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
