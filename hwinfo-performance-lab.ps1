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
<title>Win Stat Server v8.0</title>
<style>
:root{
  --ui-min-font:11px;--ui-font-scale:1;
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
.brand h1{font-size:max(var(--ui-min-font),calc(23px * var(--ui-font-scale)));margin:0;letter-spacing:-.035em}.brand p{font-size:max(var(--ui-min-font),calc(12px * var(--ui-font-scale)));color:var(--muted);margin:5px 0 0}
.livebox{display:flex;align-items:center;gap:8px;flex-wrap:wrap;justify-content:flex-end}
.badge{font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));font-weight:800;letter-spacing:.09em;border:1px solid var(--line);padding:7px 9px;border-radius:999px;background:var(--panel2)}
.badge.live{color:var(--good)}.badge.stale{color:var(--warn)}.badge.offline{color:var(--bad)}
.age{font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));color:var(--muted)}
.toolbar{position:sticky;top:0;z-index:40;background:var(--toolbar);backdrop-filter:blur(14px);padding:9px 0 11px;border-bottom:1px solid var(--line-soft);margin-bottom:12px}
.toolbar-row{display:flex;gap:7px;align-items:center;flex-wrap:wrap}.toolbar-row+.toolbar-row{margin-top:7px}
.search{flex:1;min-width:270px}.spacer{flex:1}
.sep{height:24px;width:1px;background:var(--line);margin:0 2px}.label-mini{font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));color:var(--muted)}
.err{background:color-mix(in srgb,var(--bad) 12%,var(--panel));border:1px solid color-mix(in srgb,var(--bad) 45%,var(--line));color:var(--text);padding:12px 13px;border-radius:11px;margin-bottom:11px}
.toast{position:fixed;right:18px;bottom:18px;z-index:200;background:var(--tooltip);border:1px solid var(--line);box-shadow:var(--shadow);padding:10px 12px;border-radius:10px;font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));display:none;max-width:370px}
.sessionbar{display:flex;gap:13px;align-items:center;flex-wrap:wrap;color:var(--muted);font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));margin:10px 0}
.sessionbar strong{color:var(--text);font-weight:650}.dot{width:5px;height:5px;border-radius:99px;background:var(--line);display:inline-block}
.category-overview{display:grid;grid-template-columns:repeat(4,minmax(230px,1fr));gap:9px;margin:9px 0 17px}
.cat-panel{background:var(--panel);border:1px solid var(--line);border-radius:13px;overflow:hidden;box-shadow:var(--shadow)}
.cat-head{display:flex;align-items:center;justify-content:space-between;padding:9px 11px;background:var(--panel2);border-bottom:1px solid var(--line-soft)}
.cat-head strong{font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));letter-spacing:.04em}.cat-head span{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted)}
.cat-metrics{display:grid;grid-template-columns:repeat(2,1fr)}
.cat-metric{padding:9px 10px;border-right:1px solid var(--line-soft);border-bottom:1px solid var(--line-soft);min-width:0}
.cat-metric:nth-child(even){border-right:0}.cat-metric:nth-last-child(-n+2){border-bottom:0}
.cat-metric .k{font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.cat-metric .v{font-size:max(var(--ui-min-font),calc(16px * var(--ui-font-scale)));font-weight:760;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.sectionhead{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;margin:20px 0 8px}
.sectionhead h2{font-size:max(var(--ui-min-font),calc(14px * var(--ui-font-scale)));margin:0}.sectionhead p{font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));color:var(--muted);margin:3px 0 0}
.global-card-controls{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
.dropzone{border:1px dashed color-mix(in srgb,var(--accent) 35%,var(--line));border-radius:13px;padding:11px;text-align:center;color:var(--muted);font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));margin-bottom:9px;transition:.15s background,.15s border}
.dropzone.dragover{background:color-mix(in srgb,var(--accent) 8%,var(--panel));border-color:var(--accent);color:var(--text)}
.pingrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:10px}
.pin-card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:var(--shadow);min-width:0;transition:.15s border,.15s transform}
.pin-card.dragging{opacity:.55}.pin-card.drag-target{border-color:var(--accent);transform:translateY(-2px)}
.pin-head{display:flex;align-items:flex-start;justify-content:space-between;gap:9px;padding:10px 11px 7px}
.pin-left{display:flex;gap:8px;align-items:flex-start;min-width:0}.draghandle{font-size:max(var(--ui-min-font),calc(16px * var(--ui-font-scale)));line-height:1;color:var(--muted);cursor:grab;padding-top:2px;user-select:none}
.pin-title{min-width:0}.pin-title .l{font-size:max(var(--ui-min-font),calc(12px * var(--ui-font-scale)));font-weight:750;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.pin-title .g{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.catbadge{display:inline-flex;align-items:center;padding:2px 6px;border:1px solid var(--line);border-radius:999px;font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);margin-top:5px}
.pin-actions{display:flex;gap:4px}.iconbtn{padding:4px 7px;min-height:27px;font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));border-radius:7px}
.pin-primary{display:flex;align-items:flex-end;justify-content:space-between;gap:8px;padding:0 11px 9px}
.big{font-size:max(var(--ui-min-font),calc(29px * var(--ui-font-scale)));font-weight:800;letter-spacing:-.035em;font-variant-numeric:tabular-nums}.smallmode{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted);margin-top:2px}
.statgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:var(--line-soft);border-top:1px solid var(--line-soft);border-bottom:1px solid var(--line-soft)}
.sbox{background:var(--panel);padding:6px 7px;min-width:0}.sbox .k{font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);text-transform:uppercase;letter-spacing:.05em}.sbox .v{font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));font-weight:650;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.chartbox{height:126px;position:relative;padding:6px 8px 8px;touch-action:none}
.chartbox canvas{width:100%;height:100%;display:block}
.chart-legend{position:absolute;left:10px;bottom:7px;font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);pointer-events:none}
.chart-tooltip{position:fixed;z-index:100;display:none;pointer-events:none;background:var(--tooltip);border:1px solid var(--line);border-radius:8px;padding:7px 8px;box-shadow:var(--shadow);font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));line-height:1.4;min-width:118px}
.chart-tooltip .time{color:var(--muted)}.chart-tooltip .val{font-size:max(var(--ui-min-font),calc(13px * var(--ui-font-scale)));font-weight:750;margin-top:2px}
.pin-foot{display:flex;align-items:center;gap:6px;flex-wrap:wrap;padding:7px 9px;border-top:1px solid var(--line-soft)}
.pin-foot select{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));min-height:29px;padding:4px 6px}.check{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted);display:flex;gap:4px;align-items:center}.check input{margin:0}
.empty{border:1px dashed var(--line);border-radius:12px;padding:20px;text-align:center;color:var(--muted);font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)))}
.sourcebar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:8px 10px;margin-bottom:8px}
.sourcebar .source-group{display:flex;gap:6px;align-items:center;min-width:0}.sourcebar label{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted);white-space:nowrap}
.sourcebar select{max-width:440px;min-width:250px;font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));min-height:31px}
.source-state{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted)}.source-state.ok{color:var(--good)}.source-state.warn{color:var(--warn)}
.fpsgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:8px}
.metric{background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:10px}.metric .k{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted);text-transform:uppercase;letter-spacing:.06em}.metric .v{font-size:max(var(--ui-min-font),calc(18px * var(--ui-font-scale)));font-weight:760;margin-top:4px;font-variant-numeric:tabular-nums}.metric .d{font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);margin-top:3px;line-height:1.35}
.filterchips{display:flex;gap:5px;flex-wrap:wrap}.filterchips button{min-height:28px;padding:4px 8px;font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)))}.filterchips button.active{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 12%,var(--panel))}
.groups{display:grid;gap:7px}.group{background:var(--panel);border:1px solid var(--line);border-radius:11px;overflow:hidden}
.group-head{display:flex;justify-content:space-between;align-items:center;gap:8px;background:var(--panel2);padding:9px 11px;cursor:pointer}.group-name{font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));font-weight:700}.group-count{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted)}
table{border-collapse:collapse;width:100%;font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)))}th,td{padding:6px 8px;border-top:1px solid var(--line-soft);text-align:right;font-variant-numeric:tabular-nums}th{font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);text-transform:uppercase;letter-spacing:.05em;background:var(--panel2)}th:first-child,td:first-child{text-align:center;width:30px}th:nth-child(2),td:nth-child(2){text-align:left;width:43%}.sensorlabel{color:var(--text)}.star{background:transparent;border:0;min-height:0;padding:1px 3px;font-size:max(var(--ui-min-font),calc(14px * var(--ui-font-scale)));opacity:.55}.star.on{opacity:1}.sensor-row{cursor:grab}.sensor-row.dragging{opacity:.45}
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
  font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));
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
.menu-head strong{display:block;font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)))}
.menu-head span{display:block;font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));line-height:1.45;color:var(--muted);margin-top:2px}
.menu-section{
  padding:9px 7px;
  border-bottom:1px solid var(--line-soft);
}
.menu-section-last{border-bottom:0;padding-bottom:5px}
.menu-section-title{
  font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));
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
  font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));
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
.menu-field strong{display:block;font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));font-weight:650}
.menu-field small{display:block;font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);line-height:1.35;margin-top:2px;font-weight:400}
.menu-field select{min-width:122px;max-width:145px;font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));min-height:31px;padding:4px 7px}
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
.menu-action strong{display:block;font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));font-weight:650}
.menu-action small{display:block;font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);line-height:1.35;margin-top:2px;font-weight:400}
.menu-action>span:last-child{color:var(--muted);font-size:max(var(--ui-min-font),calc(13px * var(--ui-font-scale)))}
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
.preset-card strong{font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)))}
.preset-card span{font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));line-height:1.35;color:var(--muted)}
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
  .menu-trigger{font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));padding:7px 8px}
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


/* v6.3 readability pass: larger dropdown typography */
select{
  font-size:max(var(--ui-min-font),calc(12px * var(--ui-font-scale))) !important;
  min-height:36px !important;
  padding:7px 28px 7px 10px !important;
  line-height:1.25 !important;
}
.pin-foot select{
  font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale))) !important;
  min-height:34px !important;
  padding:6px 26px 6px 9px !important;
}
.sourcebar select{
  font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale))) !important;
  min-height:35px !important;
  padding:6px 28px 6px 9px !important;
}
.menu-field select{
  font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale))) !important;
  min-height:35px !important;
  padding:6px 27px 6px 9px !important;
  min-width:135px !important;
  max-width:170px !important;
}
.menu-trigger{
  font-size:max(var(--ui-min-font),calc(12px * var(--ui-font-scale))) !important;
}
.menu-action strong,
.preset-card strong,
.menu-field strong{
  font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale))) !important;
}
.menu-action small,
.preset-card span,
.menu-field small,
.menu-head span{
  font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale))) !important;
}
.menu-head strong{
  font-size:max(var(--ui-min-font),calc(12px * var(--ui-font-scale))) !important;
}


/* v6.6 card-control visibility */
.pin-actions [data-controls-toggle]{
  min-width:30px;
  font-size:max(var(--ui-min-font),calc(15px * var(--ui-font-scale)));
  line-height:1;
  letter-spacing:.08em;
}
.pin-actions [data-controls-toggle][aria-pressed="true"]{
  background:color-mix(in srgb,var(--accent) 12%,var(--panel));
  border-color:color-mix(in srgb,var(--accent) 38%,var(--line));
}


/* v6.7 customizable overview */
.cat-head-actions{
  display:flex;
  align-items:center;
  gap:8px;
  min-width:0;
}
.cat-edit{
  min-height:25px;
  padding:3px 7px;
  font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));
  border-radius:7px;
  background:transparent;
}
.cat-metric{
  position:relative;
}
.cat-metric[draggable="true"]{cursor:grab}
.cat-metric.overview-dragging{opacity:.45}
.cat-metric.overview-drop-target{
  outline:2px solid color-mix(in srgb,var(--accent) 55%,transparent);
  outline-offset:-2px;
}
.overview-editor-backdrop{
  position:fixed;
  inset:0;
  z-index:500;
  display:grid;
  place-items:center;
  padding:20px;
  background:rgba(0,0,0,.35);
  backdrop-filter:blur(4px);
}
.overview-editor{
  width:min(520px,94vw);
  max-height:min(720px,88vh);
  display:flex;
  flex-direction:column;
  overflow:hidden;
  background:var(--panel);
  border:1px solid var(--line);
  border-radius:16px;
  box-shadow:0 24px 70px rgba(0,0,0,.32);
}
.overview-editor-head,.overview-editor-foot{
  display:flex;
  align-items:center;
  gap:12px;
  padding:13px 14px;
}
.overview-editor-head{
  justify-content:space-between;
  border-bottom:1px solid var(--line-soft);
}
.overview-editor-head strong{display:block;font-size:max(var(--ui-min-font),calc(13px * var(--ui-font-scale)))}
.overview-editor-head span{display:block;color:var(--muted);font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));margin-top:2px}
.overview-close{
  min-width:34px;
  min-height:34px;
  padding:4px;
  font-size:max(var(--ui-min-font),calc(20px * var(--ui-font-scale)));
  line-height:1;
}
.overview-editor-list{
  overflow:auto;
  padding:8px;
}
.overview-choice{
  display:grid;
  grid-template-columns:28px minmax(0,1fr) auto;
  align-items:center;
  gap:9px;
  min-height:48px;
  padding:7px 8px;
  border:1px solid transparent;
  border-radius:10px;
}
.overview-choice:hover{background:var(--panel2)}
.overview-choice .handle{color:var(--muted);font-size:max(var(--ui-min-font),calc(16px * var(--ui-font-scale)));cursor:grab;text-align:center}
.overview-choice .copy{min-width:0}
.overview-choice .copy strong{display:block;font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)))}
.overview-choice .copy small{display:block;font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);margin-top:2px;line-height:1.35}
.overview-choice input{width:17px;height:17px}
.overview-editor-foot{
  border-top:1px solid var(--line-soft);
}
@media(max-width:600px){
  .overview-editor-backdrop{padding:10px}
}


/* v6.8 session laps + scoped telemetry */
.session-scope{
  display:inline-flex;
  align-items:center;
  gap:6px;
  color:var(--muted);
}
.session-scope>span{white-space:nowrap}
.session-scope select{
  min-height:32px!important;
  padding-top:4px!important;
  padding-bottom:4px!important;
  min-width:150px;
}
.session-mini-btn{
  min-height:32px;
  padding:5px 10px;
  font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));
}
.sourcebar .spacer{flex:1}
#resetFpsAnalysis{white-space:nowrap}


/* v6.8.1 top-bar lap navigation */
.search-shell{
  flex:1 1 420px;
  min-width:260px;
}
.top-lap-controls{
  display:flex;
  align-items:center;
  gap:6px;
  flex:0 0 auto;
  min-width:0;
  padding-left:2px;
}
.top-lap-label{
  color:var(--muted);
  white-space:nowrap;
  font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));
}
.top-lap-controls select{
  min-width:160px!important;
  max-width:220px!important;
  min-height:40px!important;
}
.top-lap-new{
  min-height:40px;
  white-space:nowrap;
  padding-left:12px;
  padding-right:12px;
  background:color-mix(in srgb,var(--accent) 8%,var(--panel));
  border-color:color-mix(in srgb,var(--accent) 28%,var(--line));
}
@media(max-width:1100px){
  .search-shell{flex:1 1 100%}
  .top-lap-controls{flex:1 1 auto}
}
@media(max-width:560px){
  .top-lap-controls{
    width:100%;
    display:grid;
    grid-template-columns:auto minmax(0,1fr) auto;
  }
  .top-lap-controls select{
    min-width:0!important;
    width:100%;
  }
}


/* v6.9 layout polish */
.commandbar{
  gap:8px;
}
.search-shell{
  flex:1 1 360px;
  max-width:620px;
  min-width:260px;
}
.top-lap-controls{
  display:flex;
  align-items:stretch;
  gap:0;
  flex:0 0 auto;
  padding:0;
  border:1px solid var(--line);
  border-radius:10px;
  overflow:hidden;
  background:var(--panel);
}
.top-lap-controls select{
  min-width:158px!important;
  max-width:220px!important;
  min-height:40px!important;
  border:0!important;
  border-radius:0!important;
  background:transparent!important;
  box-shadow:none!important;
}
.top-lap-new{
  min-height:40px!important;
  border:0!important;
  border-left:1px solid var(--line)!important;
  border-radius:0!important;
  padding:6px 12px!important;
  background:color-mix(in srgb,var(--accent) 7%,var(--panel))!important;
  white-space:nowrap;
}
.top-lap-new:hover{
  background:color-mix(in srgb,var(--accent) 14%,var(--panel))!important;
}
.sectionhead-actions{
  align-items:center;
}
.section-actions{
  display:flex;
  align-items:center;
  justify-content:flex-end;
  gap:6px;
  flex-wrap:wrap;
}
.section-action{
  min-height:32px;
  padding:5px 9px;
  white-space:nowrap;
  font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));
}
.dashboard-section.section-hidden #pinnedBody{
  display:none;
}
.dashboard-section.section-hidden .sectionhead{
  margin-bottom:0;
}
.analysis-clock{
  color:var(--muted);
  white-space:nowrap;
  font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));
}
.analysis-clock strong{color:var(--text)}
.analysis-settings{
  position:relative;
}
.analysis-settings>summary{
  list-style:none;
  cursor:pointer;
  min-height:32px;
  display:flex;
  align-items:center;
  padding:5px 10px;
  border:1px solid var(--line);
  border-radius:9px;
  background:var(--panel);
  color:var(--text);
  white-space:nowrap;
  font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));
}
.analysis-settings>summary::-webkit-details-marker{display:none}
.analysis-settings>summary::after{
  content:"";
  width:6px;height:6px;
  border-right:1.5px solid currentColor;
  border-bottom:1.5px solid currentColor;
  transform:rotate(45deg);
  margin-left:8px;
  margin-top:-3px;
  opacity:.65;
}
.analysis-settings[open]>summary{
  border-color:color-mix(in srgb,var(--accent) 40%,var(--line));
  background:var(--panel2);
}
.analysis-settings-panel{
  position:absolute;
  z-index:180;
  top:calc(100% + 6px);
  right:0;
  width:min(460px,90vw);
  padding:10px;
  background:var(--panel);
  border:1px solid var(--line);
  border-radius:12px;
  box-shadow:0 18px 50px rgba(0,0,0,.25);
}
.analysis-field{
  display:grid;
  grid-template-columns:120px minmax(0,1fr);
  align-items:center;
  gap:8px;
  margin:6px 0;
}
.analysis-field>span{
  color:var(--muted);
  font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));
}
.analysis-field select{
  width:100%!important;
  min-width:0!important;
  max-width:none!important;
}
.analysis-source-state{
  margin-top:8px;
  padding-top:8px;
  border-top:1px solid var(--line-soft);
  color:var(--muted);
  font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));
}
.fps-section .sectionhead{
  margin-bottom:8px;
}
.fpsgrid{
  margin-top:0;
}
@media(max-width:1050px){
  .search-shell{max-width:none;flex:1 1 100%}
}
@media(max-width:720px){
  .sectionhead-actions{align-items:flex-start;flex-direction:column}
  .section-actions{justify-content:flex-start}
  .analysis-settings-panel{left:0;right:auto}
  .top-lap-controls{flex:1 1 auto}
}
@media(max-width:520px){
  .top-lap-controls{width:100%}
  .top-lap-controls select{flex:1;max-width:none!important}
}


/* v6.9.1 pinned-grid live sorting */
.dropzone{display:none!important}
.pin-empty{
  grid-column:1/-1;
  min-height:74px;
  display:grid;
  place-items:center;
}
.pin-placeholder{
  min-height:150px;
  border:1px dashed color-mix(in srgb,var(--accent) 62%,var(--line));
  border-radius:14px;
  background:color-mix(in srgb,var(--accent) 7%,var(--panel));
  display:grid;
  place-items:center;
  color:var(--muted);
  font-weight:650;
  pointer-events:none;
  animation:pinPlaceholderIn .12s ease-out;
}
.pin-placeholder span{
  padding:7px 10px;
  border-radius:999px;
  background:var(--panel2);
  border:1px solid var(--line);
}
@keyframes pinPlaceholderIn{
  from{opacity:.35;transform:scale(.985)}
  to{opacity:1;transform:scale(1)}
}
#pinHost.pin-drag-active{
  border-radius:14px;
  background:color-mix(in srgb,var(--accent) 2.5%,transparent);
}
.pin-card.dragging{
  opacity:.34;
  border-color:color-mix(in srgb,var(--accent) 55%,var(--line));
}
@media (prefers-reduced-motion:reduce){
  .pin-placeholder{animation:none}
}


/* v6.9.2 command bar alignment */
.commandbar{
  display:flex;
  align-items:center;
  gap:8px;
  width:100%;
  flex-wrap:nowrap;
}
.search-shell{
  flex:1 1 auto!important;
  max-width:none!important;
  min-width:280px!important;
}
.menu-wrap{
  flex:0 0 auto;
}
.top-lap-controls{
  margin-left:6px;
  flex:0 0 auto;
  display:flex;
  align-items:center;
  gap:4px;
  padding:3px;
  border:1px solid var(--line);
  border-radius:999px;
  background:color-mix(in srgb,var(--panel2) 72%,var(--panel));
  box-shadow:none;
  overflow:visible;
}
.top-lap-controls select{
  appearance:none;
  -webkit-appearance:none;
  min-width:86px!important;
  max-width:132px!important;
  min-height:32px!important;
  height:32px!important;
  padding:4px 24px 4px 11px!important;
  border:0!important;
  border-radius:999px!important;
  background:
    linear-gradient(45deg,transparent 50%,var(--muted) 50%) calc(100% - 14px) 13px/4px 4px no-repeat,
    linear-gradient(135deg,var(--muted) 50%,transparent 50%) calc(100% - 10px) 13px/4px 4px no-repeat,
    transparent!important;
  color:var(--text);
  box-shadow:none!important;
  outline:none;
  font-weight:700;
}
.top-lap-controls select:hover,
.top-lap-controls select:focus{
  background:
    linear-gradient(45deg,transparent 50%,var(--text) 50%) calc(100% - 14px) 13px/4px 4px no-repeat,
    linear-gradient(135deg,var(--text) 50%,transparent 50%) calc(100% - 10px) 13px/4px 4px no-repeat,
    color-mix(in srgb,var(--accent) 7%,transparent)!important;
}
.top-lap-new{
  min-height:32px!important;
  height:32px!important;
  padding:4px 11px!important;
  border:0!important;
  border-radius:999px!important;
  background:color-mix(in srgb,var(--accent) 11%,transparent)!important;
  color:var(--text);
  font-weight:700;
  white-space:nowrap;
}
.top-lap-new:hover{
  background:color-mix(in srgb,var(--accent) 19%,transparent)!important;
}
@media(max-width:1180px){
  .commandbar{flex-wrap:wrap}
  .search-shell{
    flex:1 1 100%!important;
    min-width:100%!important;
  }
  .top-lap-controls{
    margin-left:auto;
  }
}
@media(max-width:650px){
  .menu-wrap{flex:1 1 auto}
  .top-lap-controls{
    width:auto!important;
    flex:0 0 auto!important;
    margin-left:auto;
  }
  .top-lap-controls select{
    width:auto!important;
    flex:0 0 auto!important;
  }
}


/* v7 analysis snapshot */
.scope-analysis{
  margin-top:9px;
  border:1px solid var(--line);
  border-radius:12px;
  overflow:hidden;
  background:var(--panel);
}
.scope-analysis-head{
  display:flex;
  align-items:center;
  justify-content:space-between;
  gap:10px;
  padding:8px 10px;
  background:var(--panel2);
  border-bottom:1px solid var(--line-soft);
}
.scope-analysis-head strong{
  font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));
}
.scope-analysis-head span{
  color:var(--muted);
  text-align:right;
  font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));
}
.scope-analysis-grid{
  display:grid;
  grid-template-columns:repeat(4,minmax(0,1fr));
}
.analysis-group{
  padding:9px 10px;
  border-right:1px solid var(--line-soft);
}
.analysis-group:last-child{border-right:0}
.analysis-group-title{
  margin-bottom:6px;
  color:var(--muted);
  text-transform:uppercase;
  letter-spacing:.06em;
  font-weight:750;
  font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));
}
.analysis-row{
  display:flex;
  align-items:baseline;
  justify-content:space-between;
  gap:10px;
  padding:3px 0;
}
.analysis-row span{
  color:var(--muted);
  min-width:0;
  font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));
}
.analysis-row strong{
  white-space:nowrap;
  font-variant-numeric:tabular-nums;
  font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));
}
@media(max-width:1100px){
  .scope-analysis-grid{grid-template-columns:repeat(2,minmax(0,1fr))}
  .analysis-group:nth-child(2){border-right:0}
  .analysis-group:nth-child(-n+2){border-bottom:1px solid var(--line-soft)}
}
@media(max-width:650px){
  .scope-analysis-grid{grid-template-columns:1fr}
  .analysis-group{border-right:0;border-bottom:1px solid var(--line-soft)}
  .analysis-group:last-child{border-bottom:0}
}

/* CAPFRAMEX-INTEGRATION-BEGIN */
/* Read-only CapFrameX bridge */
.cfx-statusline{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.cfx-statusline .badge{min-width:76px;text-align:center}
.cfx-summary{display:grid;grid-template-columns:minmax(0,1.45fr) minmax(290px,.55fr);gap:9px;margin-top:9px}
.cfx-panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.cfx-panel-head{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 10px;background:var(--panel2);border-bottom:1px solid var(--line-soft)}
.cfx-panel-head strong{font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)))}
.cfx-panel-head span{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted);text-align:right}
.cfx-chartbox{height:230px;position:relative;padding:7px 9px 9px;touch-action:none}
.cfx-chartbox canvas{width:100%;height:100%;display:block}
.cfx-chart-empty{position:absolute;inset:0;display:grid;place-items:center;padding:20px;text-align:center;color:var(--muted);font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));pointer-events:none}
.cfx-detail-grid{display:grid;grid-template-columns:1fr}
.cfx-detail{padding:9px 10px;border-bottom:1px solid var(--line-soft)}
.cfx-detail:last-child{border-bottom:0}
.cfx-detail .k{font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.cfx-detail .v{font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));font-weight:650;margin-top:3px;overflow-wrap:anywhere}
.cfx-note{margin-top:9px;padding:8px 10px;border:1px solid var(--line);border-radius:10px;background:var(--panel2);color:var(--muted);font-size:max(var(--ui-min-font),calc(9px * var(--ui-font-scale)));line-height:1.45}
.cfx-note.warn{border-color:color-mix(in srgb,var(--warn) 42%,var(--line));color:var(--text)}
.cfx-correlation{margin-top:9px;display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:1px;background:var(--line-soft);border:1px solid var(--line-soft);border-radius:10px;overflow:hidden}
.cfx-correlation .cell{background:var(--panel);padding:8px 9px;min-width:0}
.cfx-correlation .cell .k{font-size:max(var(--ui-min-font),calc(8px * var(--ui-font-scale)));color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.cfx-correlation .cell .v{font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)));font-weight:650;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
@media(max-width:980px){.cfx-summary{grid-template-columns:1fr}.cfx-correlation{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:560px){.cfx-correlation{grid-template-columns:1fr}}

/* V8-NATIVE-SELECT-FIX-BEGIN
   Chromium/Windows can render the opened native <select> popup using a light
   system palette even when the closed control is dark. Explicit option colors
   keep lap/session and other dropdown entries readable. */
select,
select option,
select optgroup {
  color-scheme: dark;
}

select option,
select optgroup {
  background: #121a26;
  color: #eef4fb;
}

select option:disabled {
  background: #121a26;
  color: #66758a;
}

html[data-theme="light"] select,
html[data-theme="light"] select option,
html[data-theme="light"] select optgroup {
  color-scheme: light;
}

html[data-theme="light"] select option,
html[data-theme="light"] select optgroup {
  background: #ffffff;
  color: #172033;
}

html[data-theme="light"] select option:disabled {
  background: #ffffff;
  color: #9aa5b5;
}
/* V8-NATIVE-SELECT-FIX-END */
</style>
</head>
<body>
<div class="wrap">
<header>
 <div class="brand"><h1>Win Stat Server <span style="color:var(--muted);font-size:max(var(--ui-min-font),calc(11px * var(--ui-font-scale)))">v8</span></h1><p id="meta">Connecting to HWiNFO shared memory…</p></div>
 <div class="livebox"><a href="/dash" data-capture-dash-link style="display:inline-flex;align-items:center;min-height:32px;padding:5px 10px;margin-right:8px;border:1px solid var(--line);border-radius:9px;background:var(--panel);color:var(--text);text-decoration:none;font-size:max(var(--ui-min-font),calc(10px * var(--ui-font-scale)));font-weight:650">Capture Analyzer</a><span class="badge" id="status">CONNECTING</span><span class="age" id="age">—</span></div>
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
     <div class="menu-section-title">Card controls</div>
     <div class="segmented-actions">
      <button id="controlsOn" data-menu-action>Show all</button>
      <button id="controlsOff" data-menu-action>Hide all</button>
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

    <button class="menu-action" id="newLapMenu" data-menu-action>
     <span><strong>Start new lap</strong><small>Begin a fresh comparison interval without deleting session history.</small></span><span>＋</span>
    </button>

    <button class="menu-action" id="resetLaps" data-menu-action>
     <span><strong>Reset laps</strong><small>Delete lap markers and start again at Lap 1 now. Full-session history stays available.</small></span><span>↺</span>
    </button>

    <button class="menu-action danger-action" id="reset" data-menu-action>
     <span><strong>Reset entire session</strong><small>Delete local telemetry history, laps and FPS analysis and start from zero.</small></span>
    </button>

    <div class="menu-section menu-section-last">
     <button class="menu-action" id="exportAnalysis" data-menu-action>
      <span><strong>Export AI analysis JSON</strong><small>Structured scope summary + canonical gaming/CPU/GPU/memory telemetry, even when sensors are not pinned.</small></span><span>↓</span>
     </button>
     <button class="menu-action" id="exportCsv" data-menu-action>
      <span><strong>Export analysis telemetry CSV</strong><small>Wide-format canonical telemetry for the selected lap/session scope.</small></span><span>↓</span>
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
      <span><strong>Minimum font size</strong><small>Sets the smallest text size and proportionally scales larger typography.</small></span>
      <select id="minFontSize">
       <option value="11">11 px</option>
       <option value="12">12 px</option>
       <option value="13">13 px</option>
       <option value="14">14 px</option>
       <option value="15">15 px</option>
       <option value="16">16 px</option>
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
       <option value="0">Off</option>
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
  <div class="top-lap-controls" aria-label="Lap navigation">
   <select id="lapView" aria-label="Session scope">
    <option value="current">Lap 1</option>
    <option value="all">All session</option>
   </select>
   <button type="button" class="top-lap-new" id="newLapQuick" title="Start a new lap">+ Lap</button>
  </div>
 </div>
</div>

<div id="error"></div>
<div class="sessionbar">
 <span>Session <strong id="elapsed">00:00</strong></span><span class="dot"></span>
 <span>Current lap <strong id="lapElapsed">00:00</strong></span><span class="dot"></span>
 <span>Source samples <strong id="sampleCount">0</strong></span><span class="dot"></span>
 <span>HWiNFO poll <strong id="sourcePoll">—</strong></span><span class="dot"></span>
 <span>Last source update <strong id="sourceUpdate">—</strong></span>
</div>

<div class="category-overview" id="overviewHost">
 <section class="cat-panel" data-overview-category="gaming">
  <div class="cat-head">
   <strong>Gaming</strong>
   <div class="cat-head-actions"><span id="gamingTargetLabel">PresentMon frame pipeline</span><button class="cat-edit" type="button" data-edit-overview="gaming">Edit</button></div>
  </div>
  <div class="cat-metrics" data-overview-metrics="gaming"></div>
 </section>

 <section class="cat-panel" data-overview-category="gpu">
  <div class="cat-head">
   <strong>GPU</strong>
   <div class="cat-head-actions"><span>graphics</span><button class="cat-edit" type="button" data-edit-overview="gpu">Edit</button></div>
  </div>
  <div class="cat-metrics" data-overview-metrics="gpu"></div>
 </section>

 <section class="cat-panel" data-overview-category="cpu">
  <div class="cat-head">
   <strong>CPU</strong>
   <div class="cat-head-actions"><span>processor</span><button class="cat-edit" type="button" data-edit-overview="cpu">Edit</button></div>
  </div>
  <div class="cat-metrics" data-overview-metrics="cpu"></div>
 </section>

 <section class="cat-panel" data-overview-category="memory">
  <div class="cat-head">
   <strong>Memory</strong>
   <div class="cat-head-actions"><span>RAM / VRAM</span><button class="cat-edit" type="button" data-edit-overview="memory">Edit</button></div>
  </div>
  <div class="cat-metrics" data-overview-metrics="memory"></div>
 </section>
</div>

<div class="overview-editor-backdrop hidden" id="overviewEditorBackdrop">
 <div class="overview-editor" role="dialog" aria-modal="true" aria-labelledby="overviewEditorTitle">
  <div class="overview-editor-head">
   <div><strong id="overviewEditorTitle">Edit overview</strong><span id="overviewEditorSubtitle">Choose what appears in this summary panel.</span></div>
   <button type="button" class="overview-close" id="overviewEditorClose" aria-label="Close">×</button>
  </div>
  <div class="overview-editor-list" id="overviewEditorList"></div>
  <div class="overview-editor-foot">
   <button type="button" id="overviewEditorReset">Reset defaults</button>
   <span class="spacer"></span>
   <button type="button" class="primary" id="overviewEditorDone">Done</button>
  </div>
 </div>
</div>

<section class="dashboard-section" id="pinnedSection">
 <div class="sectionhead sectionhead-actions">
  <div><h2>Pinned telemetry</h2><p>Drag cards to reorder. Sensors from the table can be dragged directly into the grid.</p></div>
  <div class="section-actions">
   <button type="button" class="section-action" id="togglePinnedSection">Hide pinned</button>
  </div>
 </div>
 <div id="pinnedBody">
  <div class="pingrid" id="pinHost"></div>
 </div>
</section>

<section class="dashboard-section fps-section" id="fpsSection">
 <div class="sectionhead sectionhead-actions">
  <div>
   <h2>FPS session analysis</h2>
   <p><span id="fpsScopeLabel">Current lap</span> · sampled from HWiNFO polling, not raw per-frame PresentMon events.</p>
  </div>
  <div class="section-actions fps-section-actions">
   <span class="analysis-clock">Analysis <strong id="fpsAnalysisElapsed">00:00</strong></span>
   <details class="analysis-settings" id="analysisSettings">
    <summary>Analysis settings</summary>
    <div class="analysis-settings-panel">
     <label class="analysis-field"><span>FPS source</span><select id="fpsSource"><option value="">Auto detect</option></select></label>
     <label class="analysis-field"><span>Frame-time source</span><select id="ftSource"><option value="">Auto detect</option></select></label>
     <div class="analysis-source-state" id="fpsSourceState">waiting for HWiNFO…</div>
    </div>
   </details>
   <button type="button" class="section-action" id="resetFpsAnalysis">Reset analysis</button>
   <button type="button" class="section-action" id="moveFpsSection">Move up</button>
  </div>
 </div>
 <div class="fpsgrid">
  <div class="metric"><div class="k">Average FPS</div><div class="v" id="fpsAvg">—</div><div class="d">Scope sample average</div></div>
  <div class="metric"><div class="k">Sampled P5 FPS</div><div class="v" id="fpsP5">—</div><div class="d">5th percentile</div></div>
  <div class="metric"><div class="k">Sampled P1 FPS</div><div class="v" id="fpsP1">—</div><div class="d">1st percentile</div></div>
  <div class="metric"><div class="k">Sampled P0.1 FPS</div><div class="v" id="fpsP01">—</div><div class="d">Needs a longer run</div></div>
  <div class="metric"><div class="k">FPS range</div><div class="v" id="fpsRange">—</div><div class="d">Scope min / max</div></div>
  <div class="metric"><div class="k">Frame-time P95</div><div class="v" id="ftP95">—</div><div class="d">Sample percentile</div></div>
  <div class="metric"><div class="k">Frame-time P99</div><div class="v" id="ftP99">—</div><div class="d">Sample percentile</div></div>
  <div class="metric"><div class="k">Frame-time max</div><div class="v" id="ftMax">—</div><div class="d">Worst sampled value</div></div>
 </div>

 <div class="scope-analysis">
  <div class="scope-analysis-head">
   <strong>Scope analysis</strong>
   <span id="analysisQuality">Collecting telemetry…</span>
  </div>
  <div class="scope-analysis-grid">
   <div class="analysis-group">
    <div class="analysis-group-title">Frame delivery</div>
    <div class="analysis-row"><span>Median FPS</span><strong id="anFpsMedian">—</strong></div>
    <div class="analysis-row"><span>P1 FPS</span><strong id="anFpsP1">—</strong></div>
    <div class="analysis-row"><span>Frame time P95</span><strong id="anFtP95">—</strong></div>
    <div class="analysis-row"><span>Below target</span><strong id="anBelowTarget">—</strong></div>
   </div>
   <div class="analysis-group">
    <div class="analysis-group-title">Frame pipeline</div>
    <div class="analysis-row"><span>CPU Busy median</span><strong id="anCpuBusy">—</strong></div>
    <div class="analysis-row"><span>GPU Busy median</span><strong id="anGpuBusy">—</strong></div>
    <div class="analysis-row"><span>CPU Busy P95</span><strong id="anCpuBusyP95">—</strong></div>
    <div class="analysis-row"><span>GPU Busy P95</span><strong id="anGpuBusyP95">—</strong></div>
   </div>
   <div class="analysis-group">
    <div class="analysis-group-title">GPU</div>
    <div class="analysis-row"><span>Util median</span><strong id="anGpuUtil">—</strong></div>
    <div class="analysis-row"><span>≥95% samples</span><strong id="anGpuSat">—</strong></div>
    <div class="analysis-row"><span>Temp max</span><strong id="anGpuTemp">—</strong></div>
    <div class="analysis-row"><span>Power median</span><strong id="anGpuPower">—</strong></div>
   </div>
   <div class="analysis-group">
    <div class="analysis-group-title">CPU / limits</div>
    <div class="analysis-row"><span>Max thread P95</span><strong id="anCpuThread">—</strong></div>
    <div class="analysis-row"><span>Temp max</span><strong id="anCpuTemp">—</strong></div>
    <div class="analysis-row"><span>Package power median</span><strong id="anCpuPower">—</strong></div>
    <div class="analysis-row"><span>PPT / TDC / EDC max</span><strong id="anCpuLimits">—</strong></div>
   </div>
  </div>
 </div>
</section>


<section class="dashboard-section cfx-section" id="capframexSection" style="display:none">
 <div class="sectionhead sectionhead-actions">
  <div>
   <h2>CapFrameX frame analysis</h2>
   <p>Per-frame capture data proxied read-only through this local server. CapFrameX itself is never exposed by the tunnel.</p>
  </div>
  <div class="section-actions cfx-statusline">
   <span class="badge offline" id="cfxStatus">OFFLINE</span>
   <span class="age" id="cfxState">CapFrameX not detected</span>
  </div>
 </div>

 <div class="fpsgrid">
  <div class="metric"><div class="k">Average FPS</div><div class="v" id="cfxAverage">—</div><div class="d">CapFrameX metric</div></div>
  <div class="metric"><div class="k">1% Low Avg</div><div class="v" id="cfxLow1">—</div><div class="d">OnePercentLowAverage</div></div>
  <div class="metric"><div class="k">0.2% Low Avg</div><div class="v" id="cfxLow02">—</div><div class="d">ZerodotTwoPercentLowAverage</div></div>
  <div class="metric"><div class="k">P1 FPS</div><div class="v" id="cfxP1">—</div><div class="d">1st percentile metric</div></div>
  <div class="metric"><div class="k">P0.2 FPS</div><div class="v" id="cfxP02">—</div><div class="d">0.2nd percentile metric</div></div>
  <div class="metric"><div class="k">FPS range</div><div class="v" id="cfxRange">—</div><div class="d">CapFrameX Min / Max</div></div>
  <div class="metric"><div class="k">Frames</div><div class="v" id="cfxFrames">—</div><div class="d">Raw captured frame count</div></div>
  <div class="metric"><div class="k">Duration</div><div class="v" id="cfxDuration">—</div><div class="d">Latest completed capture</div></div>
 </div>

 <div class="cfx-summary">
  <div class="cfx-panel">
   <div class="cfx-panel-head">
    <strong>Frametime</strong>
    <span id="cfxChartMeta">Waiting for CapFrameX…</span>
   </div>
   <div class="cfx-chartbox">
    <canvas id="cfxChart"></canvas>
    <div class="cfx-chart-empty" id="cfxChartEmpty">Start CapFrameX and complete a capture to load per-frame data.</div>
   </div>
  </div>

  <div class="cfx-panel">
   <div class="cfx-panel-head"><strong>Capture</strong><span id="cfxRecordedAt">—</span></div>
   <div class="cfx-detail-grid">
    <div class="cfx-detail"><div class="k">Game</div><div class="v" id="cfxGame">—</div></div>
    <div class="cfx-detail"><div class="k">Process</div><div class="v" id="cfxProcess">—</div></div>
    <div class="cfx-detail"><div class="k">Metric source</div><div class="v" id="cfxMetricSource">—</div></div>
    <div class="cfx-detail"><div class="k">Detected stutters</div><div class="v" id="cfxStutters">—</div></div>
    <div class="cfx-detail"><div class="k">Freezes ≥100 ms</div><div class="v" id="cfxFreezes">—</div></div>
   </div>
  </div>
 </div>

 <div class="cfx-note" id="cfxMessage">CapFrameX integration is optional. Keep a current CapFrameX version running; the bridge auto-detects its local MCP endpoint.</div>
 <div class="cfx-correlation">
  <div class="cell"><div class="k">Hovered frame</div><div class="v" id="cfxCorrFrame">—</div></div>
  <div class="cell"><div class="k">GPU utilization</div><div class="v" id="cfxCorrGpu">—</div></div>
  <div class="cell"><div class="k">CPU max thread</div><div class="v" id="cfxCorrCpu">—</div></div>
  <div class="cell"><div class="k">CPU PPT</div><div class="v" id="cfxCorrPpt">—</div></div>
 </div>
</section>
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

function isThrottleStatus(r){
 const t=readingText(r);
 return /thermal throttling htc|thermal throttling prochot cpu|thermal throttling prochot ext|performance limit thermal|performance limit power/.test(t);
}
function statusDisplay(r,v){
 v=n(v);if(v===null)return '—';
 return v>0?'ACTIVE':'OK';
}
function displayReading(r,v){
 if(r&&isThrottleStatus(r))return statusDisplay(r,v);
 return fmt(v,r?.Unit||'');
}
const n=v=>(v===null||v===undefined||!Number.isFinite(Number(v)))?null:Number(v);
const fmt=(v,u,compact=false)=>{v=n(v);if(v===null)return '—';let d=compact?(Math.abs(v)>=100?0:1):(Math.abs(v)>=1000?0:Math.abs(v)>=100?1:2);return `${v.toFixed(d)}${u?` ${u}`:''}`};
const qtile=(a,q)=>{const x=a.filter(Number.isFinite).slice().sort((a,b)=>a-b);if(!x.length)return null;if(x.length===1)return x[0];const p=(x.length-1)*q,l=Math.floor(p),h=Math.ceil(p);return x[l]+(x[h]-x[l])*(p-l)};
const calc=a=>{const v=a.map(x=>x.v).filter(Number.isFinite);return v.length?{cur:v.at(-1),min:Math.min(...v),max:Math.max(...v),avg:v.reduce((x,y)=>x+y,0)/v.length,count:v.length}:{cur:null,min:null,max:null,avg:null,count:0}};

function targetFrameMs(){const t=Number(S.targetFps);return Number.isFinite(t)&&t>0?1000/t:null}

function healthRule(r,value){
 if(!S.healthColors)return null;
 value=n(value);if(value===null||!r)return null;

 const t=readingText(r),unit=String(r.Unit||'').trim().toLowerCase();
 const target=Number(S.targetFps);
 const budget=Number.isFinite(target)&&target>0?1000/target:null;

 // Frame-budget health is optional. Target FPS = Off disables this entire block.
 if(budget!==null){
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
   if((unit==='ms'||unit==='milliseconds')&&/\bcpu busy\b|\bgpu busy\b/.test(t)){
     if(value>budget*1.15)return {level:'bad',reason:`Busy time exceeds 115% of ${budget.toFixed(2)} ms frame budget`};
     if(value>budget*.90)return {level:'warn',reason:`Busy time is using over 90% of ${budget.toFixed(2)} ms frame budget`};
     return null;
   }
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
 }

 // Wait times are diagnostic, not inherently good/bad.
 if(/\bcpu wait\b|\bgpu wait\b/.test(t))return null;

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

 // Ryzen resource-limit utilization: this is NOT throttling by itself.
 if((unit==='%'||unit==='percent')&&/^(thermal limit|cpu ppt limit|cpu tdc limit|cpu edc limit)$/.test(norm(r.Label||r.LabelOriginal||''))){
   if(value>=100)return {level:'bad',reason:'This CPU limit has reached 100% or more'};
   if(value>=90)return {level:'warn',reason:'This CPU limit is above 90%'};
   return null;
 }

 // Actual binary throttling / performance-limit indicators.
 if(/thermal throttling htc|thermal throttling prochot cpu|thermal throttling prochot ext|performance limit thermal|performance limit power/.test(t)){
   if(value>0)return {level:'bad',reason:'A real throttling / performance-limit signal is active'};
   return null;
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
 minFontPx:(()=>{const v=Number(localStorage.getItem('hpl-v672-min-font')||11);return Number.isFinite(v)?Math.min(16,Math.max(11,v)):11})(),
 healthColors:localStorage.getItem('hpl-v62-health-colors')!=='0',
 targetFps:(()=>{const v=localStorage.getItem('hpl-v62-target-fps');return v===null?60:Number(v)})(),
 pins:JSON.parse(localStorage.getItem('hpl-v5-pins')||localStorage.getItem('hpl-v4-pins')||'[]'),
 opts:JSON.parse(localStorage.getItem('hpl-v5-opts')||localStorage.getItem('hpl-v4-opts')||'{}'),
 pendingImport:null,
 overviewEditing:null,
 overviewDragKey:null,
 overviewConfig:JSON.parse(localStorage.getItem('hpl-v67-overview')||'null'),
 laps:[{id:1,start:Date.now()}],
 viewScope:'current',
 fpsAnalysis:{fps:[],ft:[],startedAt:Date.now()},
 pinnedVisible:localStorage.getItem('hpl-v69-pinned-visible')!=='0',
 fpsPosition:localStorage.getItem('hpl-v69-fps-position')==='above'?'above':'below',
 dragType:null,
 dragOriginalPins:null,
 dragDropped:false,
 pinPlaceholder:null,
 analysisRows:[],
 capFrameX:null,capFrameXInFlight:false,capFrameXTimer:null,cfxPlot:null,cfxHoverRatio:null
};

function toast(msg){const t=$('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._x);t._x=setTimeout(()=>t.style.display='none',3000)}
function save(){
 localStorage.setItem('hpl-v5-pins',JSON.stringify(S.pins));
 localStorage.setItem('hpl-v5-opts',JSON.stringify(S.opts));
 localStorage.setItem('hpl-v5-fps-source',S.fpsPref||'');
 localStorage.setItem('hpl-v5-ft-source',S.ftPref||'');
 localStorage.setItem('hpl-v5-theme',S.themePref||'system');
 localStorage.setItem('hpl-v672-min-font',String(S.minFontPx||11));
 localStorage.setItem('hpl-v62-health-colors',S.healthColors?'1':'0');
 localStorage.setItem('hpl-v62-target-fps',String(S.targetFps));
 localStorage.setItem('hpl-v67-overview',JSON.stringify(S.overviewConfig));
 localStorage.setItem('hpl-v69-pinned-visible',S.pinnedVisible?'1':'0');
 localStorage.setItem('hpl-v69-fps-position',S.fpsPosition);
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
function ensureOpt(k){
 const o=S.opts[k]||(S.opts[k]={mode:'current',graph:true,smooth:false,controlsVisible:true});
 if(o.mode==='all')o.mode='current';
 if(o.controlsVisible===undefined)o.controlsVisible=true;
 return o
}

function applyTheme(pref){
 S.themePref=pref||'system';$('theme').value=S.themePref;
 const effective=S.themePref==='system'?(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark'):S.themePref;
 document.documentElement.dataset.theme=effective;save();
 requestAnimationFrame(()=>document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key)));
}
matchMedia('(prefers-color-scheme: light)').addEventListener?.('change',()=>{if(S.themePref==='system')applyTheme('system')});

function applyTypographyScale(px){
 let value=Number(px);
 if(!Number.isFinite(value))value=11;
 value=Math.min(16,Math.max(11,value));
 S.minFontPx=value;
 const scale=value/11;
 document.documentElement.style.setProperty('--ui-min-font',`${value}px`);
 document.documentElement.style.setProperty('--ui-font-scale',String(scale));
 if($('minFontSize'))$('minFontSize').value=String(value);
 save();
 // Font changes alter card/chart geometry, so redraw charts after layout settles.
 requestAnimationFrame(()=>requestAnimationFrame(()=>{
   document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key));
 }));
}

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
 if(fps&&ft){
   st.className='source-state ok';
   const gl=overviewReading('gpulatency'),dl=overviewReading('displaylatency'),vr=overviewReading('vram');
   st.textContent=`FPS: ${fps.Label} • Frame time: ${ft.Label} • GPU latency: ${gl?gl.Label:'not exposed'} • Display latency: ${dl?dl.Label:'not exposed'} • VRAM: ${vr?vr.Label:'not exposed'}`;
 }
 else if(fps){st.className='source-state warn';st.textContent=`FPS found (${fps.Label}), but no frame-time source detected`}
 else{st.className='source-state warn';st.textContent='No FPS source detected yet — start the game and check HWiNFO PresentMon / FPS readings'}
}

function findRegex(arr){
 for(const re of arr){const r=(S.latest?.Readings||[]).find(x=>re.test(readingText(x)));if(r)return r}return null
}
function overviewReading(kind){
 const rs=S.latest?.Readings||[];
 const unit=r=>String(r.Unit||'').trim().toLowerCase();
 const txt=r=>readingText(r);
 const label=r=>norm(`${r.Label||''} ${r.LabelOriginal||''}`);
 const sensor=r=>norm(`${r.Sensor||''} ${r.SensorOriginal||''}`);

 const score=(r,tests)=>{
   let s=0;
   for(const [re,pts] of tests)if(re.test(txt(r)))s+=pts;
   return s;
 };

 // IMPORTANT:
 // A unit match can NEVER create a candidate. The reading first needs a positive
 // semantic match from its sensor/label text. This prevents e.g. any MB reading
 // becoming VRAM or any ms reading becoming PresentMon latency.
 const pick=(tests,unitTests=[],excludeTests=[])=>{
   let best=null,bestScore=-Infinity;
   for(const r of rs){
     if(excludeTests.some(re=>re.test(txt(r))))continue;
     let semantic=score(r,tests);
     if(semantic<=0)continue;

     let s=semantic;
     if(unitTests.length){
       const u=unit(r);
       if(unitTests.some(x=>x.test(u)))s+=35;
       else s-=35;
     }
     if(s>bestScore){best=r;bestScore=s}
   }
   return best;
 };

 // For status metrics we require explicit "limited/throttling" semantics rather
 // than generic "... Limit %" headroom/utilization readings.
 const pickStatus=(tests)=>{
   let best=null,bestScore=-Infinity;
   for(const r of rs){
     let s=score(r,tests);
     if(s<=0)continue;
     const l=label(r);
     if(/\blimit\b/.test(l)&&!/\blimited\b|throttl|prochot|performance limit/.test(l))continue;
     if(s>bestScore){best=r;bestScore=s}
   }
   return best;
 };

 switch(kind){
  case 'gpu':
   return pick([[/\bgpu core load\b/,120],[/\bgpu utilization\b/,110],[/\bgpu load\b/,90]],[/^%$/,/percent/],[/memory|video engine|media/]);
  case 'gt':
   return pick([[/\bgpu temperature\b/,120],[/\bgpu.*core.*temperature\b/,115],[/\bgpu temp\b/,100],[/hot ?spot|junction/,-120]],[/°c/,/^c$/]);
  case 'ghot':
   return pick([[/gpu.*hot ?spot/,140],[/hot ?spot.*temperature/,130],[/gpu.*junction.*temperature/,125],[/junction temperature/,105]],[/°c/,/^c$/]);
  case 'gp':
   return pick([
     [/\bgpu asic power\b/,150],[/\bgpu total board power\b/,145],[/\btotal board power\b/,140],
     [/\bgpu board power\b/,135],[/\bgpu chip power\b/,130],[/\bgpu power\b/,125],
     [/\bgraphics power\b/,110],[/\bgpu ppt\b/,95]
   ],[/^w$/,/watt/],[/memory power/]);
  case 'gc':
   return pick([[/\bgpu core clock\b/,140],[/\bgpu clock\b/,130],[/\bgraphics clock\b/,120]],[/mhz/,/ghz/],[/memory/]);
  case 'gmc':
   return pick([[/\bgpu memory clock\b/,145],[/\bvram.*clock\b/,135],[/\bmemory clock\b/,90]],[/mhz/,/ghz/],[/system|physical memory/]);
  case 'gfan':
   return pick([[/\bgpu fan speed\b/,145],[/\bgpu fan\b/,135],[/\bfan.*gpu\b/,125]],[/rpm/,/^%$/,/percent/]);

  case 'cpumax':
   return pick([[/\bmax cpu thread usage\b/,150],[/\bmaximum cpu thread usage\b/,145],[/\bmax cpu core usage\b/,135],[/\bmaximum cpu core usage\b/,130]],[/^%$/,/percent/]);
  case 'cpu':
   return pick([[/\btotal cpu usage\b/,150],[/\bcpu total\b/,125],[/\bcpu usage\b/,85]],[/^%$/,/percent/],[/core \d|thread \d/]);
  case 'ct':
   return pick([[/\bcpu tctl tdie\b/,155],[/\bcpu package temperature\b/,150],[/\bcpu temperature\b/,125]],[/°c/,/^c$/],[/ccd|core \d/]);
  case 'cp':
   return pick([[/\bcpu package power\b/,155],[/\bpackage power\b/,135],[/\bcpu power\b/,110]],[/^w$/,/watt/]);
  case 'cc':
   return pick([[/\bcore effective clocks.*avg\b/,155],[/\baverage effective clock\b/,150],[/\bcore effective clock\b/,115]],[/mhz/,/ghz/]);

  case 'thermallimit':
   return pick([[/^thermal limit$/,190],[/\bcpu.*thermal limit\b/,155]],[/^%$/,/percent/],[/throttl|limited/]);
  case 'pptlimit':
   return pick([[/^cpu ppt limit$/,200],[/\bcpu ppt limit\b/,180],[/\bppt limit\b/,140]],[/^%$/,/percent/],[/limited/]);
  case 'tdclimit':
   return pick([[/^cpu tdc limit$/,200],[/\bcpu tdc limit\b/,180],[/\btdc limit\b/,140]],[/^%$/,/percent/],[/limited/]);
  case 'edclimit':
   return pick([[/^cpu edc limit$/,200],[/\bcpu edc limit\b/,180],[/\bedc limit\b/,140]],[/^%$/,/percent/],[/limited/]);

  case 'htc':
   return pickStatus([[/thermal throttling htc/,220]]);
  case 'prochotcpu':
   return pickStatus([[/thermal throttling prochot cpu/,220]]);
  case 'prochotext':
   return pickStatus([[/thermal throttling prochot ext/,220]]);

  case 'ramload':
   return pick([[/\bphysical memory load\b/,160],[/\bram load\b/,140]],[/^%$/,/percent/],[/gpu|vram|virtual memory/]);
  case 'ramused':
   return pick([[/\bphysical memory used\b/,160],[/\bram used\b/,140]],[/mb/,/gb/],[/gpu|vram|virtual memory/]);
  case 'ramavail':
   return pick([[/\bavailable physical memory\b/,170],[/\bphysical memory available\b/,165],[/\bram available\b/,140]],[/mb/,/gb/],[/gpu|vram|virtual memory/]);
  case 'committed':
   return pick([[/\bcommitted memory\b/,150],[/\bcommit charge\b/,130],[/\bvirtual memory committed\b/,120]],[/mb/,/gb/,/^%$/,/percent/],[/gpu|vram/]);

  // VRAM must explicitly say GPU/Dedicated/Video/VRAM memory.
  // Generic "Memory Used", "Virtual Memory" and System readings are intentionally excluded.
  case 'vram':
   return pick([
     [/\bgpu memory allocated\b/,180],[/\bgpu memory used\b/,175],[/\bgpu memory usage\b/,170],
     [/\bdedicated gpu memory\b/,165],[/\bdedicated memory usage\b/,155],
     [/\bvideo memory used\b/,155],[/\bvram used\b/,175],[/\bvram usage\b/,165]
   ],[/mb/,/gb/],[/virtual memory|physical memory|system memory|page file|committed/]);

  case 'vramload':
   return pick([
     [/\bgpu memory load\b/,180],[/\bgpu memory utilization\b/,175],
     [/\bvram load\b/,180],[/\bvram utilization\b/,175],
     [/\bdedicated memory utilization\b/,160]
   ],[/^%$/,/percent/],[/virtual memory|physical memory|system memory|page file/]);

  case 'pagefile':
   return pick([[/\bpage file usage\b/,160],[/\bpagefile usage\b/,155],[/\bpage file\b/,105]],[/^%$/,/percent/,/mb/,/gb/]);
  case 'memerrors':
   return pick([[/\bmemory errors\b/,150],[/\becc.*error\b/,140],[/\bwhea.*memory\b/,130]]);

  case 'cpubusy':
   return pick([[/\bcpu busy\b/,170]],[/^ms$/,/milliseconds/],[/gpu/]);
  case 'cpuwait':
   return pick([[/\bcpu wait\b/,170]],[/^ms$/,/milliseconds/],[/gpu/]);
  case 'gbusy':
   return pick([[/\bgpu busy\b/,170]],[/^ms$/,/milliseconds/],[/cpu/]);
  case 'gpuwait':
   return pick([[/\bgpu wait\b/,170]],[/^ms$/,/milliseconds/],[/cpu/]);

  // Latency mappings are intentionally strict. If HWiNFO does not expose the
  // exact PresentMon metric, return null instead of falling back to Frame Time.
  case 'gpulatency':
   return pick([[/\bgpu latency\b/,200],[/\bpresentmon.*gpu latency\b/,220]],[/^ms$/,/milliseconds/],[/frame time|frametime|display latency/]);
  case 'displaylatency':
   return pick([[/\bdisplay latency\b/,220],[/\bpresentmon.*display latency\b/,240]],[/^ms$/,/milliseconds/],[/frame time|frametime|gpu latency|render present latency/]);

  // Actual "Limited" status signals.
  case 'gpupowerlimited':
   return pickStatus([[/\bgpu power limited\b/,230],[/\bperformance limit.*power\b/,210],[/\bpower throttling\b/,190]]);
  case 'gputemplimited':
   return pickStatus([[/\bgpu temperature limited\b/,230],[/\bperformance limit.*thermal\b/,210],[/\bgpu thermal throttling\b/,210]]);
  case 'gpucurrentlimited':
   return pickStatus([[/\bgpu current limited\b/,230],[/\bperformance limit.*current\b/,210]]);
  case 'gpuvoltagelimited':
   return pickStatus([[/\bgpu voltage limited\b/,230],[/\bperformance limit.*voltage\b/,210]]);

  // Headroom/utilization-style percentage readings are kept separate from status.
  case 'gputhermallimitpct':
   return pick([
     [/\bgpu edge thermal limit\b/,220],[/\bgpu hot ?spot thermal limit\b/,215],
     [/\bgpu junction thermal limit\b/,210],[/\bgpu thermal limit\b/,170]
   ],[/^%$/,/percent/],[/limited|throttl/]);
  case 'gpupowerlimitpct':
   return pick([
     [/\bgpu power limit\b/,190],[/\bgpu ppt limit\b/,180],[/\bgpu power percent\b/,160]
   ],[/^%$/,/percent/],[/limited|throttl/]);
 }
 return null;
}

function actualCpuThrottleStatus(){
 const signals=[
   overviewReading('htc'),
   overviewReading('prochotcpu'),
   overviewReading('prochotext')
 ].filter(Boolean);
 if(!signals.length)return {display:'—',level:null,reason:'No supported CPU thermal-throttling status sensor found',reading:null};
 const active=signals.find(r=>n(r.Value)!==null&&n(r.Value)>0);
 if(active)return {display:'ACTIVE',level:'bad',reason:`${active.Label} is active`,reading:active};
 return {display:'OK',level:null,reason:'HTC / PROCHOT thermal-protection signals are inactive',reading:signals[0]};
}

function actualGpuThrottleStatus(){
 const explicit=[
   overviewReading('gputemplimited')
 ].filter(Boolean);

 if(!explicit.length)
   return {display:'—',level:null,reason:'No explicit GPU thermal-throttling / Temperature Limited status is exposed',reading:null};

 const active=explicit.find(r=>n(r.Value)!==null&&n(r.Value)>0);
 if(active)return {display:'ACTIVE',level:'bad',reason:`${active.Label} is active`,reading:active};
 return {display:'OK',level:null,reason:'Explicit GPU thermal-throttling status is inactive',reading:explicit[0]};
}

const OVERVIEW_DEFS={
 gaming:[
  {key:'fps',label:'FPS',desc:'Current PresentMon FPS',get:()=>selectedSource('fps')},
  {key:'frametime',label:'Frame time',desc:'Frame delivery time',get:()=>selectedSource('ft')},
  {key:'cpubusy',label:'CPU busy',desc:'CPU work time per sampled frame',kind:'cpubusy'},
  {key:'cpuwait',label:'CPU wait',desc:'CPU wait time',kind:'cpuwait'},
  {key:'gpubusy',label:'GPU busy',desc:'GPU work time per sampled frame',kind:'gbusy'},
  {key:'gpuwait',label:'GPU wait',desc:'GPU idle/wait time',kind:'gpuwait'},
  {key:'gpulatency',label:'GPU latency',desc:'PresentMon GPU latency',kind:'gpulatency'},
  {key:'displaylatency',label:'Display latency',desc:'PresentMon display latency',kind:'displaylatency'}
 ],
 gpu:[
  {key:'load',label:'Load',desc:'GPU core utilization',kind:'gpu'},
  {key:'temperature',label:'Temperature',desc:'GPU core temperature',kind:'gt'},
  {key:'hotspot',label:'Hotspot',desc:'GPU hotspot / junction temperature',kind:'ghot'},
  {key:'power',label:'Power',desc:'ASIC / board / chip power',kind:'gp'},
  {key:'coreclock',label:'Core clock',desc:'GPU core clock',kind:'gc'},
  {key:'memoryclock',label:'Memory clock',desc:'VRAM clock',kind:'gmc'},
  {key:'fan',label:'Fan',desc:'GPU fan speed',kind:'gfan'},
  {key:'throttling',label:'Thermal throttling',desc:'Actual thermal-protection/throttle state',status:actualGpuThrottleStatus}
 ],
 cpu:[
  {key:'usage',label:'Total usage',desc:'Total CPU utilization',kind:'cpu'},
  {key:'maxthread',label:'Max thread',desc:'Most-loaded CPU thread/core',kind:'cpumax'},
  {key:'temperature',label:'Temperature',desc:'CPU package/Tctl temperature',kind:'ct'},
  {key:'power',label:'Package power',desc:'CPU package power',kind:'cp'},
  {key:'clock',label:'Effective clock',desc:'Effective CPU clock',kind:'cc'},
  {key:'throttling',label:'Thermal throttling',desc:'Actual HTC / PROCHOT protection state',status:actualCpuThrottleStatus},
  {key:'thermallimit',label:'Thermal limit',desc:'Proximity to thermal limit; not throttling',kind:'thermallimit'},
  {key:'ppt',label:'PPT limit',desc:'Package Power Tracking utilization',kind:'pptlimit'},
  {key:'tdc',label:'TDC limit',desc:'Sustained current-limit utilization',kind:'tdclimit'},
  {key:'edc',label:'EDC limit',desc:'Peak current-limit utilization',kind:'edclimit'}
 ],
 memory:[
  {key:'ramload',label:'RAM load',desc:'Physical memory utilization',kind:'ramload'},
  {key:'ramused',label:'RAM used',desc:'Used physical memory',kind:'ramused'},
  {key:'ramavail',label:'RAM available',desc:'Available physical memory',kind:'ramavail'},
  {key:'committed',label:'Committed',desc:'Committed memory',kind:'committed'},
  {key:'vramused',label:'VRAM used',desc:'Dedicated GPU memory used',kind:'vram'},
  {key:'vramload',label:'VRAM load',desc:'Video memory pressure',kind:'vramload'},
  {key:'pagefile',label:'Page file',desc:'Page-file usage',kind:'pagefile'},
  {key:'memerrors',label:'Memory errors',desc:'ECC/WHEA memory errors when exposed',kind:'memerrors'}
 ]
};

const OVERVIEW_DEFAULTS={
 gaming:['fps','frametime','cpubusy','cpuwait','gpubusy','gpuwait','gpulatency','displaylatency'],
 gpu:['load','temperature','hotspot','power','coreclock','memoryclock','fan','throttling'],
 cpu:['usage','maxthread','temperature','power','clock','throttling','ppt'],
 memory:['ramload','ramused','ramavail','committed','vramused','vramload','pagefile']
};

function ensureOverviewConfig(){
 if(!S.overviewConfig||typeof S.overviewConfig!=='object')S.overviewConfig={};
 for(const cat of Object.keys(OVERVIEW_DEFS)){
   const allowed=new Set(OVERVIEW_DEFS[cat].map(x=>x.key));
   let arr=Array.isArray(S.overviewConfig[cat])?S.overviewConfig[cat].filter(k=>allowed.has(k)):[...OVERVIEW_DEFAULTS[cat]];
   // Keep unique values.
   arr=[...new Set(arr)];
   S.overviewConfig[cat]=arr;
 }
}

function overviewDef(cat,key){return (OVERVIEW_DEFS[cat]||[]).find(x=>x.key===key)||null}

function overviewMetricHtml(cat,key){
 const def=overviewDef(cat,key);if(!def)return '';
 return `<div class="cat-metric" draggable="true" data-overview-item="${cat}:${key}" title="${esc(def.desc||'')}"><div class="k">${esc(def.label)}</div><div class="v" data-overview-value="${cat}:${key}">—</div></div>`;
}

function renderOverviewStructure(){
 ensureOverviewConfig();
 for(const cat of Object.keys(OVERVIEW_DEFS)){
   const host=document.querySelector(`[data-overview-metrics="${cat}"]`);if(!host)continue;
   const wanted=S.overviewConfig[cat]||[];
   const signature=wanted.join('|');
   if(host.dataset.signature===signature)continue;
   host.dataset.signature=signature;
   host.innerHTML=wanted.map(k=>overviewMetricHtml(cat,k)).join('')||'<div class="cat-metric"><div class="k">No metrics</div><div class="v">—</div></div>';
 }
 bindOverviewDnD();
}

function resolveOverviewValue(def){
 if(!def)return {display:'—',reading:null,value:null,status:null};
 if(def.status){
   const s=def.status();
   return {display:s.display,reading:s.reading,value:s.reading?n(s.reading.Value):null,status:s};
 }
 const r=def.get?def.get():overviewReading(def.kind);
 return {display:r?displayReading(r,r.Value):'—',reading:r,value:r?n(r.Value):null,status:null};
}

function updateOverview(){
 renderOverviewStructure();
 for(const cat of Object.keys(OVERVIEW_DEFS)){
   for(const key of S.overviewConfig[cat]||[]){
     const def=overviewDef(cat,key),el=document.querySelector(`[data-overview-value="${cat}:${key}"]`);
     if(!el||!def)continue;
     clearHealth(el);
     const x=resolveOverviewValue(def);
     el.textContent=x.display;
     if(x.status){
       if(x.status.level){
         el.classList.add(x.status.level==='bad'?'health-bad':'health-warn');
         if(x.status.reason){el.title=x.status.reason;el.dataset.healthTitle='1'}
       }else if(x.status.reason){el.title=x.status.reason;el.dataset.healthTitle='1'}
     }else if(x.reading)applyHealth(el,x.reading,x.value);
   }
 }
 $('gamingTargetLabel').textContent=Number(S.targetFps)>0
   ?`PresentMon frame pipeline • target ${S.targetFps} FPS`
   :'PresentMon frame pipeline • target off';
}

function bindOverviewDnD(){
 document.querySelectorAll('[data-overview-item]').forEach(el=>{
   el.ondragstart=e=>{
     S.overviewDragKey=el.dataset.overviewItem;
     el.classList.add('overview-dragging');
     e.dataTransfer.setData('text/plain',S.overviewDragKey);
     e.dataTransfer.effectAllowed='move';
   };
   el.ondragend=()=>{
     S.overviewDragKey=null;
     document.querySelectorAll('.cat-metric').forEach(x=>x.classList.remove('overview-dragging','overview-drop-target'));
   };
   el.ondragover=e=>{
     const [cat]=el.dataset.overviewItem.split(':');
     if(S.overviewDragKey?.startsWith(cat+':')){e.preventDefault();el.classList.add('overview-drop-target')}
   };
   el.ondragleave=()=>el.classList.remove('overview-drop-target');
   el.ondrop=e=>{
     e.preventDefault();el.classList.remove('overview-drop-target');
     const from=e.dataTransfer.getData('text/plain')||S.overviewDragKey;
     const to=el.dataset.overviewItem;
     if(!from||!to)return;
     const [fc,fk]=from.split(':'),[tc,tk]=to.split(':');
     if(fc!==tc||fk===tk)return;
     const arr=(S.overviewConfig[fc]||[]).filter(x=>x!==fk);
     const i=arr.indexOf(tk);arr.splice(i<0?arr.length:i,0,fk);
     S.overviewConfig[fc]=arr;save();renderOverviewStructure();updateOverview();
   };
 });
}

function openOverviewEditor(cat){
 ensureOverviewConfig();S.overviewEditing=cat;
 const titles={gaming:'Gaming',gpu:'GPU',cpu:'CPU',memory:'Memory'};
 $('overviewEditorTitle').textContent=`Edit ${titles[cat]} overview`;
 $('overviewEditorSubtitle').textContent='Choose metrics and drag rows to change their order.';
 renderOverviewEditorList();
 $('overviewEditorBackdrop').classList.remove('hidden');
}
function closeOverviewEditor(){S.overviewEditing=null;$('overviewEditorBackdrop').classList.add('hidden')}

function renderOverviewEditorList(){
 const cat=S.overviewEditing;if(!cat)return;
 const selected=S.overviewConfig[cat]||[],defs=OVERVIEW_DEFS[cat]||[];
 const ordered=[...selected.map(k=>overviewDef(cat,k)).filter(Boolean),...defs.filter(d=>!selected.includes(d.key))];
 $('overviewEditorList').innerHTML=ordered.map(d=>`
   <label class="overview-choice" draggable="true" data-editor-key="${d.key}">
    <span class="handle">⠿</span>
    <span class="copy"><strong>${esc(d.label)}</strong><small>${esc(d.desc||'')}</small></span>
    <input type="checkbox" ${selected.includes(d.key)?'checked':''} data-editor-toggle="${d.key}">
   </label>`).join('');
 $('overviewEditorList').querySelectorAll('[data-editor-toggle]').forEach(input=>{
   input.onchange=()=>{
     const key=input.dataset.editorToggle,arr=S.overviewConfig[cat]||[];
     if(input.checked&&!arr.includes(key))arr.push(key);
     if(!input.checked)S.overviewConfig[cat]=arr.filter(x=>x!==key);
     else S.overviewConfig[cat]=arr;
     save();renderOverviewStructure();updateOverview();
   };
 });
 $('overviewEditorList').querySelectorAll('[data-editor-key]').forEach(row=>{
   row.ondragstart=e=>{e.dataTransfer.setData('text/plain',row.dataset.editorKey);row.classList.add('overview-dragging')};
   row.ondragend=()=>row.classList.remove('overview-dragging');
   row.ondragover=e=>{e.preventDefault();row.classList.add('overview-drop-target')};
   row.ondragleave=()=>row.classList.remove('overview-drop-target');
   row.ondrop=e=>{
     e.preventDefault();row.classList.remove('overview-drop-target');
     const from=e.dataTransfer.getData('text/plain'),to=row.dataset.editorKey;
     if(!from||from===to)return;
     const arr=S.overviewConfig[cat]||[];
     if(!arr.includes(from)||!arr.includes(to))return;
     const next=arr.filter(x=>x!==from),i=next.indexOf(to);next.splice(i<0?next.length:i,0,from);
     S.overviewConfig[cat]=next;save();renderOverviewEditorList();renderOverviewStructure();updateOverview();
   };
 });
}

document.querySelectorAll('[data-edit-overview]').forEach(b=>b.addEventListener('click',()=>openOverviewEditor(b.dataset.editOverview)));
$('overviewEditorClose').addEventListener('click',closeOverviewEditor);
$('overviewEditorDone').addEventListener('click',closeOverviewEditor);
$('overviewEditorBackdrop').addEventListener('click',e=>{if(e.target===$('overviewEditorBackdrop'))closeOverviewEditor()});
$('overviewEditorReset').addEventListener('click',()=>{
 const cat=S.overviewEditing;if(!cat)return;
 S.overviewConfig[cat]=[...OVERVIEW_DEFAULTS[cat]];save();renderOverviewEditorList();renderOverviewStructure();updateOverview();
});


function currentLap(){return S.laps[S.laps.length-1]||{id:1,start:S.sessionStart}}

function formatDuration(ms){
 const s=Math.max(0,Math.floor(ms/1000)),h=Math.floor(s/3600),m=Math.floor((s%3600)/60),ss=s%60;
 return h?`${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:${String(ss).padStart(2,'0')}`:`${String(m).padStart(2,'0')}:${String(ss).padStart(2,'0')}`;
}

function scopeRange(){
 const now=Date.now();
 if(S.viewScope==='all')return {start:S.sessionStart,end:now,label:'All session',historical:false};
 if(S.viewScope==='current'){
   const lap=currentLap();
   return {start:lap.start,end:now,label:`Current lap · Lap ${lap.id}`,historical:false,lapId:lap.id};
 }
 const m=/^lap:(\d+)$/.exec(S.viewScope||'');
 if(m){
   const id=Number(m[1]),i=S.laps.findIndex(l=>l.id===id);
   if(i>=0){
     const lap=S.laps[i],end=i+1<S.laps.length?S.laps[i+1].start:now;
     return {start:lap.start,end,label:`Lap ${lap.id}`,historical:i<S.laps.length-1,lapId:lap.id};
   }
 }
 const lap=currentLap();
 S.viewScope='current';
 return {start:lap.start,end:now,label:`Current lap · Lap ${lap.id}`,historical:false,lapId:lap.id};
}

function scopedArray(arr){
 const rg=scopeRange();
 return (arr||[]).filter(p=>p.t>=rg.start&&p.t<=rg.end);
}
function scopedHistory(k){return scopedArray(S.histories.get(k)||[])}

function syncLapSelector(){
 const el=$('lapView');if(!el)return;
 const value=S.viewScope||'current';
 const previous=S.laps.slice(0,-1);
 el.innerHTML=`<option value="current">Lap ${currentLap().id}</option><option value="all">All session</option>`+
   previous.map(l=>`<option value="lap:${l.id}">Lap ${l.id}</option>`).join('');
 el.value=[...el.options].some(o=>o.value===value)?value:'current';
 if(el.value!==value)S.viewScope='current';
 updateScopeLabels();
}
function updateScopeLabels(){
 const rg=scopeRange();
 if($('fpsScopeLabel'))$('fpsScopeLabel').textContent=rg.label;
}
function setViewScope(value){
 S.viewScope=value||'current';
 syncLapSelector();
 updateDynamic();
}

function applyPinnedVisibility(){
 const section=$('pinnedSection'),btn=$('togglePinnedSection');
 if(!section||!btn)return;
 section.classList.toggle('section-hidden',!S.pinnedVisible);
 btn.textContent=S.pinnedVisible?'Hide pinned':'Show pinned';
 btn.setAttribute('aria-pressed',S.pinnedVisible?'false':'true');
}
function togglePinnedVisibility(){
 S.pinnedVisible=!S.pinnedVisible;save();applyPinnedVisibility();
}

function applySectionOrder(){
 const pinned=$('pinnedSection'),fps=$('fpsSection');
 if(!pinned||!fps||!pinned.parentNode)return;
 if(S.fpsPosition==='above'){
   if(fps.nextElementSibling!==pinned)pinned.before(fps);
 }else{
   if(pinned.nextElementSibling!==fps)pinned.after(fps);
 }
 const btn=$('moveFpsSection');
 if(btn)btn.textContent=S.fpsPosition==='above'?'Move down':'Move up';
}
function toggleFpsPosition(){
 S.fpsPosition=S.fpsPosition==='above'?'below':'above';
 save();applySectionOrder();
}

function newLap(){
 const now=Date.now();
 const last=currentLap();
 // Avoid accidental double-click laps separated by less than one second.
 if(last&&now-last.start<1000){toast('Current lap just started');return}
 const id=(last?.id||0)+1;
 S.laps.push({id,start:now});
 if(S.viewScope==='current')S.viewScope='current';
 syncLapSelector();
 updateDynamic();
 toast(`Lap ${id} started`);
}

function resetLapState(){
 const now=Date.now();
 S.laps=[{id:1,start:now}];
 S.viewScope='current';
 syncLapSelector();
}

function resetLapsOnly(){
 if(!confirm('Delete all lap markers and start again at Lap 1 now? Full-session telemetry history will stay available under All session.'))return;
 const now=Date.now();
 S.laps=[{id:1,start:now}];
 S.viewScope='current';
 syncLapSelector();
 updateDynamic();
 toast('Laps reset · fresh Lap 1 started');
}

function resetFpsAnalysis(confirmFirst=true){
 if(confirmFirst&&!confirm('Reset only FPS / frame-time analysis? Pinned telemetry, session history and laps will stay untouched.'))return;
 S.fpsAnalysis={fps:[],ft:[],startedAt:Date.now()};
 updateFps();
 toast('FPS analysis reset');
}

function fpsAnalysisArray(type){
 return scopedArray(S.fpsAnalysis?.[type]||[]);
}

function scopedCurrentValue(k,r){
 const rg=scopeRange();
 if(!rg.historical)return r?.Value;
 const a=scopedHistory(k);
 return a.length?a[a.length-1].v:null;
}

function scopeStatLabel(kind){
 const rg=scopeRange();
 if(S.viewScope==='all')return `Session ${kind}`;
 if(rg.historical)return `Lap ${rg.lapId} ${kind}`;
 return `Lap ${kind}`;
}

const ANALYSIS_METRICS=[
 {key:'fps',label:'Presented FPS',unit:'FPS',group:'frame',get:()=>selectedSource('fps')},
 {key:'frame_time_ms',label:'Frame Time',unit:'ms',group:'frame',get:()=>selectedSource('ft')},
 {key:'cpu_busy_ms',label:'CPU Busy',unit:'ms',group:'pipeline',kind:'cpubusy'},
 {key:'cpu_wait_ms',label:'CPU Wait',unit:'ms',group:'pipeline',kind:'cpuwait'},
 {key:'gpu_busy_ms',label:'GPU Busy',unit:'ms',group:'pipeline',kind:'gbusy'},
 {key:'gpu_wait_ms',label:'GPU Wait',unit:'ms',group:'pipeline',kind:'gpuwait'},
 {key:'gpu_latency_ms',label:'GPU Latency',unit:'ms',group:'pipeline',kind:'gpulatency'},
 {key:'display_latency_ms',label:'Display Latency',unit:'ms',group:'pipeline',kind:'displaylatency'},

 {key:'gpu_util_pct',label:'GPU Utilization',unit:'%',group:'gpu',kind:'gpu'},
 {key:'gpu_temp_c',label:'GPU Temperature',unit:'°C',group:'gpu',kind:'gt'},
 {key:'gpu_hotspot_c',label:'GPU Hotspot',unit:'°C',group:'gpu',kind:'ghot'},
 {key:'gpu_power_w',label:'GPU Power',unit:'W',group:'gpu',kind:'gp'},
 {key:'gpu_clock_mhz',label:'GPU Core Clock',unit:'MHz',group:'gpu',kind:'gc'},
 {key:'gpu_memory_clock_mhz',label:'GPU Memory Clock',unit:'MHz',group:'gpu',kind:'gmc'},
 {key:'gpu_fan',label:'GPU Fan',unit:null,group:'gpu',kind:'gfan'},
 {key:'gpu_power_limited',label:'GPU Power Limited',unit:null,group:'gpu_limit',kind:'gpupowerlimited'},
 {key:'gpu_temp_limited',label:'GPU Temperature Limited',unit:null,group:'gpu_limit',kind:'gputemplimited'},
 {key:'gpu_current_limited',label:'GPU Current Limited',unit:null,group:'gpu_limit',kind:'gpucurrentlimited'},
 {key:'gpu_voltage_limited',label:'GPU Voltage Limited',unit:null,group:'gpu_limit',kind:'gpuvoltagelimited'},
 {key:'gpu_thermal_limit_pct',label:'GPU Thermal Limit Utilization',unit:'%',group:'gpu_limit',kind:'gputhermallimitpct'},
 {key:'gpu_power_limit_pct',label:'GPU Power Limit Utilization',unit:'%',group:'gpu_limit',kind:'gpupowerlimitpct'},

 {key:'cpu_total_pct',label:'CPU Total Usage',unit:'%',group:'cpu',kind:'cpu'},
 {key:'cpu_max_thread_pct',label:'CPU Max Thread Usage',unit:'%',group:'cpu',kind:'cpumax'},
 {key:'cpu_temp_c',label:'CPU Temperature',unit:'°C',group:'cpu',kind:'ct'},
 {key:'cpu_package_power_w',label:'CPU Package Power',unit:'W',group:'cpu',kind:'cp'},
 {key:'cpu_effective_clock_mhz',label:'CPU Effective Clock',unit:'MHz',group:'cpu',kind:'cc'},
 {key:'cpu_thermal_limit_pct',label:'CPU Thermal Limit',unit:'%',group:'cpu_limit',kind:'thermallimit'},
 {key:'cpu_ppt_limit_pct',label:'CPU PPT Limit',unit:'%',group:'cpu_limit',kind:'pptlimit'},
 {key:'cpu_tdc_limit_pct',label:'CPU TDC Limit',unit:'%',group:'cpu_limit',kind:'tdclimit'},
 {key:'cpu_edc_limit_pct',label:'CPU EDC Limit',unit:'%',group:'cpu_limit',kind:'edclimit'},
 {key:'cpu_throttle_htc',label:'CPU Thermal Throttling HTC',unit:null,group:'cpu_limit',kind:'htc'},
 {key:'cpu_prochot',label:'CPU PROCHOT',unit:null,group:'cpu_limit',kind:'prochotcpu'},
 {key:'cpu_prochot_ext',label:'CPU PROCHOT EXT',unit:null,group:'cpu_limit',kind:'prochotext'},

 {key:'ram_load_pct',label:'RAM Load',unit:'%',group:'memory',kind:'ramload'},
 {key:'ram_used',label:'RAM Used',unit:null,group:'memory',kind:'ramused'},
 {key:'ram_available',label:'RAM Available',unit:null,group:'memory',kind:'ramavail'},
 {key:'memory_committed',label:'Committed Memory',unit:null,group:'memory',kind:'committed'},
 {key:'vram_used',label:'VRAM Used',unit:null,group:'memory',kind:'vram'},
 {key:'vram_load_pct',label:'VRAM Load',unit:'%',group:'memory',kind:'vramload'},
 {key:'pagefile',label:'Page File',unit:null,group:'memory',kind:'pagefile'},
 {key:'memory_errors',label:'Memory Errors',unit:null,group:'memory',kind:'memerrors'}
];

function analysisMetricReading(def){
 return def.get?def.get():overviewReading(def.kind);
}

function metricMappingStatus(def,r){
 if(!r)return {status:'missing',confidence:'none',reason:'No semantically matching HWiNFO reading found'};
 const t=readingText(r),l=norm(`${r.Label||''} ${r.LabelOriginal||''}`),u=norm(r.Unit);

 // Defensive post-validation for the metrics that caused real-world false mappings.
 if(def.key==='vram_used'||def.key==='vram_load_pct'){
   if(/virtual memory|physical memory|system memory|page file|committed/.test(t))
     return {status:'rejected',confidence:'none',reason:'Rejected system/virtual-memory source for a VRAM metric'};
   if(!/gpu memory|dedicated.*memory|video memory|vram/.test(t))
     return {status:'rejected',confidence:'none',reason:'VRAM metric requires explicit GPU/dedicated/video-memory semantics'};
 }
 if(def.key==='gpu_latency_ms'){
   if(!/\bgpu latency\b/.test(t))
     return {status:'rejected',confidence:'none',reason:'GPU Latency requires an explicit GPU Latency reading; Frame Time is not accepted'};
 }
 if(def.key==='display_latency_ms'){
   if(!/\bdisplay latency\b/.test(t))
     return {status:'rejected',confidence:'none',reason:'Display Latency requires an explicit Display Latency reading; Frame Time is not accepted'};
 }
 if(def.key==='gpu_temp_limited'){
   if(!/temperature limited|performance limit.*thermal|thermal throttling/.test(t))
     return {status:'rejected',confidence:'none',reason:'Generic Thermal Limit % is utilization/headroom, not a Temperature Limited status'};
 }
 if(def.key==='gpu_power_limited'){
   if(!/power limited|performance limit.*power|power throttling/.test(t))
     return {status:'rejected',confidence:'none',reason:'Generic Power Limit % is utilization/headroom, not a Power Limited status'};
 }

 return {status:'mapped',confidence:'high',reason:null};
}

function verifiedAnalysisReading(def){
 const r=analysisMetricReading(def);
 const m=metricMappingStatus(def,r);
 return m.status==='mapped'?r:null;
}
function activeLapIdAt(t){
 let id=1;
 for(const lap of S.laps){if(t>=lap.start)id=lap.id;else break}
 return id;
}
function sampleAnalysisTelemetry(now=Date.now()){
 if(!S.latest?.Ok)return;
 const values={};
 for(const def of ANALYSIS_METRICS){
   const r=verifiedAnalysisReading(def);
   const v=r?n(r.Value):null;
   values[def.key]=v;
 }
 S.analysisRows.push({t:now,lapId:activeLapIdAt(now),values});
}
function analysisRowsForScope(){
 const rg=scopeRange();
 return (S.analysisRows||[]).filter(row=>row.t>=rg.start&&row.t<=rg.end);
}
function metricValues(rows,key){
 return rows.map(r=>n(r.values?.[key])).filter(Number.isFinite);
}
function median(a){return qtile(a,.5)}
function avg(a){return a.length?a.reduce((x,y)=>x+y,0)/a.length:null}
function maxv(a){return a.length?Math.max(...a):null}
function minv(a){return a.length?Math.min(...a):null}
function pctWhere(a,fn){return a.length?100*a.filter(fn).length/a.length:null}
function statPack(a){
 return {
   count:a.length,
   min:minv(a),max:maxv(a),avg:avg(a),median:median(a),
   p01:a.length?qtile(a,.001):null,p1:a.length?qtile(a,.01):null,p5:a.length?qtile(a,.05):null,
   p95:a.length?qtile(a,.95):null,p99:a.length?qtile(a,.99):null
 };
}
function medianInterval(rows){
 if(rows.length<2)return null;
 const d=[];for(let i=1;i<rows.length;i++)d.push(rows[i].t-rows[i-1].t);
 return median(d);
}
function analysisSummary(rows=analysisRowsForScope()){
 const get=k=>metricValues(rows,k);
 const fps=get('fps'),ft=get('frame_time_ms'),cb=get('cpu_busy_ms'),gb=get('gpu_busy_ms');
 const gpu=get('gpu_util_pct'),gtemp=get('gpu_temp_c'),ghot=get('gpu_hotspot_c'),gp=get('gpu_power_w');
 const cthread=get('cpu_max_thread_pct'),ctemp=get('cpu_temp_c'),cp=get('cpu_package_power_w');
 const ppt=get('cpu_ppt_limit_pct'),tdc=get('cpu_tdc_limit_pct'),edc=get('cpu_edc_limit_pct');
 const htc=get('cpu_throttle_htc'),pch=get('cpu_prochot'),pce=get('cpu_prochot_ext');
 const target=Number(S.targetFps),budget=target>0?1000/target:null;

 return {
   scope:scopeRange(),
   quality:{
     samples:rows.length,
     duration_ms:rows.length>1?rows.at(-1).t-rows[0].t:0,
     median_sample_interval_ms:medianInterval(rows)
   },
   frame:{
     fps:statPack(fps),
     frame_time_ms:statPack(ft),
     below_target_pct:target>0?pctWhere(fps,v=>v<target):null,
     over_frame_budget_pct:budget!==null?pctWhere(ft,v=>v>budget):null,
     target_fps:target>0?target:null,
     frame_budget_ms:budget
   },
   pipeline:{
     cpu_busy_ms:statPack(cb),
     gpu_busy_ms:statPack(gb),
     cpu_wait_ms:statPack(get('cpu_wait_ms')),
     gpu_wait_ms:statPack(get('gpu_wait_ms')),
     gpu_latency_ms:statPack(get('gpu_latency_ms')),
     display_latency_ms:statPack(get('display_latency_ms'))
   },
   gpu:{
     utilization_pct:statPack(gpu),
     samples_ge_95_pct:pctWhere(gpu,v=>v>=95),
     temperature_c:statPack(gtemp),
     hotspot_c:statPack(ghot),
     power_w:statPack(gp),
     clock_mhz:statPack(get('gpu_clock_mhz')),
     vram_load_pct:statPack(get('vram_load_pct')),
     limits:{
       status_active_samples:{
         power_limited:get('gpu_power_limited').filter(v=>v>0).length,
         temperature_limited:get('gpu_temp_limited').filter(v=>v>0).length,
         current_limited:get('gpu_current_limited').filter(v=>v>0).length,
         voltage_limited:get('gpu_voltage_limited').filter(v=>v>0).length
       },
       thermal_limit_utilization_pct:statPack(get('gpu_thermal_limit_pct')),
       power_limit_utilization_pct:statPack(get('gpu_power_limit_pct'))
     }
   },
   cpu:{
     total_pct:statPack(get('cpu_total_pct')),
     max_thread_pct:statPack(cthread),
     temperature_c:statPack(ctemp),
     package_power_w:statPack(cp),
     effective_clock_mhz:statPack(get('cpu_effective_clock_mhz')),
     thermal_limit_pct:statPack(get('cpu_thermal_limit_pct')),
     ppt_limit_pct:statPack(ppt),
     tdc_limit_pct:statPack(tdc),
     edc_limit_pct:statPack(edc),
     throttle_active_samples:{
       htc:htc.filter(v=>v>0).length,
       prochot_cpu:pch.filter(v=>v>0).length,
       prochot_ext:pce.filter(v=>v>0).length
     }
   },
   memory:{
     ram_load_pct:statPack(get('ram_load_pct')),
     ram_used:statPack(get('ram_used')),
     ram_available:statPack(get('ram_available')),
     committed:statPack(get('memory_committed')),
     vram_used:statPack(get('vram_used')),
     vram_load_pct:statPack(get('vram_load_pct')),
     pagefile:statPack(get('pagefile')),
     memory_errors:statPack(get('memory_errors'))
   }
 };
}

function analysisMappingDiagnostics(){
 const out={};
 const sourceUse=new Map();

 for(const def of ANALYSIS_METRICS){
   const raw=analysisMetricReading(def);
   const check=metricMappingStatus(def,raw);
   const verified=check.status==='mapped'?raw:null;
   const srcKey=verified?keyOf(verified):null;

   out[def.key]={
     status:check.status,
     confidence:check.confidence,
     reason:check.reason,
     source_key:srcKey,
     source_sensor:verified?.Sensor||null,
     source_label:verified?.Label||null,
     source_unit:verified?.Unit||null
   };

   if(srcKey){
     if(!sourceUse.has(srcKey))sourceUse.set(srcKey,[]);
     sourceUse.get(srcKey).push(def.key);
   }
 }

 // Flag suspicious reuse of one reading for unrelated canonical metrics.
 for(const [srcKey,keys] of sourceUse){
   if(keys.length<2)continue;
   const allowedPairs=[
     ['gpu_util_pct','vram_load_pct']
   ];
   const allowed=allowedPairs.some(pair=>keys.every(k=>pair.includes(k)));
   if(!allowed){
     for(const k of keys){
       out[k].duplicate_source_with=keys.filter(x=>x!==k);
     }
   }
 }
 return out;
}

function captureWarnings(rows=analysisRowsForScope(),summary=analysisSummary(rows),mapping=analysisMappingDiagnostics()){
 const warnings=[];
 const q=summary.quality;

 if(q.samples<30)warnings.push({
   code:'LOW_SAMPLE_COUNT',severity:'warning',
   message:`Only ${q.samples} HWiNFO source samples are available. Use at least ~30 samples for a basic trend analysis and preferably 60–120 seconds of gameplay.`
 });
 if(q.duration_ms<30000)warnings.push({
   code:'SHORT_CAPTURE',severity:'warning',
   message:`Capture duration is ${formatDuration(q.duration_ms)}. A 60–120 second representative gameplay lap is recommended.`
 });
 if(Number.isFinite(q.median_sample_interval_ms)&&q.median_sample_interval_ms>=900)warnings.push({
   code:'COARSE_POLLING',severity:'info',
   message:`Median HWiNFO sample interval is ${Math.round(q.median_sample_interval_ms)} ms. This is suitable for trends, not true per-frame 1%/0.1% lows or stutter analysis.`
 });

 const target=Number(S.targetFps);
 warnings.push({
   code:'ANALYSIS_TARGET',severity:'info',
   message:target>0
     ?`All target-relative calculations use the user-selected target of ${target} FPS (${(1000/target).toFixed(3)} ms frame budget).`
     :'Target FPS is Off, so target-relative frame-budget classifications are disabled.'
 });

 const important=['fps','frame_time_ms','cpu_busy_ms','gpu_busy_ms','gpu_util_pct','cpu_max_thread_pct','gpu_power_w','cpu_package_power_w'];
 for(const key of important){
   if(mapping[key]?.status!=='mapped')warnings.push({
     code:'MISSING_IMPORTANT_METRIC',severity:'warning',metric:key,
     message:`${key} is not safely mapped and is exported as null.`
   });
 }

 for(const key of ['vram_used','vram_load_pct','gpu_latency_ms','display_latency_ms','gpu_temp_limited','gpu_power_limited']){
   const m=mapping[key];
   if(m?.status==='rejected')warnings.push({
     code:'REJECTED_SUSPICIOUS_MAPPING',severity:'info',metric:key,
     message:`${key}: ${m.reason}`
   });
 }

 return warnings;
}

function updateScopeAnalysis(){
 const rows=analysisRowsForScope(),s=analysisSummary(rows);
 const val=(id,v,u='')=>{$(id).textContent=Number.isFinite(v)?`${v.toFixed(Math.abs(v)>=100?1:2)}${u?` ${u}`:''}`:'—'};
 val('anFpsMedian',s.frame.fps.median,'FPS');
 val('anFpsP1',s.frame.fps.p1,'FPS');
 val('anFtP95',s.frame.frame_time_ms.p95,'ms');
 $('anBelowTarget').textContent=Number.isFinite(s.frame.below_target_pct)?`${s.frame.below_target_pct.toFixed(1)} %`:'—';
 val('anCpuBusy',s.pipeline.cpu_busy_ms.median,'ms');
 val('anGpuBusy',s.pipeline.gpu_busy_ms.median,'ms');
 val('anCpuBusyP95',s.pipeline.cpu_busy_ms.p95,'ms');
 val('anGpuBusyP95',s.pipeline.gpu_busy_ms.p95,'ms');
 val('anGpuUtil',s.gpu.utilization_pct.median,'%');
 $('anGpuSat').textContent=Number.isFinite(s.gpu.samples_ge_95_pct)?`${s.gpu.samples_ge_95_pct.toFixed(1)} %`:'—';
 val('anGpuTemp',s.gpu.temperature_c.max,'°C');
 val('anGpuPower',s.gpu.power_w.median,'W');
 val('anCpuThread',s.cpu.max_thread_pct.p95,'%');
 val('anCpuTemp',s.cpu.temperature_c.max,'°C');
 val('anCpuPower',s.cpu.package_power_w.median,'W');
 const limits=[s.cpu.ppt_limit_pct.max,s.cpu.tdc_limit_pct.max,s.cpu.edc_limit_pct.max];
 $('anCpuLimits').textContent=limits.some(Number.isFinite)
   ?limits.map(v=>Number.isFinite(v)?`${v.toFixed(0)}%`:'—').join(' / ')
   :'—';

 const q=s.quality,mapping=analysisMappingDiagnostics(),warnings=captureWarnings(rows,s,mapping);
 const target=Number(S.targetFps);
 $('analysisQuality').textContent=q.samples
   ?`${q.samples} samples · ${formatDuration(q.duration_ms)} · ${Number.isFinite(q.median_sample_interval_ms)?Math.round(q.median_sample_interval_ms)+' ms poll':'—'} · target ${target>0?target+' FPS':'off'}${warnings.filter(w=>w.severity==='warning').length?` · ${warnings.filter(w=>w.severity==='warning').length} warning(s)`:''}`
   :'Collecting telemetry…';
 $('analysisQuality').title=warnings.map(w=>`[${w.severity}] ${w.message}`).join('\n');
}

function detectHardware(){
 const groups=[...new Set((S.latest?.Readings||[]).map(r=>String(r.Sensor||'')))];
 const cpu=groups.find(x=>/CPU\s*\[#?\d*\].*(Ryzen|Core|Intel|AMD)|Ryzen|Intel.*CPU/i.test(x))||null;
 const gpu=groups.find(x=>/GPU\s*\[#?\d*\].*(Radeon|GeForce|Arc)|Radeon|GeForce|Intel Arc/i.test(x))||null;
 return {cpu,gpu};
}

function analysisMetricDefinitions(){
 const diagnostics=analysisMappingDiagnostics(),out={};
 for(const def of ANALYSIS_METRICS){
   const d=diagnostics[def.key];
   out[def.key]={
     label:def.label,
     canonical_unit:def.unit,
     group:def.group,
     mapping_status:d.status,
     mapping_confidence:d.confidence,
     mapping_reason:d.reason,
     source_key:d.source_key,
     source_sensor:d.source_sensor,
     source_label:d.source_label,
     source_unit:d.source_unit,
     duplicate_source_with:d.duplicate_source_with||[]
   };
 }
 return out;
}

function exportAnalysisJson(){
 const rows=analysisRowsForScope(),summary=analysisSummary(rows),rg=scopeRange(),hardware=detectHardware();
 const mapping=analysisMappingDiagnostics(),warnings=captureWarnings(rows,summary,mapping);
 const data={
   schema:'hwinfo-performance-lab-analysis',
   schema_version:2,
   app_version:'8.0.0',
   exported_at:new Date().toISOString(),
   scope:{
     label:rg.label,
     start:new Date(rg.start).toISOString(),
     end:new Date(rg.end).toISOString(),
     selected:S.viewScope,
     lap_id:rg.lapId??null
   },
   capture:{
     source:'HWiNFO Shared Memory',
     hwinfo_poll_ms:S.latest?.PollingPeriodMs??null,
     browser_poll_ms:Number($('clientPoll').value)||null,
     target_fps:Number(S.targetFps)>0?Number(S.targetFps):null,
     percentiles_are_polling_samples:true,
     raw_per_frame_presentmon:false
   },
   hardware,
   metric_definitions:analysisMetricDefinitions(),
   capture_warnings:warnings,
   mapping_diagnostics:mapping,
   summary,
   laps:S.laps.map((lap,i)=>({
     id:lap.id,
     start:new Date(lap.start).toISOString(),
     end:new Date(i+1<S.laps.length?S.laps[i+1].start:Date.now()).toISOString(),
     current:i===S.laps.length-1
   })),
   interpretation_notes:[
     'FPS and frame-time percentiles are based on HWiNFO polling samples, not raw per-frame PresentMon events.',
     'CPU Busy is time the CPU spent generating the sampled frame; GPU Busy is time the GPU spent working on the sampled frame.',
     'PPT/TDC/EDC/Thermal Limit percentages are limit utilization, not percentages of time throttling.',
     'GPU Thermal Limit % / GPU Power Limit % are exported as utilization/headroom metrics, never as boolean throttling status.',
     'HTC/PROCHOT and explicit GPU Temperature/Power/Current/Voltage Limited readings are separate actual status indicators when exposed.',
     'GPU Latency and Display Latency are exported only when explicitly matching latency readings exist; Frame Time is never substituted.',
     'VRAM metrics require explicit GPU/Dedicated/Video/VRAM memory semantics; System Virtual Memory is never substituted.',
     'Missing or rejected values are null. Check mapping_diagnostics and capture_warnings before drawing conclusions.'
   ],
   samples:rows.map(row=>({
     timestamp:new Date(row.t).toISOString(),
     elapsed_ms:row.t-S.sessionStart,
     lap_id:row.lapId,
     ...row.values
   }))
 };
 const scopeName=rg.label.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
 downloadBlob(JSON.stringify(data,null,2),'application/json',`hwinfo-analysis-${scopeName||'session'}-${stamp()}.json`);
 toast('AI analysis JSON exported');
}

function exportAnalysisCsv(){
 const rows=analysisRowsForScope(),rg=scopeRange();
 const defs=ANALYSIS_METRICS,keys=defs.map(d=>d.key);
 const header=['timestamp_iso','elapsed_ms','lap_id','target_fps','frame_budget_ms','hwinfo_poll_ms',...keys];
 const lines=[header.join(',')];
 for(const row of rows){
   const values=[
     new Date(row.t).toISOString(),
     row.t-S.sessionStart,
     row.lapId,
     Number(S.targetFps)>0?Number(S.targetFps):'',
     Number(S.targetFps)>0?1000/Number(S.targetFps):'',
     S.latest?.PollingPeriodMs??'',
     ...keys.map(k=>Number.isFinite(n(row.values?.[k]))?n(row.values[k]):'')
   ];
   lines.push(values.join(','));
 }
 const scopeName=rg.label.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
 downloadBlob(lines.join('\n'),'text/csv',`hwinfo-analysis-telemetry-${scopeName||'session'}-${stamp()}.csv`);
 toast('Analysis telemetry CSV exported');
}

function sourceAgeMs(){if(!S.latest?.PollTimeUnix)return null;return Math.max(0,Date.now()-Number(S.latest.PollTimeUnix)*1000)}
function addSample(k,v){
 v=n(v);if(v===null||!k)return;
 if(!S.histories.has(k))S.histories.set(k,[]);
 S.histories.get(k).push({t:Date.now(),v});
}
function addFpsAnalysisSample(type,v){
 v=n(v);if(v===null)return;
 if(!S.fpsAnalysis)S.fpsAnalysis={fps:[],ft:[],startedAt:Date.now()};
 S.fpsAnalysis[type].push({t:Date.now(),v});
}
function sampleNewSource(){
 if(!S.latest?.Ok)return;
 updateSourceState();
 const token=String(S.latest.PollTimeUnix||'');
 if(token&&token===S.lastSourceToken)return;
 S.lastSourceToken=token;S.samples++;
 const sampleNow=Date.now();
 sampleAnalysisTelemetry(sampleNow);

 // Pinned telemetry owns its own full-session history.
 for(const k of new Set(S.pins)){
   const r=reading(k);if(r)addSample(k,r.Value);
 }

 // FPS analysis is intentionally separate so it can be reset without touching pins/laps.
 const fps=selectedSource('fps'),ft=selectedSource('ft');
 if(fps)addFpsAnalysisSample('fps',fps.Value);
 if(ft)addFpsAnalysisSample('ft',ft.Value);

 $('sampleCount').textContent=S.samples;
}
function rolling(arr,sec){
 if(!arr.length)return arr;const out=[];let left=0,sum=0;
 for(let i=0;i<arr.length;i++){sum+=arr[i].v;while(arr[i].t-arr[left].t>sec*1000){sum-=arr[left].v;left++}out.push({t:arr[i].t,v:sum/(i-left+1)})}
 return out;
}

function pin(k){pinAt(k,null)}
function pinAt(k,before){
 if(!reading(k)||S.pins.includes(k))return;
 const a=[...S.pins],i=before?a.indexOf(before):-1;
 if(i<0)a.push(k);else a.splice(i,0,k);
 S.pins=a;ensureOpt(k);save();syncPinsStructure();syncGroupStars();updateDynamic();
}
function unpin(k){S.pins=S.pins.filter(x=>x!==k);save();syncPinsStructure();syncGroupStars()}
function reorder(k,before){
 const a=S.pins.filter(x=>x!==k);const i=before?a.indexOf(before):-1;if(i<0)a.push(k);else a.splice(i,0,k);S.pins=a;save();syncPinsStructure();updateDynamic()
}
function setMode(k,v){ensureOpt(k).mode=v;save();const c=document.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`);if(c){applyCardPresentation(c,k);drawOneCard(c,k)}}
function setGraph(k,v){ensureOpt(k).graph=v;save();const c=document.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`);if(c){applyCardPresentation(c,k);drawOneCard(c,k)}}
function setSmooth(k,v){ensureOpt(k).smooth=v;save();drawOneCard(document.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`),k)}
function toggleControls(k){
 const o=ensureOpt(k);o.controlsVisible=!o.controlsVisible;save();
 const c=document.querySelector(`.pin-card[data-key="${CSS.escape(k)}"]`);
 if(c)applyCardPresentation(c,k);
}
function applyAllControls(show){
 for(const k of S.pins)ensureOpt(k).controlsVisible=show;
 save();
 document.querySelectorAll('.pin-card').forEach(c=>applyCardPresentation(c,c.dataset.key));
}
window.__unpin=unpin;window.__setMode=setMode;window.__setGraph=setGraph;window.__setSmooth=setSmooth;window.__toggleControls=toggleControls;

function cardHtml(k,r){
 const o=ensureOpt(k),cat=classify(r);
 return `<article class="pin-card" data-key="${k}" draggable="true">
  <div class="pin-head"><div class="pin-left"><div class="draghandle" title="Drag to reorder">⠿</div><div class="pin-title"><div class="l">${esc(r.Label)}</div><div class="g">${esc(r.Sensor)}</div><span class="catbadge">${cat}</span></div></div>
   <div class="pin-actions">
    <button class="iconbtn" data-controls-toggle title="Show / hide card controls" onclick="__toggleControls('${k}')">⋯</button>
    <button class="iconbtn" onclick="__unpin('${k}')">Unpin</button>
   </div></div>
  <div class="pin-primary"><div><div class="big" data-pin-primary>—</div><div class="smallmode" data-pin-mode>Current</div></div></div>
  <div class="statgrid">
   <div class="sbox"><div class="k" data-pin-label="cur">Current</div><div class="v" data-pin-stat="cur">—</div></div>
   <div class="sbox"><div class="k" data-pin-label="min">Lap min</div><div class="v" data-pin-stat="min">—</div></div>
   <div class="sbox"><div class="k" data-pin-label="avg">Lap avg</div><div class="v" data-pin-stat="avg">—</div></div>
   <div class="sbox"><div class="k" data-pin-label="max">Lap max</div><div class="v" data-pin-stat="max">—</div></div>
  </div>
  <div class="chartbox"><canvas></canvas><div class="chart-legend" data-chartlegend>0 samples</div></div>
  <div class="pin-foot" data-card-controls>
   <span class="label-mini">Large value</span>
   <select data-mode onchange="__setMode('${k}',this.value)"><option value="current">Current</option><option value="min">Session min</option><option value="avg">Session avg</option><option value="max">Session max</option></select>
   <label class="check"><input type="checkbox" data-graph onchange="__setGraph('${k}',this.checked)"> graph</label>
   <label class="check"><input type="checkbox" data-smooth onchange="__setSmooth('${k}',this.checked)"> 5s avg</label>
  </div>
 </article>`;
}
function applyCardPresentation(card,k){
 const o=ensureOpt(k);
 card.querySelector('[data-mode]').value=o.mode||'current';
 card.querySelector('[data-graph]').checked=o.graph!==false;
 card.querySelector('[data-smooth]').checked=!!o.smooth;
 card.querySelector('.chartbox').classList.toggle('hidden',o.graph===false);
 const controls=card.querySelector('[data-card-controls]');
 if(controls)controls.classList.toggle('hidden',o.controlsVisible===false);
 const toggle=card.querySelector('[data-controls-toggle]');
 if(toggle){
   toggle.title=o.controlsVisible===false?'Show card controls':'Hide card controls';
   toggle.setAttribute('aria-pressed',o.controlsVisible===false?'true':'false');
 }
 card.querySelector('[data-pin-mode]').textContent=o.mode==='min'?'Session minimum':o.mode==='avg'?'Session average':o.mode==='max'?'Session maximum':'Current';
}
function bindCardDnD(card){
 card.ondragstart=e=>{
   S.draggingKey=card.dataset.key;
   S.dragType='pin';
   S.dragOriginalPins=[...S.pins];
   S.dragDropped=false;
   card.classList.add('dragging');
   e.dataTransfer.effectAllowed='move';
   e.dataTransfer.setData('text/plain',S.draggingKey);
 };
 card.ondragend=()=>{
   if(!S.dragDropped&&S.dragOriginalPins){
     S.pins=[...S.dragOriginalPins];
     save();
     syncPinsStructure();
   }
   cleanupPinDrag();
 };
}
function syncPinsStructure(){
 const host=$('pinHost'),valid=S.pins.filter(k=>reading(k));
 host.className='pingrid';
 if(!valid.length){
   if(!host.querySelector(':scope > .pin-empty'))host.innerHTML='<div class="empty pin-empty">No pinned telemetry.</div>';
   return;
 }
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
 const seconds=Number($('window').value)||300,rg=scopeRange();
 let pts=(S.histories.get(k)||[]).filter(p=>p.t>=rg.start&&p.t<=rg.end&&Number.isFinite(p.v));
 // Current lap / all-session views obey the chosen rolling graph window.
 // A completed historical lap shows the whole lap, which is more useful for comparison.
 if(!rg.historical){
   const cut=Math.max(rg.start,rg.end-seconds*1000);
   pts=pts.filter(p=>p.t>=cut);
 }
 if(o.smooth)pts=rolling(pts,5);if(pts.length<2){S.hoverCharts.set(k,{pts,plot:null});return}
 const vals=pts.map(p=>p.v);let lo=Math.min(...vals),hi=Math.max(...vals);if(lo===hi){lo-=1;hi+=1}const pad=(hi-lo)*.10;lo-=pad;hi+=pad;
 const L=4*dpr,R=w-4*dpr,T=4*dpr,B=h-14*dpr,colors=graphColors();
 c.strokeStyle=colors.grid;c.lineWidth=1*dpr;for(let i=0;i<3;i++){const y=T+(B-T)*i/2;c.beginPath();c.moveTo(L,y);c.lineTo(R,y);c.stroke()}
 const t0=pts[0].t,t1=pts.at(-1).t||t0+1;c.strokeStyle=colors.line;c.lineWidth=1.6*dpr;c.beginPath();
 pts.forEach((p,i)=>{const x=L+(R-L)*(p.t-t0)/Math.max(1,t1-t0),y=B-(B-T)*(p.v-lo)/(hi-lo);i?c.lineTo(x,y):c.moveTo(x,y)});c.stroke();
 c.font=`${Math.max(11,Number(S.minFontPx)||11)*dpr}px Segoe UI`;c.fillStyle=colors.muted;c.fillText(fmt(hi,r.Unit,true),6*dpr,10*dpr);c.fillText(fmt(lo,r.Unit,true),6*dpr,h-2*dpr);
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
 const r=reading(k);if(!card||!r)return;
 const scoped=scopedHistory(k),st=calc(scoped),o=ensureOpt(k),rg=scopeRange();
 const current=scopedCurrentValue(k,r);
 const primary=o.mode==='min'?st.min:o.mode==='avg'?st.avg:o.mode==='max'?st.max:current;

 const primaryEl=card.querySelector('[data-pin-primary]');
 primaryEl.textContent=displayReading(r,primary);applyHealth(primaryEl,r,primary);

 const curLabel=card.querySelector('[data-pin-label="cur"]');
 if(curLabel)curLabel.textContent=rg.historical?'Lap end':'Current';
 for(const kind of ['min','avg','max']){
   const label=card.querySelector(`[data-pin-label="${kind}"]`);
   if(label)label.textContent=scopeStatLabel(kind);
 }
 for(const [f,v] of [['cur',current],['min',st.min],['avg',st.avg],['max',st.max]]){
   const el=card.querySelector(`[data-pin-stat="${f}"]`);
   el.textContent=displayReading(r,v);applyHealth(el,r,v);
 }
 card.querySelector('[data-chartlegend]').textContent=`${rg.label} • ${st.count} samples${o.smooth?' • 5s rolling average':''}`;
 if(o.graph!==false)drawCanvas(card.querySelector('canvas'),k,null);
}
function updatePins(){
 // IMPORTANT: never rebuild, append or move card DOM nodes during a telemetry poll.
 // Native <select> popups are closed by browsers when their element is moved/reinserted.
 // Card structure is synchronized only when pins/topology/order actually changes.
 document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key))
}

function updateFps(){
 const fv=fpsAnalysisArray('fps').map(x=>x.v).filter(Number.isFinite),
       tv=fpsAnalysisArray('ft').map(x=>x.v).filter(Number.isFinite);
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


function cfxNum(v){
 const x=Number(v);return Number.isFinite(x)?x:null;
}
function cfxSet(id,value,unit){
 const el=$(id);if(!el)return;
 const x=cfxNum(value);el.textContent=x===null?'—':fmt(x,unit||'');
}
function cfxClear(){
 ['cfxAverage','cfxLow1','cfxLow02','cfxP1','cfxP02','cfxRange','cfxFrames','cfxDuration',
  'cfxGame','cfxProcess','cfxMetricSource','cfxStutters','cfxFreezes','cfxRecordedAt'].forEach(id=>{if($(id))$(id).textContent='—'});
 $('cfxChartMeta').textContent='Waiting for CapFrameX…';
 $('cfxChartEmpty').classList.remove('hidden');
 const canvas=$('cfxChart');if(canvas){const ctx=canvas.getContext('2d');ctx.clearRect(0,0,canvas.width,canvas.height)}
 S.cfxPlot=null;
}
function nearestAnalysisRow(ts){
 if(!Number.isFinite(ts)||!S.analysisRows?.length)return null;
 let best=null,dist=Infinity;
 for(const row of S.analysisRows){const d=Math.abs(row.t-ts);if(d<dist){dist=d;best=row}}
 return best&&dist<=2500?best:null;
}
function updateCfxCorrelation(point){
 if(!point||!S.capFrameX?.Latest){
  $('cfxCorrFrame').textContent='—';$('cfxCorrGpu').textContent='—';$('cfxCorrCpu').textContent='—';$('cfxCorrPpt').textContent='—';return;
 }
 const latest=S.capFrameX.Latest;
 // CapFrameX CreationDate is saved when the session file is created after the capture.
 const end=Date.parse(latest.RecordedAt||'');
 const duration=cfxNum(latest.DurationSec);
 const absolute=Number.isFinite(end)&&duration!==null?end-duration*1000+Number(point.TSec||0)*1000:null;
 const row=absolute===null?null:nearestAnalysisRow(absolute);
 const fps=Number(point.FrametimeMs)>0?1000/Number(point.FrametimeMs):null;
 $('cfxCorrFrame').textContent=Number(point.FrametimeMs).toFixed(2)+' ms'+(fps?' / '+fps.toFixed(1)+' FPS':'');
 if(!row){
  $('cfxCorrGpu').textContent='no HWiNFO match';$('cfxCorrCpu').textContent='—';$('cfxCorrPpt').textContent='—';return;
 }
 const v=row.values||{};
 const show=(x,u)=>Number.isFinite(Number(x))?fmt(Number(x),u):'—';
 $('cfxCorrGpu').textContent=show(v.gpu_util_pct,'%');
 $('cfxCorrCpu').textContent=show(v.cpu_max_thread_pct,'%');
 $('cfxCorrPpt').textContent=show(v.cpu_ppt_limit_pct,'%');
}
function drawCapFrameX(){
 const canvas=$('cfxChart'),pts=S.capFrameX?.Latest?.Frametimes||[];
 if(!canvas||!pts.length){if($('cfxChartEmpty'))$('cfxChartEmpty').classList.remove('hidden');return}
 $('cfxChartEmpty').classList.add('hidden');
 const rect=canvas.getBoundingClientRect(),dpr=Math.max(1,devicePixelRatio||1);
 const w=Math.max(1,Math.floor(rect.width*dpr)),h=Math.max(1,Math.floor(rect.height*dpr));
 if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h}
 const ctx=canvas.getContext('2d');ctx.clearRect(0,0,w,h);
 const clean=pts.filter(p=>Number.isFinite(Number(p.TSec))&&Number.isFinite(Number(p.FrametimeMs))&&Number(p.FrametimeMs)>=0);
 if(clean.length<2)return;
 const vals=clean.map(p=>Number(p.FrametimeMs)).filter(v=>v>0).sort((a,b)=>a-b);
 const p995=vals.length?qtile(vals,.995):16.7;
 const budget=Number(S.targetFps)>0?1000/Number(S.targetFps):null;
 const ymax=Math.max(16.7,(p995||16.7)*1.25,budget?budget*1.35:0);
 const t0=Number(clean[0].TSec),t1=Number(clean.at(-1).TSec)||t0+1;
 const L=6*dpr,R=w-6*dpr,T=7*dpr,B=h-20*dpr,colors=graphColors();
 ctx.strokeStyle=colors.grid;ctx.lineWidth=1*dpr;
 for(let i=0;i<4;i++){const y=T+(B-T)*i/3;ctx.beginPath();ctx.moveTo(L,y);ctx.lineTo(R,y);ctx.stroke()}
 if(budget&&budget<ymax){
  const y=B-(B-T)*budget/ymax;ctx.save();ctx.setLineDash([5*dpr,4*dpr]);ctx.strokeStyle=colors.hover;ctx.beginPath();ctx.moveTo(L,y);ctx.lineTo(R,y);ctx.stroke();ctx.restore();
 }
 ctx.strokeStyle=colors.line;ctx.lineWidth=1.35*dpr;ctx.beginPath();
 clean.forEach((p,i)=>{
  const x=L+(R-L)*(Number(p.TSec)-t0)/Math.max(.001,t1-t0);
  const y=B-(B-T)*Math.min(ymax,Number(p.FrametimeMs))/ymax;
  i?ctx.lineTo(x,y):ctx.moveTo(x,y);
 });ctx.stroke();
 ctx.font=(Math.max(11,Number(S.minFontPx)||11)*dpr)+'px Segoe UI';ctx.fillStyle=colors.muted;
 ctx.fillText(ymax.toFixed(1)+' ms',7*dpr,12*dpr);ctx.fillText('0 ms',7*dpr,h-3*dpr);
 const ratio=S.cfxHoverRatio;
 if(ratio!==null&&ratio!==undefined){
  const target=t0+(t1-t0)*ratio;let best=clean[0],bd=Infinity;
  for(const p of clean){const d=Math.abs(Number(p.TSec)-target);if(d<bd){bd=d;best=p}}
  const x=L+(R-L)*(Number(best.TSec)-t0)/Math.max(.001,t1-t0);
  const y=B-(B-T)*Math.min(ymax,Number(best.FrametimeMs))/ymax;
  ctx.strokeStyle=colors.hover;ctx.beginPath();ctx.moveTo(x,T);ctx.lineTo(x,B);ctx.stroke();
  ctx.fillStyle=colors.text;ctx.beginPath();ctx.arc(x,y,3*dpr,0,Math.PI*2);ctx.fill();
  updateCfxCorrelation(best);
 }
 S.cfxPlot={pts:clean,t0,t1};
}
function bindCfxChart(){
 const canvas=$('cfxChart');if(!canvas||canvas.dataset.bound==='1')return;
 canvas.dataset.bound='1';
 canvas.onpointermove=e=>{
  const rect=canvas.getBoundingClientRect();
  S.cfxHoverRatio=Math.max(0,Math.min(1,(e.clientX-rect.left)/Math.max(1,rect.width)));
  drawCapFrameX();
  const meta=S.cfxPlot;if(!meta?.pts?.length)return;
  const target=meta.t0+(meta.t1-meta.t0)*S.cfxHoverRatio;let best=meta.pts[0],bd=Infinity;
  for(const p of meta.pts){const d=Math.abs(Number(p.TSec)-target);if(d<bd){bd=d;best=p}}
  const ms=Number(best.FrametimeMs),fps=ms>0?1000/ms:null,tip=$('tooltip');
  tip.querySelector('.time').textContent=Number(best.TSec).toFixed(2)+' s';
  tip.querySelector('.val').textContent=ms.toFixed(2)+' ms'+(fps?' • '+fps.toFixed(1)+' FPS':'');
  tip.style.display='block';
  let tx=e.clientX+12,ty=e.clientY+12;if(tx+190>innerWidth)tx=e.clientX-195;if(ty+75>innerHeight)ty=e.clientY-80;
  tip.style.left=tx+'px';tip.style.top=ty+'px';
 };
 canvas.onpointerleave=()=>{S.cfxHoverRatio=null;$('tooltip').style.display='none';updateCfxCorrelation(null);drawCapFrameX()};
}
function updateCapFrameX(){
 const d=S.capFrameX,status=$('cfxStatus');
 if(!d?.Available){
  status.className='badge offline';status.textContent='OFFLINE';
  $('cfxState').textContent=d?.Message||'CapFrameX not detected';
  $('cfxMessage').className='cfx-note';
  $('cfxMessage').textContent=d?.Message||'Start CapFrameX and leave it running.';
  cfxClear();return;
 }
 const s=d.Status||{},state=String(s.State||'Idle');
 if(s.IsCapturing){status.className='badge live';status.textContent='CAPTURING'}
 else if(/processing/i.test(state)){status.className='badge stale';status.textContent='PROCESSING'}
 else{status.className='badge live';status.textContent='CONNECTED'}
 $('cfxState').textContent=state;
 const latest=d.Latest;
 if(!latest){cfxClear();$('cfxMessage').textContent='Connected to CapFrameX. No completed capture was found yet.';return}
 cfxSet('cfxAverage',latest.Metrics?.Average,'FPS');
 cfxSet('cfxLow1',latest.Metrics?.OnePercentLowAverage,'FPS');
 cfxSet('cfxLow02',latest.Metrics?.ZerodotTwoPercentLowAverage,'FPS');
 cfxSet('cfxP1',latest.Metrics?.P1,'FPS');
 cfxSet('cfxP02',latest.Metrics?.P0dot2,'FPS');
 const mn=cfxNum(latest.Metrics?.Min),mx=cfxNum(latest.Metrics?.Max);
 $('cfxRange').textContent=mn!==null&&mx!==null?fmt(mn,'')+' / '+fmt(mx,' FPS'):'—';
 $('cfxFrames').textContent=Number.isFinite(Number(latest.FrameCount))?Number(latest.FrameCount).toLocaleString():'—';
 $('cfxDuration').textContent=Number.isFinite(Number(latest.DurationSec))?Number(latest.DurationSec).toFixed(1)+' s':'—';
 $('cfxGame').textContent=latest.Game||'—';$('cfxProcess').textContent=latest.ProcessName||'—';
 $('cfxMetricSource').textContent=latest.MetricSource||'—';
 $('cfxStutters').textContent=Number.isFinite(Number(latest.StutterCount))?String(latest.StutterCount):'—';
 $('cfxFreezes').textContent=Number.isFinite(Number(latest.FreezeCount))?String(latest.FreezeCount):'—';
 $('cfxRecordedAt').textContent=latest.RecordedAt?new Date(latest.RecordedAt).toLocaleString():'—';
 $('cfxChartMeta').textContent=(latest.MetricSource||'frametime')+' • '+(latest.SampleHz?latest.SampleHz+' Hz display':'raw')+' • '+(latest.FrameCount||0)+' frames';
 const warn=latest.MetricSourceWarning;
 $('cfxMessage').className='cfx-note'+(warn?' warn':'');
 $('cfxMessage').textContent=warn||'Latest completed capture is loaded automatically. Hover the graph for approximate HWiNFO time correlation.';
 bindCfxChart();drawCapFrameX();
}
async function fetchCapFrameX(){
 if(S.capFrameXInFlight)return;S.capFrameXInFlight=true;
 try{
  const ctl=new AbortController(),to=setTimeout(()=>ctl.abort(),5000);
  const res=await fetch('/api/capframex?_='+Date.now(),{cache:'no-store',signal:ctl.signal});clearTimeout(to);
  if(!res.ok)throw new Error('HTTP '+res.status);
  S.capFrameX=await res.json();updateCapFrameX();
 }catch(e){S.capFrameX={Available:false,Message:'CapFrameX bridge unavailable: '+e.message};updateCapFrameX()}
 finally{S.capFrameXInFlight=false}
}
function scheduleCapFrameX(){
 clearTimeout(S.capFrameXTimer);
 S.capFrameXTimer=setTimeout(async()=>{await fetchCapFrameX();scheduleCapFrameX()},2000);
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
  <td data-cell="${k}:cur">${esc(displayReading(r,r.Value))}</td><td data-cell="${k}:min">${esc(displayReading(r,r.Min))}</td><td data-cell="${k}:max">${esc(displayReading(r,r.Max))}</td><td data-cell="${k}:avg">${esc(displayReading(r,r.Avg))}</td>
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
 document.querySelectorAll('.sensor-row').forEach(row=>{
   row.ondragstart=e=>{
     S.draggingKey=row.dataset.key;
     S.dragType='sensor';
     S.dragDropped=false;
     row.classList.add('dragging');
     e.dataTransfer.setData('text/plain',S.draggingKey);
     e.dataTransfer.effectAllowed='copy';
   };
   row.ondragend=()=>{
     row.classList.remove('dragging');
     cleanupPinDrag();
   };
 });
}
function updateSensorCells(){
 if(!S.latest?.Ok)return;
 for(const r of S.latest.Readings){
   const k=keyOf(r);
   for(const [f,v] of [['cur',r.Value],['min',r.Min],['max',r.Max],['avg',r.Avg]]){
     const el=document.querySelector(`[data-cell="${CSS.escape(k+':'+f)}"]`);
     if(el){el.textContent=displayReading(r,v);applyHealth(el,r,v)}
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
 if(!S.latest?.Ok)return;
 updateSourceState();updateOverview();updatePins();updateFps();updateScopeAnalysis();updateSensorCells();updateStatus();
 $('sampleCount').textContent=S.samples
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
  r=>/gpu core load|gpu utilization/.test(readingText(r)),
  r=>/gpu temperature/.test(readingText(r))&&!/hot ?spot|junction/.test(readingText(r)),
  r=>/gpu.*hot ?spot|gpu.*junction/.test(readingText(r)),
  r=>(/gpu asic power|gpu total board power|total board power|gpu board power|gpu chip power|gpu power|graphics power|gpu ppt/.test(readingText(r)))&&/^w$|watt/.test(String(r.Unit||'').toLowerCase()),
  r=>/gpu core clock|gpu clock|graphics clock/.test(readingText(r))&&!/memory/.test(readingText(r)),
  r=>/gpu memory clock|vram.*clock/.test(readingText(r)),
  r=>/gpu fan/.test(readingText(r)),
  r=>/gpu memory allocated|dedicated memory usage|gpu memory used|vram used/.test(readingText(r)),
  r=>/gpu.*thermal thrott|gpu.*performance limit thermal|gpu.*power limit|gpu.*performance limit power/.test(readingText(r))
 ],
 cpu:[
  r=>/total cpu usage/.test(readingText(r)),
  r=>/max cpu thread usage|maximum cpu thread usage|max cpu core usage|maximum cpu core usage/.test(readingText(r)),
  r=>/cpu tctl tdie|cpu package temperature/.test(readingText(r)),
  r=>/cpu package power|package power/.test(readingText(r)),
  r=>/core effective clocks.*avg|average effective clock/.test(readingText(r)),
  r=>/^cpu ppt limit$/.test(norm(r.Label||r.LabelOriginal||'')),
  r=>/thermal throttling htc/.test(readingText(r))
 ],
 memory:[
  r=>/physical memory load/.test(readingText(r)),
  r=>/physical memory used/.test(readingText(r)),
  r=>/available physical memory|physical memory available/.test(readingText(r)),
  r=>/committed memory|commit charge/.test(readingText(r)),
  r=>/page file usage|pagefile usage/.test(readingText(r)),
  r=>/gpu memory allocated|dedicated memory usage|gpu memory used|vram used/.test(readingText(r)),
  r=>/gpu memory load|vram.*load/.test(readingText(r)),
  r=>/memory errors|ecc.*error|whea.*memory/.test(readingText(r))
 ]
};
function applyPreset(which){
 if(!S.latest?.Ok)return;const cats=which==='all'?['gaming','gpu','cpu','memory']:[which];
 for(const cat of cats){for(const test of PRESETS[cat]||[]){const r=S.latest.Readings.find(test);if(r&&!S.pins.includes(keyOf(r)))S.pins.push(keyOf(r))}}
 save();syncPinsStructure();syncGroupStars();updateDynamic();
 const host=$('pinHost');host?.classList.add('flash');setTimeout(()=>host?.classList.remove('flash'),450)
}

function collapseAll(collapse){document.querySelectorAll('.group').forEach(g=>{const name=g.dataset.group,body=g.querySelector('.group-body'),chev=g.querySelector('.chev');body.classList.toggle('hidden',collapse);chev.textContent=collapse?'▸':'▾';collapse?S.collapsed.add(name):S.collapsed.delete(name)})}
function applyAllGraphs(on){for(const k of S.pins)ensureOpt(k).graph=on;save();document.querySelectorAll('.pin-card').forEach(c=>{applyCardPresentation(c,c.dataset.key);drawOneCard(c,c.dataset.key)})}
function applyAllMode(){const mode=$('globalMode').value;for(const k of S.pins)ensureOpt(k).mode=mode;save();document.querySelectorAll('.pin-card').forEach(c=>{applyCardPresentation(c,c.dataset.key);drawOneCard(c,c.dataset.key)})}
function resetSession(){
 if(!confirm('Reset the entire local session? This clears pinned telemetry history, all laps and FPS analysis. HWiNFO built-in Min/Max/Avg remain untouched.'))return;
 const now=Date.now();
 S.histories=new Map();S.samples=0;S.sessionStart=now;S.lastSourceToken=null;
 S.analysisRows=[];
 S.fpsAnalysis={fps:[],ft:[],startedAt:now};
 resetLapState();
 $('sampleCount').textContent='0';updateDynamic();toast('Entire session reset');
}
function clearPins(){if(!S.pins.length)return;if(!confirm('Remove all pinned cards?'))return;S.pins=[];save();syncPinsStructure();syncGroupStars()}
function exportCsv(){exportAnalysisCsv()}
function stamp(){return new Date().toISOString().replace(/[:.]/g,'-')}
function downloadBlob(content,type,name){const blob=new Blob([content],{type}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000)}

function exportSetup(){
 const pinItems=S.pins.map(k=>{const r=reading(k);if(!r)return null;return {reading:descriptor(r),options:ensureOpt(k)}}).filter(Boolean);
 const cfg={
  schema:'hwinfo-performance-lab-setup',version:5,exportedAt:new Date().toISOString(),
  ui:{theme:S.themePref,minFontPx:S.minFontPx,graphWindow:$('window').value,clientPoll:$('clientPoll').value,category:S.category,healthColors:S.healthColors,targetFps:S.targetFps,overview:S.overviewConfig,pinnedVisible:S.pinnedVisible,fpsPosition:S.fpsPosition},
  pins:pinItems,
  sources:{fps:S.fpsPref?descriptor(reading(S.fpsPref)):null,frameTime:S.ftPref?descriptor(reading(S.ftPref)):null}
 };
 downloadBlob(JSON.stringify(cfg,null,2),'application/json',`hwinfo-performance-lab-setup-${stamp()}.json`);toast('Dashboard setup exported')
}
function applyImportedSetup(cfg){
 if(!cfg||cfg.schema!=='hwinfo-performance-lab-setup'){toast('This is not a Performance Lab setup file');return}
 if(!S.latest?.Ok){S.pendingImport=cfg;toast('Setup loaded; waiting for HWiNFO data');return}
 const pins=[],opts={};let unresolved=0;
 for(const item of cfg.pins||[]){const r=resolveDescriptor(item.reading);if(!r){unresolved++;continue}const k=keyOf(r);pins.push(k);opts[k]={mode:item.options?.mode==='all'?'current':(item.options?.mode||'current'),graph:item.options?.graph!==false,smooth:!!item.options?.smooth,controlsVisible:item.options?.controlsVisible!==false}}
 S.pins=pins;S.opts=opts;
 if(cfg.ui?.graphWindow)$('window').value=String(cfg.ui.graphWindow);
 if(cfg.ui?.clientPoll)$('clientPoll').value=String(cfg.ui.clientPoll);
 if(cfg.ui?.category){S.category=cfg.ui.category;setFilterButtons()}
 if(cfg.ui?.theme)applyTheme(cfg.ui.theme);
 if(cfg.ui?.minFontPx!==undefined)applyTypographyScale(cfg.ui.minFontPx);
 if(typeof cfg.ui?.healthColors==='boolean'){S.healthColors=cfg.ui.healthColors;$('healthColors').checked=S.healthColors}
 if(cfg.ui&&cfg.ui.targetFps!==undefined){const tf=Number(cfg.ui.targetFps);S.targetFps=Number.isFinite(tf)?tf:60;$('targetFps').value=String(S.targetFps)}
 if(cfg.ui?.overview&&typeof cfg.ui.overview==='object')S.overviewConfig=cfg.ui.overview;
 if(typeof cfg.ui?.pinnedVisible==='boolean')S.pinnedVisible=cfg.ui.pinnedVisible;
 if(cfg.ui?.fpsPosition==='above'||cfg.ui?.fpsPosition==='below')S.fpsPosition=cfg.ui.fpsPosition;
 ensureOverviewConfig();renderOverviewStructure();applyPinnedVisibility();applySectionOrder();
 const fr=resolveDescriptor(cfg.sources?.fps),tr=resolveDescriptor(cfg.sources?.frameTime);S.fpsPref=fr?keyOf(fr):'';S.ftPref=tr?keyOf(tr):'';
 save();rebuildSourceSelectors();S.topology='';renderGroupsStructure(true);syncPinsStructure();updateDynamic();schedulePoll();
 toast(`Setup imported${unresolved?` • ${unresolved} sensor(s) not found on this PC`:''}`)
}
async function importSetupFile(file){try{const cfg=JSON.parse(await file.text());applyImportedSetup(cfg)}catch(e){toast('Could not import setup: '+e.message)}finally{$('importFile').value=''}}

function getPinPlaceholder(){
 if(S.pinPlaceholder&&S.pinPlaceholder.isConnected)return S.pinPlaceholder;
 const ph=document.createElement('div');
 ph.className='pin-placeholder';
 ph.innerHTML='<span>Pin here</span>';
 S.pinPlaceholder=ph;
 return ph;
}

function animatePinReflow(host,mutate,exclude=null){
 const cards=[...host.querySelectorAll(':scope > .pin-card')].filter(x=>x!==exclude);
 const before=new Map(cards.map(x=>[x,x.getBoundingClientRect()]));
 mutate();
 const after=[...host.querySelectorAll(':scope > .pin-card')].filter(x=>x!==exclude);
 for(const el of after){
   const a=before.get(el);if(!a)continue;
   const b=el.getBoundingClientRect(),dx=a.left-b.left,dy=a.top-b.top;
   if(Math.abs(dx)<1&&Math.abs(dy)<1)continue;
   try{
     el.getAnimations().forEach(anim=>anim.cancel());
     el.animate(
       [{transform:`translate(${dx}px,${dy}px)`},{transform:'translate(0,0)'}],
       {duration:145,easing:'cubic-bezier(.2,.75,.25,1)'}
     );
   }catch{}
 }
}

function previewInsertion(host,node,target,e){
 if(!node||!host)return;
 let ref=null;
 if(target&&target!==node){
   const rect=target.getBoundingClientRect();
   const multiColumn=rect.width<host.getBoundingClientRect().width*.72;
   const after=multiColumn
     ? e.clientX>rect.left+rect.width/2
     : e.clientY>rect.top+rect.height/2;
   ref=after?target.nextElementSibling:target;
   if(ref===node)ref=node.nextElementSibling;
 }

 if(ref===node||node.nextElementSibling===ref)return;
 animatePinReflow(host,()=>{
   if(ref)host.insertBefore(node,ref);
   else host.appendChild(node);
 },S.dragType==='pin'?node:null);
}

function pinnedOrderFromDom(){
 return [...$('pinHost').querySelectorAll(':scope > .pin-card')]
   .map(c=>c.dataset.key).filter(Boolean);
}

function cleanupPinDrag(){
 const host=$('pinHost');
 host?.classList.remove('pin-drag-active');
 document.querySelectorAll('.pin-card').forEach(x=>x.classList.remove('dragging','drag-target'));
 if(S.pinPlaceholder?.isConnected)S.pinPlaceholder.remove();
 S.pinPlaceholder=null;
 const empty=host?.querySelector(':scope > .pin-empty');
 if(empty)empty.classList.remove('hidden');
 S.draggingKey=null;
 S.dragType=null;
 S.dragOriginalPins=null;
 S.dragDropped=false;
}

function bindGlobalDnD(){
 const host=$('pinHost');
 if(!host)return;

 host.ondragenter=e=>{
   if(!S.draggingKey)return;
   e.preventDefault();
   host.classList.add('pin-drag-active');
 };

 host.ondragover=e=>{
   if(!S.draggingKey)return;
   e.preventDefault();
   e.dataTransfer.dropEffect=S.dragType==='pin'?'move':'copy';
   host.classList.add('pin-drag-active');

   const target=e.target.closest?.('.pin-card');

   if(S.dragType==='pin'){
     const dragged=host.querySelector(`:scope > .pin-card[data-key="${CSS.escape(S.draggingKey)}"]`);
     if(dragged)previewInsertion(host,dragged,target,e);
     return;
   }

   const empty=host.querySelector(':scope > .pin-empty');
   if(empty)empty.classList.add('hidden');

   const ph=getPinPlaceholder();
   if(!ph.isConnected){
     const sample=host.querySelector(':scope > .pin-card');
     if(sample){
       const r=sample.getBoundingClientRect();
       ph.style.minHeight=`${Math.max(120,Math.round(r.height))}px`;
     }
     host.appendChild(ph);
   }
   previewInsertion(host,ph,target,e);
 };

 host.ondrop=e=>{
   if(!S.draggingKey)return;
   e.preventDefault();
   e.stopPropagation();

   const k=e.dataTransfer.getData('text/plain')||S.draggingKey;
   if(!k)return;

   if(S.dragType==='pin'&&S.pins.includes(k)){
     const domOrder=pinnedOrderFromDom();
     const hidden=S.pins.filter(x=>!domOrder.includes(x));
     S.pins=[...domOrder,...hidden];
     S.dragDropped=true;
     save();
     cleanupPinDrag();
     syncPinsStructure();
     updateDynamic();
     return;
   }

   if(S.dragType==='sensor'&&!S.pins.includes(k)){
     const ph=S.pinPlaceholder;
     let before=null;
     if(ph){
       let next=ph.nextElementSibling;
       while(next&&!next.classList.contains('pin-card'))next=next.nextElementSibling;
       before=next?.dataset?.key||null;
     }
     S.dragDropped=true;
     if(ph?.isConnected)ph.remove();
     S.pinPlaceholder=null;
     pinAt(k,before);
     cleanupPinDrag();
   }
 };
}

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
document.addEventListener('click',e=>{
 closeMenus();
 const details=$('analysisSettings');
 if(details?.open&&!details.contains(e.target))details.open=false;
});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){closeMenus();if(!$('overviewEditorBackdrop').classList.contains('hidden'))closeOverviewEditor()}});

$('search').addEventListener('input',()=>{S.topology='';renderGroupsStructure(true)});
$('window').addEventListener('change',()=>document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key)));
$('clientPoll').addEventListener('change',schedulePoll);
$('theme').addEventListener('change',e=>applyTheme(e.target.value));
$('minFontSize').value=String(S.minFontPx);
$('minFontSize').addEventListener('change',e=>applyTypographyScale(e.target.value));
$('healthColors').checked=S.healthColors;
$('targetFps').value=String(S.targetFps);
$('healthColors').addEventListener('change',e=>{S.healthColors=e.target.checked;save();updateDynamic()});
$('targetFps').addEventListener('change',e=>{const tf=Number(e.target.value);S.targetFps=Number.isFinite(tf)?tf:60;save();updateDynamic()});
$('fpsSource').addEventListener('change',e=>{S.fpsPref=e.target.value;save();updateSourceState();resetFpsAnalysis(false);updateDynamic();toast('FPS source changed • analysis restarted')});
$('ftSource').addEventListener('change',e=>{S.ftPref=e.target.value;save();updateSourceState();resetFpsAnalysis(false);updateDynamic();toast('Frame-time source changed • analysis restarted')});
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
$('reset').onclick=resetSession;$('exportCsv').onclick=exportCsv;$('exportAnalysis').onclick=exportAnalysisJson;
$('newLapQuick').onclick=newLap;$('newLapMenu').onclick=newLap;
$('resetLaps').onclick=resetLapsOnly;
$('lapView').addEventListener('change',e=>setViewScope(e.target.value));
$('resetFpsAnalysis').onclick=()=>resetFpsAnalysis(true);
$('togglePinnedSection').onclick=togglePinnedVisibility;
$('moveFpsSection').onclick=toggleFpsPosition;
$('expandAll').onclick=()=>collapseAll(false);$('collapseAll').onclick=()=>collapseAll(true);
$('graphsOn').onclick=()=>applyAllGraphs(true);$('graphsOff').onclick=()=>applyAllGraphs(false);
$('controlsOn').onclick=()=>applyAllControls(true);$('controlsOff').onclick=()=>applyAllControls(false);
$('applyMode').onclick=applyAllMode;$('clearPins').onclick=clearPins;
$('exportSetup').onclick=exportSetup;$('importSetup').onclick=()=>$('importFile').click();$('importFile').onchange=e=>{if(e.target.files?.[0])importSetupFile(e.target.files[0])};
document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{S.category=b.dataset.filter;setFilterButtons();S.topology='';renderGroupsStructure(true)});
bindGlobalDnD();applyTheme(S.themePref);applyTypographyScale(S.minFontPx);setFilterButtons();ensureOverviewConfig();renderOverviewStructure();syncLapSelector();applyPinnedVisibility();applySectionOrder();

setInterval(()=>{
 const now=Date.now();
 $('elapsed').textContent=formatDuration(now-S.sessionStart);
 $('lapElapsed').textContent=formatDuration(now-currentLap().start);
 $('fpsAnalysisElapsed').textContent=formatDuration(now-(S.fpsAnalysis?.startedAt||now));
 updateStatus();
},500);
window.addEventListener('resize',()=>{document.querySelectorAll('.pin-card').forEach(c=>drawOneCard(c,c.dataset.key));drawCapFrameX()});
bindCfxChart();fetchOnce();schedulePoll();fetchCapFrameX();scheduleCapFrameX();
</script>
</body>
</html>
'@

# DASH-TEST-BEGIN
$dashHtml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9InV0Zi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+UGVyZm9ybWFuY2UgTGFiIOKAlCBMaXZlIERpYWdub3N0aWNzPC90aXRsZT4KPHN0eWxlPgo6cm9vdHsKICAtLWJnOiMwODBhMGM7CiAgLS1zdXJmYWNlOiMwZDExMTQ7CiAgLS1zdXJmYWNlMjojMTIxODFkOwogIC0tc3VyZmFjZTM6IzE3MWUyNDsKICAtLWxpbmU6IzI2MzAzOTsKICAtLWxpbmUyOiMzNTQxNGE7CiAgLS10ZXh0OiNlZGYxZjM7CiAgLS1tdXRlZDojOWFhNmFkOwogIC0tZGltOiM2ZjdiODI7CiAgLS1hY2NlbnQ6IzlhYTI3ZDsKICAtLWdvb2Q6IzcyZDdhNDsKICAtLXdhcm46I2QwYWE2YTsKICAtLWJhZDojZDU3YTdhOwogIC0tY2hhcnQ6IzgyYWVlODsKICAtLWZvbnQ6IlNlZ29lIFVJIixBcmlhbCxzYW5zLXNlcmlmOwogIC0tbW9ubzoiQ2FzY2FkaWEgQ29kZSIsQ29uc29sYXMsbW9ub3NwYWNlOwp9Cip7Ym94LXNpemluZzpib3JkZXItYm94fQpodG1se2JhY2tncm91bmQ6dmFyKC0tYmcpO2NvbG9yOnZhcigtLXRleHQpO2ZvbnQtZmFtaWx5OnZhcigtLWZvbnQpO2ZvbnQtc2l6ZToxNnB4fQpib2R5e21hcmdpbjowO2JhY2tncm91bmQ6dmFyKC0tYmcpO21pbi1oZWlnaHQ6MTAwdmh9CmJ1dHRvbixhLHNlbGVjdCxpbnB1dHtmb250OmluaGVyaXR9CmF7Y29sb3I6aW5oZXJpdH0KLnNoZWxse3dpZHRoOm1pbigxNTAwcHgsY2FsYygxMDAlIC0gMzBweCkpO21hcmdpbjowIGF1dG99Ci50b3BiYXJ7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MjA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tbGluZSk7YmFja2dyb3VuZDpyZ2JhKDgsMTAsMTIsLjk0KTtiYWNrZHJvcC1maWx0ZXI6Ymx1cigxMnB4KX0KLnRvcGJhcl9faW5uZXJ7bWluLWhlaWdodDo2MnB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjIwcHh9Ci5icmFuZHtmb250LXNpemU6MTdweDtmb250LXdlaWdodDo3MDA7d2hpdGUtc3BhY2U6bm93cmFwfQouYnJhbmQgc21hbGx7bWFyZ2luLWxlZnQ6MTBweDtwYWRkaW5nLWxlZnQ6MTBweDtib3JkZXItbGVmdDoxcHggc29saWQgdmFyKC0tbGluZTIpO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLWRpbSk7Zm9udC13ZWlnaHQ6NjAwfQoudG9wLWFjdGlvbnN7bWFyZ2luLWxlZnQ6YXV0bztkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHh9Ci5saW5rYnRue2hlaWdodDozNnB4O2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6MCAxMnB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czo1cHg7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTt0ZXh0LWRlY29yYXRpb246bm9uZTtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NjUwfQoubGlua2J0bjpob3Zlcntjb2xvcjp2YXIoLS10ZXh0KTtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UyKX0KLnN0YXR1c2Jhcntib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lKTtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UpfQouc3RhdHVzYmFyX19pbm5lcnttaW4taGVpZ2h0OjQ0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MThweDtmbGV4LXdyYXA6d3JhcH0KLnNvdXJjZXtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7Zm9udC1zaXplOjE0cHg7Y29sb3I6dmFyKC0tbXV0ZWQpfQouZG90e3dpZHRoOjhweDtoZWlnaHQ6OHB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6dmFyKC0tZGltKX0KLmRvdC5nb29ke2JhY2tncm91bmQ6dmFyKC0tZ29vZCk7Ym94LXNoYWRvdzowIDAgMCAzcHggcmdiYSgxMTQsMjE1LDE2NCwuMDgpfQouZG90Lndhcm57YmFja2dyb3VuZDp2YXIoLS13YXJuKX0KLmRvdC5iYWR7YmFja2dyb3VuZDp2YXIoLS1iYWQpfQouc291cmNlIHN0cm9uZ3tjb2xvcjp2YXIoLS10ZXh0KTtmb250LXdlaWdodDo2NTB9Cm1haW57cGFkZGluZzoxOHB4IDAgNDBweH0KLnNlY3Rpb257bWFyZ2luLXRvcDoyMnB4fQouc2VjdGlvbjpmaXJzdC1jaGlsZHttYXJnaW4tdG9wOjB9Ci5zZWN0aW9uLWhlYWR7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmZsZXgtZW5kO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDoxOHB4O21hcmdpbi1ib3R0b206OXB4fQouc2VjdGlvbi1oZWFkIGgye21hcmdpbjowO2ZvbnQtc2l6ZToxOHB4O2ZvbnQtd2VpZ2h0OjcwMH0KLnNlY3Rpb24taGVhZCBwe21hcmdpbjozcHggMCAwO2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLW11dGVkKX0KLnNlY3Rpb24taGVhZCAubWV0YXtmb250LWZhbWlseTp2YXIoLS1tb25vKTtmb250LXNpemU6MTRweDtjb2xvcjp2YXIoLS1kaW0pO3RleHQtYWxpZ246cmlnaHR9Ci5tZXRyaWNze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDYsbWlubWF4KDE1MHB4LDFmcikpO2dhcDo4cHh9Ci5jYXJke21pbi13aWR0aDowO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czo2cHg7YmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTtwYWRkaW5nOjEycHh9Ci5jYXJkIC5re2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA0ZW07d2hpdGUtc3BhY2U6bm93cmFwO292ZXJmbG93OmhpZGRlbjt0ZXh0LW92ZXJmbG93OmVsbGlwc2lzfQouY2FyZCAudnttYXJnaW4tdG9wOjZweDtmb250LXNpemU6MjNweDtmb250LXdlaWdodDo3NTA7bGV0dGVyLXNwYWNpbmc6LS4wMjVlbTt3aGl0ZS1zcGFjZTpub3dyYXA7b3ZlcmZsb3c6aGlkZGVuO3RleHQtb3ZlcmZsb3c6ZWxsaXBzaXM7Zm9udC12YXJpYW50LW51bWVyaWM6dGFidWxhci1udW1zfQouY2FyZCAuZHttYXJnaW4tdG9wOjRweDtmb250LXNpemU6MTRweDtjb2xvcjp2YXIoLS1kaW0pO3doaXRlLXNwYWNlOm5vd3JhcDtvdmVyZmxvdzpoaWRkZW47dGV4dC1vdmVyZmxvdzplbGxpcHNpc30KLmdyaWQye2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6bWlubWF4KDAsMS41ZnIpIG1pbm1heCgzMjBweCwuNWZyKTtnYXA6OXB4fQoucGFuZWx7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjZweDtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UpO292ZXJmbG93OmhpZGRlbn0KLnBhbmVsLWhlYWR7aGVpZ2h0OjQycHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDtwYWRkaW5nOjAgMTFweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lKTtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UyKX0KLnBhbmVsLWhlYWQgc3Ryb25ne2ZvbnQtc2l6ZToxNXB4fQoucGFuZWwtaGVhZCBzcGFue2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLWRpbSk7d2hpdGUtc3BhY2U6bm93cmFwO292ZXJmbG93OmhpZGRlbjt0ZXh0LW92ZXJmbG93OmVsbGlwc2lzfQouY2hhcnR3cmFwe2hlaWdodDozMDBweDtwb3NpdGlvbjpyZWxhdGl2ZTtwYWRkaW5nOjhweH0KY2FudmFze2Rpc3BsYXk6YmxvY2s7d2lkdGg6MTAwJTtoZWlnaHQ6MTAwJX0KLmVtcHR5e3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7ZGlzcGxheTpncmlkO3BsYWNlLWl0ZW1zOmNlbnRlcjt0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjI1cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxNHB4O3BvaW50ZXItZXZlbnRzOm5vbmV9Ci5kZXRhaWxze2Rpc3BsYXk6Z3JpZH0KLmRldGFpbHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjE0NXB4IG1pbm1heCgwLDFmcik7Z2FwOjEycHg7cGFkZGluZzoxMHB4IDExcHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tbGluZSl9Ci5kZXRhaWw6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOjB9Ci5kZXRhaWwgLmt7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7Zm9udC1zaXplOjE0cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZX0KLmRldGFpbCAudntmb250LXNpemU6MTRweDtmb250LXdlaWdodDo2NTA7b3ZlcmZsb3ctd3JhcDphbnl3aGVyZX0KLndhcm5pbmd7bWFyZ2luLXRvcDo4cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjZweDtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UpO292ZXJmbG93OmhpZGRlbn0KLndhcm5pbmcgc3VtbWFyeXtjdXJzb3I6cG9pbnRlcjtwYWRkaW5nOjEwcHggMTFweDtmb250LXNpemU6MTRweDtmb250LXdlaWdodDo2NTA7Y29sb3I6dmFyKC0tbXV0ZWQpfQoud2FybmluZ1tvcGVuXSBzdW1tYXJ5e2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUpfQoud2FybmluZy10ZXh0e3BhZGRpbmc6MTBweCAxMXB4O2ZvbnQtc2l6ZToxNHB4O2xpbmUtaGVpZ2h0OjEuNTU7Y29sb3I6dmFyKC0tbXV0ZWQpfQoubGl2ZS1ub3Rle3BhZGRpbmc6OXB4IDExcHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjZweDtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UyKTtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjE0cHg7bGluZS1oZWlnaHQ6MS41O21hcmdpbi10b3A6OHB4fQpAbWVkaWEobWF4LXdpZHRoOjEyMDBweCl7Lm1ldHJpY3N7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOnJlcGVhdCgzLDFmcil9fQpAbWVkaWEobWF4LXdpZHRoOjkwMHB4KXsuZ3JpZDJ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn0ubWV0cmljc3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDIsMWZyKX19CkBtZWRpYShtYXgtd2lkdGg6NjIwcHgpey5zaGVsbHt3aWR0aDptaW4oMTAwJSAtIDE4cHgsMTUwMHB4KX0uYnJhbmQgc21hbGx7ZGlzcGxheTpub25lfS5tZXRyaWNze2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9LnRvcC1hY3Rpb25zIC5saW5rYnRuOmZpcnN0LWNoaWxke2Rpc3BsYXk6bm9uZX0uc2VjdGlvbi1oZWFke2FsaWduLWl0ZW1zOmZsZXgtc3RhcnQ7ZmxleC1kaXJlY3Rpb246Y29sdW1ufS5zZWN0aW9uLWhlYWQgLm1ldGF7dGV4dC1hbGlnbjpsZWZ0fS5kZXRhaWx7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcjtnYXA6M3B4fX0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPGhlYWRlciBjbGFzcz0idG9wYmFyIj4KIDxkaXYgY2xhc3M9InNoZWxsIHRvcGJhcl9faW5uZXIiPgogIDxkaXYgY2xhc3M9ImJyYW5kIj5QZXJmb3JtYW5jZSBMYWIgPHNtYWxsPi9kYXNoIHRlc3Q8L3NtYWxsPjwvZGl2PgogIDxkaXYgY2xhc3M9InRvcC1hY3Rpb25zIj4KICAgPGEgY2xhc3M9ImxpbmtidG4iIGhyZWY9Ii8iPk1haW4gZGFzaGJvYXJkPC9hPgogICA8YSBjbGFzcz0ibGlua2J0biIgaHJlZj0iL2FwaS9jYXBmcmFtZXgiIHRhcmdldD0iX2JsYW5rIj5DYXBGcmFtZVggQVBJPC9hPgogIDwvZGl2PgogPC9kaXY+CjwvaGVhZGVyPgoKPGRpdiBjbGFzcz0ic3RhdHVzYmFyIj4KIDxkaXYgY2xhc3M9InNoZWxsIHN0YXR1c2Jhcl9faW5uZXIiPgogIDxkaXYgY2xhc3M9InNvdXJjZSI+PHNwYW4gY2xhc3M9ImRvdCIgaWQ9Imh3RG90Ij48L3NwYW4+PHN0cm9uZz5IV2lORk88L3N0cm9uZz48c3BhbiBpZD0iaHdTdGF0ZSI+Y29ubmVjdGluZ+KApjwvc3Bhbj48L2Rpdj4KICA8ZGl2IGNsYXNzPSJzb3VyY2UiPjxzcGFuIGNsYXNzPSJkb3QiIGlkPSJjZnhEb3QiPjwvc3Bhbj48c3Ryb25nPkNhcEZyYW1lWCBsaXZlPC9zdHJvbmc+PHNwYW4gaWQ9ImNmeExpdmVTdGF0ZSI+Y29ubmVjdGluZ+KApjwvc3Bhbj48L2Rpdj4KICA8ZGl2IGNsYXNzPSJzb3VyY2UiPjxzcGFuIGNsYXNzPSJkb3QiIGlkPSJjYXB0dXJlRG90Ij48L3NwYW4+PHN0cm9uZz5DYXB0dXJlPC9zdHJvbmc+PHNwYW4gaWQ9ImNhcHR1cmVTdGF0ZSI+Y2hlY2tpbmfigKY8L3NwYW4+PC9kaXY+CiA8L2Rpdj4KPC9kaXY+Cgo8bWFpbiBjbGFzcz0ic2hlbGwiPgogPHNlY3Rpb24gY2xhc3M9InNlY3Rpb24iPgogIDxkaXYgY2xhc3M9InNlY3Rpb24taGVhZCI+CiAgIDxkaXY+PGgyPkxpdmUgZnJhbWUgcGlwZWxpbmU8L2gyPjxwPlJlYWwtdGltZSBDYXBGcmFtZVggbWV0cmljcy4gVGhpcyBpcyBpbmRlcGVuZGVudCBvZiB0aGUgY29tcGxldGVkLWNhcHR1cmUgYW5hbHlzaXMgYmVsb3cuPC9wPjwvZGl2PgogICA8ZGl2IGNsYXNzPSJtZXRhIiBpZD0ibGl2ZUFnZSI+4oCUPC9kaXY+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0ibWV0cmljcyI+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPkF2ZXJhZ2UgRlBTPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImxpdmVBdmciPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPkNhcEZyYW1lWCBvbmxpbmUgbWV0cmljPC9kaXY+PC9kaXY+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPlA5NSBGUFM8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0ibGl2ZVA5NSI+4oCUPC9kaXY+PGRpdiBjbGFzcz0iZCI+Q2FwRnJhbWVYIG9ubGluZSBtZXRyaWM8L2Rpdj48L2Rpdj4KICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iayI+UDEgRlBTPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImxpdmVQMSI+4oCUPC9kaXY+PGRpdiBjbGFzcz0iZCI+Q2FwRnJhbWVYIG9ubGluZSBtZXRyaWM8L2Rpdj48L2Rpdj4KICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iayI+MSUgTG93IEF2ZzwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJsaXZlTG93MSI+4oCUPC9kaXY+PGRpdiBjbGFzcz0iZCI+Q2FwRnJhbWVYIG9ubGluZSBtZXRyaWM8L2Rpdj48L2Rpdj4KICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iayI+Q1BVIEJ1c3k8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0ibGl2ZUNwdUJ1c3kiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPkZyYW1lIHBpcGVsaW5lPC9kaXY+PC9kaXY+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPkdQVSBCdXN5PC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImxpdmVHcHVCdXN5Ij7igJQ8L2Rpdj48ZGl2IGNsYXNzPSJkIj5GcmFtZSBwaXBlbGluZTwvZGl2PjwvZGl2PgogIDwvZGl2PgogPC9zZWN0aW9uPgoKIDxzZWN0aW9uIGNsYXNzPSJzZWN0aW9uIj4KICA8ZGl2IGNsYXNzPSJzZWN0aW9uLWhlYWQiPgogICA8ZGl2PjxoMj5IV2lORk8gbGl2ZSB0ZWxlbWV0cnk8L2gyPjxwPlNlbGVjdGVkIGhhcmR3YXJlIHJlYWRpbmdzIGZyb20gdGhlIHNhbWUgSFdpTkZPIGVuZHBvaW50IHVzZWQgYnkgdGhlIG1haW4gZGFzaGJvYXJkLjwvcD48L2Rpdj4KICAgPGRpdiBjbGFzcz0ibWV0YSIgaWQ9Imh3UG9sbCI+4oCUPC9kaXY+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0ibWV0cmljcyI+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPkdQVSB1dGlsaXphdGlvbjwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJod0dwdSI+4oCUPC9kaXY+PGRpdiBjbGFzcz0iZCIgaWQ9Imh3R3B1U3JjIj5ObyBzb3VyY2U8L2Rpdj48L2Rpdj4KICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iayI+Q1BVIG1heCB0aHJlYWQ8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0iaHdDcHVNYXgiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiIGlkPSJod0NwdU1heFNyYyI+Tm8gc291cmNlPC9kaXY+PC9kaXY+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPkdQVSBwb3dlcjwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJod0dwdVBvd2VyIj7igJQ8L2Rpdj48ZGl2IGNsYXNzPSJkIiBpZD0iaHdHcHVQb3dlclNyYyI+Tm8gc291cmNlPC9kaXY+PC9kaXY+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPkNQVSBwYWNrYWdlIHBvd2VyPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9Imh3Q3B1UG93ZXIiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiIGlkPSJod0NwdVBvd2VyU3JjIj5ObyBzb3VyY2U8L2Rpdj48L2Rpdj4KICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iayI+R1BVIHRlbXBlcmF0dXJlPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9Imh3R3B1VGVtcCI+4oCUPC9kaXY+PGRpdiBjbGFzcz0iZCIgaWQ9Imh3R3B1VGVtcFNyYyI+Tm8gc291cmNlPC9kaXY+PC9kaXY+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPkNQVSB0ZW1wZXJhdHVyZTwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJod0NwdVRlbXAiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiIGlkPSJod0NwdVRlbXBTcmMiPk5vIHNvdXJjZTwvZGl2PjwvZGl2PgogIDwvZGl2PgogPC9zZWN0aW9uPgoKIDxzZWN0aW9uIGNsYXNzPSJzZWN0aW9uIj4KICA8ZGl2IGNsYXNzPSJzZWN0aW9uLWhlYWQiPgogICA8ZGl2PjxoMj5MYXRlc3QgY29tcGxldGVkIGNhcHR1cmU8L2gyPjxwPlBvc3QtY2FwdHVyZSBhbmFseXNpcyBzdGF5cyBzZXBhcmF0ZSBmcm9tIGxpdmUgdGVsZW1ldHJ5LjwvcD48L2Rpdj4KICAgPGRpdiBjbGFzcz0ibWV0YSIgaWQ9ImNhcHR1cmVNZXRhIj7igJQ8L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0ibWV0cmljcyI+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPkF2ZXJhZ2UgRlBTPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImNhcEF2ZyI+4oCUPC9kaXY+PGRpdiBjbGFzcz0iZCI+RnVsbCBjYXB0dXJlPC9kaXY+PC9kaXY+CiAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImsiPjElIExvdyBBdmc8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0iY2FwTG93MSI+4oCUPC9kaXY+PGRpdiBjbGFzcz0iZCI+VGltZS1iYXNlZCBsb3cgYXZlcmFnZTwvZGl2PjwvZGl2PgogICA8ZGl2IGNsYXNzPSJjYXJkIj48ZGl2IGNsYXNzPSJrIj4wLjIlIExvdyBBdmc8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0iY2FwTG93MDIiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPlJhcmUgc2V2ZXJlIGRpcHM8L2Rpdj48L2Rpdj4KICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iayI+UDEgRlBTPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImNhcFAxIj7igJQ8L2Rpdj48ZGl2IGNsYXNzPSJkIj4xc3QgcGVyY2VudGlsZTwvZGl2PjwvZGl2PgogICA8ZGl2IGNsYXNzPSJjYXJkIj48ZGl2IGNsYXNzPSJrIj5QMC4yIEZQUzwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJjYXBQMDIiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPjAuMm5kIHBlcmNlbnRpbGU8L2Rpdj48L2Rpdj4KICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iayI+RHVyYXRpb248L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0iY2FwRHVyYXRpb24iPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiIGlkPSJjYXBGcmFtZXMiPuKAlCBmcmFtZXM8L2Rpdj48L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0iZ3JpZDIiIHN0eWxlPSJtYXJnaW4tdG9wOjhweCI+CiAgIDxkaXYgY2xhc3M9InBhbmVsIj4KICAgIDxkaXYgY2xhc3M9InBhbmVsLWhlYWQiPjxzdHJvbmc+RnJhbWV0aW1lPC9zdHJvbmc+PHNwYW4gaWQ9ImNoYXJ0TWV0YSI+4oCUPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2hhcnR3cmFwIj4KICAgICA8Y2FudmFzIGlkPSJjaGFydCI+PC9jYW52YXM+CiAgICAgPGRpdiBjbGFzcz0iZW1wdHkiIGlkPSJjaGFydEVtcHR5Ij5ObyBjb21wbGV0ZWQgQ2FwRnJhbWVYIGNhcHR1cmUgYXZhaWxhYmxlLjwvZGl2PgogICAgPC9kaXY+CiAgIDwvZGl2PgoKICAgPGRpdiBjbGFzcz0icGFuZWwiPgogICAgPGRpdiBjbGFzcz0icGFuZWwtaGVhZCI+PHN0cm9uZz5DYXB0dXJlIGRldGFpbHM8L3N0cm9uZz48c3BhbiBpZD0iY2FwRGF0ZSI+4oCUPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGV0YWlscyI+CiAgICAgPGRpdiBjbGFzcz0iZGV0YWlsIj48ZGl2IGNsYXNzPSJrIj5HYW1lPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImNhcEdhbWUiPuKAlDwvZGl2PjwvZGl2PgogICAgIDxkaXYgY2xhc3M9ImRldGFpbCI+PGRpdiBjbGFzcz0iayI+UHJvY2VzczwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJjYXBQcm9jZXNzIj7igJQ8L2Rpdj48L2Rpdj4KICAgICA8ZGl2IGNsYXNzPSJkZXRhaWwiPjxkaXYgY2xhc3M9ImsiPk1ldHJpYyBzb3VyY2U8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0iY2FwU291cmNlIj7igJQ8L2Rpdj48L2Rpdj4KICAgICA8ZGl2IGNsYXNzPSJkZXRhaWwiPjxkaXYgY2xhc3M9ImsiPkZyYW1lIHNwaWtlczwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJjYXBTdHV0dGVycyI+4oCUPC9kaXY+PC9kaXY+CiAgICAgPGRpdiBjbGFzcz0iZGV0YWlsIj48ZGl2IGNsYXNzPSJrIj5GcmVlemVzIOKJpTEwMCBtczwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJjYXBGcmVlemVzIj7igJQ8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogICA8L2Rpdj4KICA8L2Rpdj4KCiAgPGRldGFpbHMgY2xhc3M9Indhcm5pbmciIGlkPSJzb3VyY2VXYXJuaW5nIj4KICAgPHN1bW1hcnk+U291cmNlIC8gZnJhbWUtZ2VuZXJhdGlvbiB3YXJuaW5nPC9zdW1tYXJ5PgogICA8ZGl2IGNsYXNzPSJ3YXJuaW5nLXRleHQiIGlkPSJ3YXJuaW5nVGV4dCI+Tm8gd2FybmluZy48L2Rpdj4KICA8L2RldGFpbHM+CgogIDxkaXYgY2xhc3M9ImxpdmUtbm90ZSI+CiAgIFRoaXMgdGVzdCBwYWdlIGludGVudGlvbmFsbHkgZG9lcyBub3QgYXR0ZW1wdCBIV2lORk8g4oaUIGhpc3RvcmljYWwtZnJhbWUgY29ycmVsYXRpb24geWV0LiBUaGUgZXhpc3RpbmcgaW1wbGVtZW50YXRpb24gc3RvcmVzIEhXaU5GTyBoaXN0b3J5IGluIHRoZSBicm93c2VyLCBzbyBhIHJlZnJlc2ggY2FuIGxvc2UgbWF0Y2hpbmcgc2FtcGxlcy4KICA8L2Rpdj4KIDwvc2VjdGlvbj4KPC9tYWluPgoKPHNjcmlwdD4KY29uc3QgJD1pZD0+ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwpjb25zdCBmbXQ9KHYsdW5pdD0nJyxkaWdpdHM9MSk9PnsKIGNvbnN0IG49TnVtYmVyKHYpO2lmKCFOdW1iZXIuaXNGaW5pdGUobikpcmV0dXJuICfigJQnOwogcmV0dXJuIG4udG9Mb2NhbGVTdHJpbmcodW5kZWZpbmVkLHttaW5pbXVtRnJhY3Rpb25EaWdpdHM6ZGlnaXRzLG1heGltdW1GcmFjdGlvbkRpZ2l0czpkaWdpdHN9KSsodW5pdD8nICcrdW5pdDonJyk7Cn07CmNvbnN0IG5vcm09cz0+U3RyaW5nKHN8fCcnKS50b0xvd2VyQ2FzZSgpLnJlcGxhY2UoL1xzKy9nLCcgJykudHJpbSgpOwpjb25zdCB0eHQ9cj0+bm9ybSgocj8uU2Vuc29yfHwnJykrJyAnKyhyPy5TZW5zb3JPcmlnaW5hbHx8JycpKycgJysocj8uTGFiZWx8fCcnKSsnICcrKHI/LkxhYmVsT3JpZ2luYWx8fCcnKSk7CmZ1bmN0aW9uIHNldERvdChpZCxzdGF0ZSl7ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLmNsYXNzTmFtZT0nZG90ICcrKHN0YXRlfHwnJyl9CmZ1bmN0aW9uIHNldE1ldHJpYyhpZCx2LHVuaXQsZGlnaXRzPTEpe2RvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS50ZXh0Q29udGVudD1mbXQodix1bml0LGRpZ2l0cyl9CmZ1bmN0aW9uIGZpbmRSZWFkaW5nKHJvd3MscHJlZGljYXRlcyl7CiBmb3IoY29uc3QgcCBvZiBwcmVkaWNhdGVzKXtjb25zdCByPXJvd3MuZmluZChwKTtpZihyKXJldHVybiByfQogcmV0dXJuIG51bGw7Cn0KZnVuY3Rpb24gcmVhZGluZ0Rpc3BsYXkocil7CiBpZighcnx8IU51bWJlci5pc0Zpbml0ZShOdW1iZXIoci5WYWx1ZSkpKXJldHVybiAn4oCUJzsKIGNvbnN0IHU9U3RyaW5nKHIuVW5pdHx8JycpLnRyaW0oKTsKIGxldCBkPTE7aWYoL3JwbXxmcHMvaS50ZXN0KHUpKWQ9MDsKIHJldHVybiBmbXQoci5WYWx1ZSx1LGQpOwp9CmZ1bmN0aW9uIHNldEh3KGlkLHNyY0lkLHIpewogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50PXJlYWRpbmdEaXNwbGF5KHIpOwogZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoc3JjSWQpLnRleHRDb250ZW50PXI/KHIuTGFiZWx8fHIuTGFiZWxPcmlnaW5hbHx8ci5TZW5zb3J8fCdIV2lORk8nKTonTm8gbWF0Y2hpbmcgc291cmNlJzsKfQphc3luYyBmdW5jdGlvbiBwb2xsSHcoKXsKIHRyeXsKICBjb25zdCByZXM9YXdhaXQgZmV0Y2goJy9hcGkvc2Vuc29ycz9fPScrRGF0ZS5ub3coKSx7Y2FjaGU6J25vLXN0b3JlJ30pOwogIGNvbnN0IGQ9YXdhaXQgcmVzLmpzb24oKTsKICBpZighZD8uT2spdGhyb3cgbmV3IEVycm9yKGQ/LkVycm9yfHwnTm8gSFdpTkZPIGRhdGEnKTsKICBjb25zdCByb3dzPWQuUmVhZGluZ3N8fFtdOwogIHNldERvdCgnaHdEb3QnLCdnb29kJyk7ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2h3U3RhdGUnKS50ZXh0Q29udGVudD0nbGl2ZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2h3UG9sbCcpLnRleHRDb250ZW50PWQuUG9sbGluZ1BlcmlvZE1zP2QuUG9sbGluZ1BlcmlvZE1zKycgbXMgc291cmNlIHBvbGwnOidzb3VyY2UgY29ubmVjdGVkJzsKCiAgY29uc3QgZ3B1PWZpbmRSZWFkaW5nKHJvd3MsWwogICByPT4vZ3B1IGNvcmUgbG9hZHxncHUgdXRpbGl6YXRpb24vLnRlc3QodHh0KHIpKSAmJiAvJS8udGVzdChTdHJpbmcoci5Vbml0fHwnJykpLAogICByPT4vZ3B1Lipsb2FkLy50ZXN0KHR4dChyKSkgJiYgLyUvLnRlc3QoU3RyaW5nKHIuVW5pdHx8JycpKQogIF0pOwogIGNvbnN0IGNwdU1heD1maW5kUmVhZGluZyhyb3dzLFsKICAgcj0+L21heCBjcHUgdGhyZWFkIHVzYWdlfG1heGltdW0gY3B1IHRocmVhZCB1c2FnZS8udGVzdCh0eHQocikpLAogICByPT4vbWF4IGNwdSBjb3JlIHVzYWdlfG1heGltdW0gY3B1IGNvcmUgdXNhZ2UvLnRlc3QodHh0KHIpKQogIF0pOwogIGNvbnN0IGdwdVBvd2VyPWZpbmRSZWFkaW5nKHJvd3MsWwogICByPT4vZ3B1IGFzaWMgcG93ZXJ8Z3B1IHRvdGFsIGJvYXJkIHBvd2VyfHRvdGFsIGJvYXJkIHBvd2VyfGdwdSBib2FyZCBwb3dlcnxncHUgY2hpcCBwb3dlcnxncmFwaGljcyBwb3dlci8udGVzdCh0eHQocikpICYmIC9edyR8d2F0dC9pLnRlc3QoU3RyaW5nKHIuVW5pdHx8JycpKSwKICAgcj0+L2dwdSBwb3dlci8udGVzdCh0eHQocikpICYmIC9edyR8d2F0dC9pLnRlc3QoU3RyaW5nKHIuVW5pdHx8JycpKQogIF0pOwogIGNvbnN0IGNwdVBvd2VyPWZpbmRSZWFkaW5nKHJvd3MsWwogICByPT4vY3B1IHBhY2thZ2UgcG93ZXJ8cGFja2FnZSBwb3dlci8udGVzdCh0eHQocikpICYmIC9edyR8d2F0dC9pLnRlc3QoU3RyaW5nKHIuVW5pdHx8JycpKQogIF0pOwogIGNvbnN0IGdwdVRlbXA9ZmluZFJlYWRpbmcocm93cyxbCiAgIHI9Pi9ncHUgdGVtcGVyYXR1cmUvLnRlc3QodHh0KHIpKSYmIS9ob3QgP3Nwb3R8anVuY3Rpb24vLnRlc3QodHh0KHIpKQogIF0pOwogIGNvbnN0IGNwdVRlbXA9ZmluZFJlYWRpbmcocm93cyxbCiAgIHI9Pi9jcHUgdGN0bCB0ZGllfGNwdSBwYWNrYWdlIHRlbXBlcmF0dXJlLy50ZXN0KHR4dChyKSksCiAgIHI9Pi9jcHUuKnRlbXBlcmF0dXJlLy50ZXN0KHR4dChyKSkmJiEvY29yZS8udGVzdCh0eHQocikpCiAgXSk7CgogIHNldEh3KCdod0dwdScsJ2h3R3B1U3JjJyxncHUpOwogIHNldEh3KCdod0NwdU1heCcsJ2h3Q3B1TWF4U3JjJyxjcHVNYXgpOwogIHNldEh3KCdod0dwdVBvd2VyJywnaHdHcHVQb3dlclNyYycsZ3B1UG93ZXIpOwogIHNldEh3KCdod0NwdVBvd2VyJywnaHdDcHVQb3dlclNyYycsY3B1UG93ZXIpOwogIHNldEh3KCdod0dwdVRlbXAnLCdod0dwdVRlbXBTcmMnLGdwdVRlbXApOwogIHNldEh3KCdod0NwdVRlbXAnLCdod0NwdVRlbXBTcmMnLGNwdVRlbXApOwogfWNhdGNoKGUpewogIHNldERvdCgnaHdEb3QnLCdiYWQnKTtkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaHdTdGF0ZScpLnRleHRDb250ZW50PSdvZmZsaW5lJzsKIH0KfQphc3luYyBmdW5jdGlvbiBwb2xsTGl2ZSgpewogdHJ5ewogIGNvbnN0IHJlcz1hd2FpdCBmZXRjaCgnL2FwaS9jYXBmcmFtZXgvbGl2ZT9fPScrRGF0ZS5ub3coKSx7Y2FjaGU6J25vLXN0b3JlJ30pOwogIGNvbnN0IGQ9YXdhaXQgcmVzLmpzb24oKTsKICBpZighZD8uQXZhaWxhYmxlKXRocm93IG5ldyBFcnJvcihkPy5NZXNzYWdlfHwnQ2FwRnJhbWVYIGxpdmUgdW5hdmFpbGFibGUnKTsKICBzZXREb3QoJ2NmeERvdCcsJ2dvb2QnKTtkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2Z4TGl2ZVN0YXRlJykudGV4dENvbnRlbnQ9J2xpdmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXZlQWdlJykudGV4dENvbnRlbnQ9J3VwZGF0ZWQgJytuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygpOwogIHNldE1ldHJpYygnbGl2ZUF2ZycsZC5NZXRyaWNzPy5BdmVyYWdlLCdGUFMnKTsKICBzZXRNZXRyaWMoJ2xpdmVQOTUnLGQuTWV0cmljcz8uUDk1LCdGUFMnKTsKICBzZXRNZXRyaWMoJ2xpdmVQMScsZC5NZXRyaWNzPy5QMSwnRlBTJyk7CiAgc2V0TWV0cmljKCdsaXZlTG93MScsZC5NZXRyaWNzPy5PbmVQZXJjZW50TG93QXZlcmFnZSwnRlBTJyk7CiAgc2V0TWV0cmljKCdsaXZlQ3B1QnVzeScsZC5NZXRyaWNzPy5DUFVCdXN5LCdtcycsMik7CiAgc2V0TWV0cmljKCdsaXZlR3B1QnVzeScsZC5NZXRyaWNzPy5HUFVCdXN5LCdtcycsMik7CiB9Y2F0Y2goZSl7CiAgc2V0RG90KCdjZnhEb3QnLCdiYWQnKTtkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2Z4TGl2ZVN0YXRlJykudGV4dENvbnRlbnQ9J3VuYXZhaWxhYmxlJzsKICBbJ2xpdmVBdmcnLCdsaXZlUDk1JywnbGl2ZVAxJywnbGl2ZUxvdzEnLCdsaXZlQ3B1QnVzeScsJ2xpdmVHcHVCdXN5J10uZm9yRWFjaChpZD0+ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50PSfigJQnKTsKIH0KfQpmdW5jdGlvbiBzYW5pdGl6ZShzKXsKIHJldHVybiBTdHJpbmcoc3x8JycpCiAgLnJlcGxhY2VBbGwoJ8OD4oCUJywnw5cnKQogIC5yZXBsYWNlQWxsKCfDouKCrOKAnScsJ+KAlCcpCiAgLnJlcGxhY2VBbGwoJ8Oi4oKs4oCcJywn4oCTJykKICAucmVwbGFjZUFsbCgnw6LigqzLnCcsJ+KAmCcpCiAgLnJlcGxhY2VBbGwoJ8Oi4oKs4oSiJywn4oCZJykKICAucmVwbGFjZUFsbCgnw6LigqzFkycsJ+KAnCcpCiAgLnJlcGxhY2VBbGwoJ8Oi4oKswp0nLCfigJ0nKTsKfQpmdW5jdGlvbiBkcmF3Q2FwdHVyZShwb2ludHMpewogY29uc3QgY2FudmFzPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGFydCcpLGVtcHR5PWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGFydEVtcHR5Jyk7CiBpZighcG9pbnRzPy5sZW5ndGgpe2VtcHR5LnN0eWxlLmRpc3BsYXk9J2dyaWQnO3JldHVybn0KIGVtcHR5LnN0eWxlLmRpc3BsYXk9J25vbmUnOwogY29uc3QgcmVjdD1jYW52YXMuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCksZHByPU1hdGgubWF4KDEsZGV2aWNlUGl4ZWxSYXRpb3x8MSk7CiBjb25zdCB3PU1hdGgubWF4KDEsTWF0aC5mbG9vcihyZWN0LndpZHRoKmRwcikpLGg9TWF0aC5tYXgoMSxNYXRoLmZsb29yKHJlY3QuaGVpZ2h0KmRwcikpOwogaWYoY2FudmFzLndpZHRoIT09d3x8Y2FudmFzLmhlaWdodCE9PWgpe2NhbnZhcy53aWR0aD13O2NhbnZhcy5oZWlnaHQ9aH0KIGNvbnN0IGM9Y2FudmFzLmdldENvbnRleHQoJzJkJyk7Yy5jbGVhclJlY3QoMCwwLHcsaCk7CiBjb25zdCBwdHM9cG9pbnRzLmZpbHRlcihwPT5OdW1iZXIuaXNGaW5pdGUoTnVtYmVyKHAuVFNlYykpJiZOdW1iZXIuaXNGaW5pdGUoTnVtYmVyKHAuRnJhbWV0aW1lTXMpKSk7CiBpZihwdHMubGVuZ3RoPDIpcmV0dXJuOwogY29uc3QgdmFsdWVzPXB0cy5tYXAocD0+TnVtYmVyKHAuRnJhbWV0aW1lTXMpKS5maWx0ZXIodj0+dj4wKS5zb3J0KChhLGIpPT5hLWIpOwogY29uc3QgcWk9TWF0aC5tYXgoMCxNYXRoLm1pbih2YWx1ZXMubGVuZ3RoLTEsTWF0aC5mbG9vcih2YWx1ZXMubGVuZ3RoKi45OTUpKSk7CiBjb25zdCB5bWF4PU1hdGgubWF4KDE2LjcsKHZhbHVlc1txaV18fDE2LjcpKjEuMjUpOwogY29uc3QgdDA9TnVtYmVyKHB0c1swXS5UU2VjKSx0MT1OdW1iZXIocHRzLmF0KC0xKS5UU2VjKXx8dDArMTsKIGNvbnN0IEw9OCpkcHIsUj13LTgqZHByLFQ9OCpkcHIsQj1oLTI0KmRwcjsKIGNvbnN0IGNzPWdldENvbXB1dGVkU3R5bGUoZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50KTsKIGNvbnN0IGdyaWQ9Y3MuZ2V0UHJvcGVydHlWYWx1ZSgnLS1saW5lJykudHJpbSgpLGxpbmU9Y3MuZ2V0UHJvcGVydHlWYWx1ZSgnLS1jaGFydCcpLnRyaW0oKSxtdXRlZD1jcy5nZXRQcm9wZXJ0eVZhbHVlKCctLW11dGVkJykudHJpbSgpOwogYy5zdHJva2VTdHlsZT1ncmlkO2MubGluZVdpZHRoPTEqZHByOwogZm9yKGxldCBpPTA7aTw0O2krKyl7Y29uc3QgeT1UKyhCLVQpKmkvMztjLmJlZ2luUGF0aCgpO2MubW92ZVRvKEwseSk7Yy5saW5lVG8oUix5KTtjLnN0cm9rZSgpfQogYy5zdHJva2VTdHlsZT1saW5lO2MubGluZVdpZHRoPTEuNCpkcHI7Yy5iZWdpblBhdGgoKTsKIHB0cy5mb3JFYWNoKChwLGkpPT57CiAgY29uc3QgeD1MKyhSLUwpKihOdW1iZXIocC5UU2VjKS10MCkvTWF0aC5tYXgoLjAwMSx0MS10MCk7CiAgY29uc3QgeT1CLShCLVQpKk1hdGgubWluKHltYXgsTnVtYmVyKHAuRnJhbWV0aW1lTXMpKS95bWF4OwogIGk/Yy5saW5lVG8oeCx5KTpjLm1vdmVUbyh4LHkpOwogfSk7Yy5zdHJva2UoKTsKIGMuZm9udD0oMTQqZHByKSsncHggU2Vnb2UgVUknO2MuZmlsbFN0eWxlPW11dGVkOwogYy5maWxsVGV4dCh5bWF4LnRvRml4ZWQoMSkrJyBtcycsOCpkcHIsMTUqZHByKTsKIGMuZmlsbFRleHQoJzAgbXMnLDgqZHByLGgtNCpkcHIpOwp9CmFzeW5jIGZ1bmN0aW9uIHBvbGxDYXB0dXJlKCl7CiB0cnl7CiAgY29uc3QgcmVzPWF3YWl0IGZldGNoKCcvYXBpL2NhcGZyYW1leD9fPScrRGF0ZS5ub3coKSx7Y2FjaGU6J25vLXN0b3JlJ30pOwogIGNvbnN0IGQ9YXdhaXQgcmVzLmpzb24oKTsKICBpZighZD8uQXZhaWxhYmxlKXRocm93IG5ldyBFcnJvcihkPy5NZXNzYWdlfHwnQ2FwRnJhbWVYIHVuYXZhaWxhYmxlJyk7CiAgaWYoZC5TdGF0dXM/LklzQ2FwdHVyaW5nKXsKICAgc2V0RG90KCdjYXB0dXJlRG90Jywnd2FybicpO2RvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjYXB0dXJlU3RhdGUnKS50ZXh0Q29udGVudD0nY2FwdHVyaW5nJzsKICB9ZWxzZXsKICAgc2V0RG90KCdjYXB0dXJlRG90JywnZ29vZCcpO2RvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjYXB0dXJlU3RhdGUnKS50ZXh0Q29udGVudD0naWRsZSc7CiAgfQogIGNvbnN0IHg9ZC5MYXRlc3Q7aWYoIXgpcmV0dXJuOwogIHNldE1ldHJpYygnY2FwQXZnJyx4Lk1ldHJpY3M/LkF2ZXJhZ2UsJ0ZQUycpOwogIHNldE1ldHJpYygnY2FwTG93MScseC5NZXRyaWNzPy5PbmVQZXJjZW50TG93QXZlcmFnZSwnRlBTJyk7CiAgc2V0TWV0cmljKCdjYXBMb3cwMicseC5NZXRyaWNzPy5aZXJvZG90VHdvUGVyY2VudExvd0F2ZXJhZ2UsJ0ZQUycpOwogIHNldE1ldHJpYygnY2FwUDEnLHguTWV0cmljcz8uUDEsJ0ZQUycpOwogIHNldE1ldHJpYygnY2FwUDAyJyx4Lk1ldHJpY3M/LlAwZG90MiwnRlBTJyk7CiAgc2V0TWV0cmljKCdjYXBEdXJhdGlvbicseC5EdXJhdGlvblNlYywncycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjYXBGcmFtZXMnKS50ZXh0Q29udGVudD1OdW1iZXIoeC5GcmFtZUNvdW50fHwwKS50b0xvY2FsZVN0cmluZygpKycgZnJhbWVzJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2FwR2FtZScpLnRleHRDb250ZW50PXguR2FtZXx8J+KAlCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NhcFByb2Nlc3MnKS50ZXh0Q29udGVudD14LlByb2Nlc3NOYW1lfHwn4oCUJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2FwU291cmNlJykudGV4dENvbnRlbnQ9eC5NZXRyaWNTb3VyY2V8fCfigJQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjYXBTdHV0dGVycycpLnRleHRDb250ZW50PU51bWJlci5pc0Zpbml0ZShOdW1iZXIoeC5TdHV0dGVyQ291bnQpKT9TdHJpbmcoeC5TdHV0dGVyQ291bnQpOifigJQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjYXBGcmVlemVzJykudGV4dENvbnRlbnQ9TnVtYmVyLmlzRmluaXRlKE51bWJlcih4LkZyZWV6ZUNvdW50KSk/U3RyaW5nKHguRnJlZXplQ291bnQpOifigJQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjYXBEYXRlJykudGV4dENvbnRlbnQ9eC5SZWNvcmRlZEF0P25ldyBEYXRlKHguUmVjb3JkZWRBdCkudG9Mb2NhbGVTdHJpbmcoKTon4oCUJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2FwdHVyZU1ldGEnKS50ZXh0Q29udGVudD0oeC5HYW1lfHx4LlByb2Nlc3NOYW1lfHwnY2FwdHVyZScpKycgwrcgJytmbXQoeC5EdXJhdGlvblNlYywncycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGFydE1ldGEnKS50ZXh0Q29udGVudD0oeC5NZXRyaWNTb3VyY2V8fCdmcmFtZXRpbWUnKSsnIMK3ICcrTnVtYmVyKHguRnJhbWVDb3VudHx8MCkudG9Mb2NhbGVTdHJpbmcoKSsnIGZyYW1lcyc7CiAgY29uc3Qgd2FybmluZz1zYW5pdGl6ZSh4Lk1ldHJpY1NvdXJjZVdhcm5pbmd8fCcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd2FybmluZ1RleHQnKS50ZXh0Q29udGVudD13YXJuaW5nfHwnTm8gc291cmNlIHdhcm5pbmcgZm9yIHRoZSBjdXJyZW50IGNhcHR1cmUuJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc291cmNlV2FybmluZycpLnN0eWxlLmRpc3BsYXk9d2FybmluZz8nYmxvY2snOidub25lJzsKICBkcmF3Q2FwdHVyZSh4LkZyYW1ldGltZXN8fFtdKTsKIH1jYXRjaChlKXsKICBzZXREb3QoJ2NhcHR1cmVEb3QnLCdiYWQnKTtkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2FwdHVyZVN0YXRlJykudGV4dENvbnRlbnQ9J3VuYXZhaWxhYmxlJzsKIH0KfQphc3luYyBmdW5jdGlvbiB0aWNrKCl7YXdhaXQgUHJvbWlzZS5hbGxTZXR0bGVkKFtwb2xsSHcoKSxwb2xsTGl2ZSgpLHBvbGxDYXB0dXJlKCldKX0Kd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsKCk9PnBvbGxDYXB0dXJlKCkpOwp0aWNrKCk7CnNldEludGVydmFsKHRpY2ssMTUwMCk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4="))
# DASH-TEST-END
# CAPTURE-DASH-V2-BEGIN
$captureDashHtml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9InV0Zi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+V2luIFN0YXQgU2VydmVyIHY4IOKAlCBDYXB0dXJlIEFuYWx5emVyPC90aXRsZT4KPHN0eWxlPgo6cm9vdHsKICAtLWJnOiMwNzBhMGY7LS1wYW5lbDojMGUxNDFkOy0tcGFuZWwyOiMxMjFhMjY7LS1wYW5lbDM6IzE4MjMzMzsKICAtLWxpbmU6IzIyMzA0MzstLWxpbmUtc29mdDojMTkyNTM0Oy0tdGV4dDojZWVmNGZiOy0tbXV0ZWQ6IzgzOTJhODsKICAtLWFjY2VudDojNmVhOGZmOy0tZ29vZDojNzRkNDlhOy0td2FybjojZWZjNTZjOy0tYmFkOiNlZTdhODY7CiAgLS1jaGFydC1ncmlkOnJnYmEoMTMxLDE0NiwxNjgsLjE4KTstLWNoYXJ0LWxpbmU6cmdiYSgxMTAsMTY4LDI1NSwuOTYpOy0tY2hhcnQtaG92ZXI6cmdiYSgyMzgsMjQ0LDI1MSwuNTgpOwogIC0tc2hhZG93OjAgMTJweCAzNXB4IHJnYmEoMCwwLDAsLjIwKTsKICBmb250LWZhbWlseTpJbnRlcix1aS1zYW5zLXNlcmlmLHN5c3RlbS11aSwtYXBwbGUtc3lzdGVtLCJTZWdvZSBVSSIsQXJpYWwsc2Fucy1zZXJpZjsKfQoqe2JveC1zaXppbmc6Ym9yZGVyLWJveH0KaHRtbHtiYWNrZ3JvdW5kOnZhcigtLWJnKTtjb2xvcjp2YXIoLS10ZXh0KTtmb250LXNpemU6MTRweH0KYm9keXttYXJnaW46MDttaW4taGVpZ2h0OjEwMHZoO2JhY2tncm91bmQ6dmFyKC0tYmcpfQpidXR0b24sc2VsZWN0LGlucHV0e2ZvbnQ6aW5oZXJpdH1idXR0b257Y3Vyc29yOnBvaW50ZXJ9Ci5zaGVsbHt3aWR0aDptaW4oMTYyMHB4LGNhbGMoMTAwJSAtIDI4cHgpKTttYXJnaW46YXV0b30KLnRvcGJhcntwb3NpdGlvbjpzdGlja3k7dG9wOjA7ei1pbmRleDo0MDtiYWNrZ3JvdW5kOnJnYmEoNywxMCwxNSwuOTUpO2JhY2tkcm9wLWZpbHRlcjpibHVyKDE0cHgpO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCl9Ci50b3BiYXJpbnttaW4taGVpZ2h0OjU2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweH0KLmJyYW5ke2ZvbnQtc2l6ZToxNnB4O2ZvbnQtd2VpZ2h0Ojc2MDtsZXR0ZXItc3BhY2luZzotLjAyZW19LmJyYW5kIHNwYW57bWFyZ2luLWxlZnQ6OXB4O3BhZGRpbmctbGVmdDo5cHg7Ym9yZGVyLWxlZnQ6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTFweDtmb250LXdlaWdodDo2MDB9Ci5hY3Rpb25ze21hcmdpbi1sZWZ0OmF1dG99Ci5idG57bWluLWhlaWdodDozMnB4O3BhZGRpbmc6NXB4IDEwcHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjhweDtiYWNrZ3JvdW5kOnZhcigtLXBhbmVsKTtjb2xvcjp2YXIoLS10ZXh0KTtmb250LXNpemU6MTFweDtmb250LXdlaWdodDo2NTA7dGV4dC1kZWNvcmF0aW9uOm5vbmU7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcn0KLmJ0bjpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLXBhbmVsMil9LmJ0bi5wcmltYXJ5e2JvcmRlci1jb2xvcjpjb2xvci1taXgoaW4gc3JnYix2YXIoLS1hY2NlbnQpIDQwJSx2YXIoLS1saW5lKSk7YmFja2dyb3VuZDpjb2xvci1taXgoaW4gc3JnYix2YXIoLS1hY2NlbnQpIDEwJSx2YXIoLS1wYW5lbCkpfS5idG46ZGlzYWJsZWR7b3BhY2l0eTouNDI7Y3Vyc29yOm5vdC1hbGxvd2VkfQptYWlue3BhZGRpbmc6MTJweCAwIDM4cHh9Ci5jYXB0dXJlYmFye2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6bWlubWF4KDM2MHB4LDFmcikgYXV0bztnYXA6MTJweDthbGlnbi1pdGVtczplbmQ7cGFkZGluZzoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMXB4O2JhY2tncm91bmQ6dmFyKC0tcGFuZWwpfQouZmllbGQgbGFiZWx7ZGlzcGxheTpibG9jazttYXJnaW4tYm90dG9tOjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjlweDtmb250LXdlaWdodDo3MDA7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wNmVtfQpzZWxlY3QsaW5wdXRbdHlwZT1udW1iZXJdLGlucHV0W3R5cGU9c2VhcmNoXXt3aWR0aDoxMDAlO21pbi1oZWlnaHQ6MzRweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6OHB4O2JhY2tncm91bmQ6dmFyKC0tcGFuZWwyKTtjb2xvcjp2YXIoLS10ZXh0KTtwYWRkaW5nOjZweCA5cHg7Zm9udC1zaXplOjExcHh9CnNlbGVjdCBvcHRpb257YmFja2dyb3VuZDojMTIxYTI2O2NvbG9yOiNlZWY0ZmJ9Ci5jYXB0dXJlbWV0YXt0ZXh0LWFsaWduOnJpZ2h0O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTBweDtsaW5lLWhlaWdodDoxLjQ1fQouc3RhdHVze2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHh9LmRvdHt3aWR0aDo3cHg7aGVpZ2h0OjdweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW11dGVkKX0uZG90Lmdvb2R7YmFja2dyb3VuZDp2YXIoLS1nb29kKX0uZG90LmJhZHtiYWNrZ3JvdW5kOnZhcigtLWJhZCl9Ci5zZWN0aW9uaGVhZHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6ZmxleC1lbmQ7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEycHg7bWFyZ2luOjE1cHggMCA4cHh9Ci5zZWN0aW9uaGVhZCBoMnttYXJnaW46MDtmb250LXNpemU6MTRweH0uc2VjdGlvbmhlYWQgcHttYXJnaW46M3B4IDAgMDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEwcHh9LnNtYWxsbWV0YXtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEwcHg7dGV4dC1hbGlnbjpyaWdodH0KLmZwc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoYXV0by1maXQsbWlubWF4KDE0NXB4LDFmcikpO2dhcDo4cHh9Ci5tZXRyaWN7YmFja2dyb3VuZDp2YXIoLS1wYW5lbCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjExcHg7cGFkZGluZzo5cHh9Ci5tZXRyaWMgLmt7Zm9udC1zaXplOjlweDtjb2xvcjp2YXIoLS1tdXRlZCk7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wNmVtfS5tZXRyaWMgLnZ7Zm9udC1zaXplOjE4cHg7Zm9udC13ZWlnaHQ6NzYwO21hcmdpbi10b3A6NHB4O2ZvbnQtdmFyaWFudC1udW1lcmljOnRhYnVsYXItbnVtc30ubWV0cmljIC5ke2ZvbnQtc2l6ZTo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6M3B4fQoubWFpbkdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczptaW5tYXgoMCwxLjdmcikgbWlubWF4KDMwMHB4LC41NWZyKTtnYXA6OHB4O21hcmdpbi10b3A6OHB4fQoucGFuZWx7YmFja2dyb3VuZDp2YXIoLS1wYW5lbCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjExcHg7b3ZlcmZsb3c6aGlkZGVufQoucGFuZWxoZWFke2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEwcHg7cGFkZGluZzo4cHggMTBweDtiYWNrZ3JvdW5kOnZhcigtLXBhbmVsMik7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tbGluZS1zb2Z0KX0KLnBhbmVsaGVhZCBzdHJvbmd7Zm9udC1zaXplOjExcHh9LnBhbmVsaGVhZCBzcGFue2ZvbnQtc2l6ZTo5cHg7Y29sb3I6dmFyKC0tbXV0ZWQpfQouZnJhbWVjaGFydHtoZWlnaHQ6MzAwcHg7cG9zaXRpb246cmVsYXRpdmU7cGFkZGluZzo2cHggOHB4IDhweDt0b3VjaC1hY3Rpb246bm9uZX0KLmZyYW1lY2hhcnQgY2FudmFzLC5waW4tY2hhcnQgY2FudmFze3dpZHRoOjEwMCU7aGVpZ2h0OjEwMCU7ZGlzcGxheTpibG9ja30KLmVtcHR5T3ZlcmxheXtwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6Z3JpZDtwbGFjZS1pdGVtczpjZW50ZXI7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMHB4O3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MTZweDtwb2ludGVyLWV2ZW50czpub25lfQouZGV0YWlsc3tkaXNwbGF5OmdyaWR9LmRldGFpbHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjExMHB4IG1pbm1heCgwLDFmcik7Z2FwOjhweDtwYWRkaW5nOjhweCAxMHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCl9LmRldGFpbDpsYXN0LWNoaWxke2JvcmRlci1ib3R0b206MH0KLmRldGFpbCAua3tmb250LXNpemU6OHB4O2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA1ZW19LmRldGFpbCAudntmb250LXNpemU6MTBweDtmb250LXdlaWdodDo2NTA7b3ZlcmZsb3ctd3JhcDphbnl3aGVyZX0KCi8qIEhvdmVyIHN0cmlwIGRpcmVjdGx5IGJlbG93IG1hc3RlciBncmFwaCAqLwouaG92ZXJzdHJpcHttYXJnaW4tdG9wOjhweDtiYWNrZ3JvdW5kOnZhcigtLXBhbmVsKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6MTFweDtvdmVyZmxvdzpoaWRkZW59Ci5ob3ZlcnN0cmlwLWhlYWR7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTBweDtwYWRkaW5nOjdweCA5cHg7YmFja2dyb3VuZDp2YXIoLS1wYW5lbDIpO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCl9Ci5ob3ZlcnN0cmlwLWhlYWQgc3Ryb25ne2ZvbnQtc2l6ZToxMHB4fS5ob3ZlcnN0cmlwLWhlYWQgc3Bhbntmb250LXNpemU6OXB4O2NvbG9yOnZhcigtLW11dGVkKX0KLmhvdmVyY2VsbHN7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoYXV0by1maXQsbWlubWF4KDE1MHB4LDFmcikpfQouaG92ZXJjZWxse21pbi13aWR0aDowO3BhZGRpbmc6N3B4IDlweDtib3JkZXItcmlnaHQ6MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tbGluZS1zb2Z0KX0KLmhvdmVyY2VsbCAua3tmb250LXNpemU6OHB4O2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA1ZW07d2hpdGUtc3BhY2U6bm93cmFwO292ZXJmbG93OmhpZGRlbjt0ZXh0LW92ZXJmbG93OmVsbGlwc2lzfQouaG92ZXJjZWxsIC52e2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0Ojc0MDttYXJnaW4tdG9wOjJweDt3aGl0ZS1zcGFjZTpub3dyYXA7b3ZlcmZsb3c6aGlkZGVuO3RleHQtb3ZlcmZsb3c6ZWxsaXBzaXM7Zm9udC12YXJpYW50LW51bWVyaWM6dGFidWxhci1udW1zfQouaG92ZXJjZWxsIC5ke2ZvbnQtc2l6ZTo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MXB4O3doaXRlLXNwYWNlOm5vd3JhcDtvdmVyZmxvdzpoaWRkZW47dGV4dC1vdmVyZmxvdzplbGxpcHNpc30KCi5yYW5nZWJhcntkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjEyNXB4IDEyNXB4IGF1dG8gYXV0byAxZnI7Z2FwOjdweDthbGlnbi1pdGVtczplbmQ7bWFyZ2luLXRvcDo4cHh9Ci5yYW5nZWluZm97YWxpZ24tc2VsZjpjZW50ZXI7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMHB4O21hcmdpbi1sZWZ0OjRweH0KLndhcm5pbmd7bWFyZ2luLXRvcDo4cHg7YmFja2dyb3VuZDp2YXIoLS1wYW5lbCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVufS53YXJuaW5nIHN1bW1hcnl7Y3Vyc29yOnBvaW50ZXI7cGFkZGluZzo4cHggMTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEwcHg7Zm9udC13ZWlnaHQ6NjUwfS53YXJuaW5nYm9keXtwYWRkaW5nOjhweCAxMHB4O2JvcmRlci10b3A6MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCk7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMHB4O2xpbmUtaGVpZ2h0OjEuNX0KCi8qIEhhcmR3YXJlIGFyZWE6IGNvcmUgdG9nZ2xlcyBsZWZ0LCBncmFwaHMgcmlnaHQgKi8KLmhhcmR3YXJlTGF5b3V0e2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6Mjg1cHggbWlubWF4KDAsMWZyKTtnYXA6MTBweDthbGlnbi1pdGVtczpzdGFydH0KLmNvcmVQYW5lbHtiYWNrZ3JvdW5kOnZhcigtLXBhbmVsKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6MTJweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246c3RpY2t5O3RvcDo3MHB4fQouY29yZUhlYWR7cGFkZGluZzoxMHB4IDExcHg7YmFja2dyb3VuZDp2YXIoLS1wYW5lbDIpO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCl9Ci5jb3JlSGVhZCBzdHJvbmd7ZGlzcGxheTpibG9jaztmb250LXNpemU6MTFweH0uY29yZUhlYWQgc3BhbntkaXNwbGF5OmJsb2NrO2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6OXB4O21hcmdpbi10b3A6MnB4O2xpbmUtaGVpZ2h0OjEuNH0KLmNvcmVMaXN0e2Rpc3BsYXk6Z3JpZH0KLmNvcmVSb3d7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczptaW5tYXgoMCwxZnIpIGF1dG87Z2FwOjhweDthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzo4cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lLXNvZnQpfQouY29yZVJvdzpsYXN0LWNoaWxke2JvcmRlci1ib3R0b206MH0uY29yZUNvcHl7bWluLXdpZHRoOjB9LmNvcmVDb3B5IHN0cm9uZ3tkaXNwbGF5OmJsb2NrO2ZvbnQtc2l6ZToxMHB4O3doaXRlLXNwYWNlOm5vd3JhcDtvdmVyZmxvdzpoaWRkZW47dGV4dC1vdmVyZmxvdzplbGxpcHNpc30uY29yZUNvcHkgc21hbGx7ZGlzcGxheTpibG9jaztjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjhweDttYXJnaW4tdG9wOjJweDt3aGl0ZS1zcGFjZTpub3dyYXA7b3ZlcmZsb3c6aGlkZGVuO3RleHQtb3ZlcmZsb3c6ZWxsaXBzaXN9Ci5zd2l0Y2h7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6MzRweDtoZWlnaHQ6MTlweDtmbGV4OjAgMCBhdXRvfS5zd2l0Y2ggaW5wdXR7cG9zaXRpb246YWJzb2x1dGU7b3BhY2l0eTowO3BvaW50ZXItZXZlbnRzOm5vbmV9LnRyYWNre3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjk5OXB4O2JhY2tncm91bmQ6dmFyKC0tcGFuZWwzKTt0cmFuc2l0aW9uOi4xNXN9LnRodW1ie3Bvc2l0aW9uOmFic29sdXRlO2xlZnQ6M3B4O3RvcDozcHg7d2lkdGg6MTFweDtoZWlnaHQ6MTFweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW11dGVkKTt0cmFuc2l0aW9uOi4xNXN9Ci5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCsudHJhY2t7YmFja2dyb3VuZDpjb2xvci1taXgoaW4gc3JnYix2YXIoLS1hY2NlbnQpIDIzJSx2YXIoLS1wYW5lbDMpKTtib3JkZXItY29sb3I6Y29sb3ItbWl4KGluIHNyZ2IsdmFyKC0tYWNjZW50KSA1NSUsdmFyKC0tbGluZSkpfS5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCsudHJhY2sgLnRodW1ie3RyYW5zZm9ybTp0cmFuc2xhdGVYKDE1cHgpO2JhY2tncm91bmQ6dmFyKC0tYWNjZW50KX0KLnN3aXRjaCBpbnB1dDpkaXNhYmxlZCsudHJhY2t7b3BhY2l0eTouMzV9Ci5jb3JlRm9vdHtwYWRkaW5nOjlweCAxMHB4O2JvcmRlci10b3A6MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCk7YmFja2dyb3VuZDp2YXIoLS1wYW5lbDIpfQouY29yZUZvb3QgLmJ0bnt3aWR0aDoxMDAlfQoKLyogR3JhcGggY2FyZHMgY29waWVkIGluIHNwaXJpdCBmcm9tIG1haW4gZGFzaGJvYXJkICovCi5waW5ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KGF1dG8tZml0LG1pbm1heCgzMzBweCwxZnIpKTtnYXA6MTBweH0KLnBpbi1jYXJke2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE4MGRlZyx2YXIoLS1wYW5lbDIpLHZhcigtLXBhbmVsKSk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjE0cHg7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTttaW4td2lkdGg6MH0KLnBpbi1oZWFke2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpmbGV4LXN0YXJ0O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDo5cHg7cGFkZGluZzoxMHB4IDExcHggN3B4fQoucGluLXRpdGxle21pbi13aWR0aDowfS5waW4tdGl0bGUgLmx7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NzUwO3doaXRlLXNwYWNlOm5vd3JhcDtvdmVyZmxvdzpoaWRkZW47dGV4dC1vdmVyZmxvdzplbGxpcHNpc30ucGluLXRpdGxlIC5ne2ZvbnQtc2l6ZTo5cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO3doaXRlLXNwYWNlOm5vd3JhcDtvdmVyZmxvdzpoaWRkZW47dGV4dC1vdmVyZmxvdzplbGxpcHNpczttYXJnaW4tdG9wOjJweH0KLmNhdGJhZGdle2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6MnB4IDZweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6OTk5cHg7Zm9udC1zaXplOjhweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDo1cHh9LmNhdGJhZGdlLnJlY29yZGVke2NvbG9yOnZhcigtLWdvb2QpO2JvcmRlci1jb2xvcjpjb2xvci1taXgoaW4gc3JnYix2YXIoLS1nb29kKSAzOCUsdmFyKC0tbGluZSkpfQoucGluLWFjdGlvbnN7ZGlzcGxheTpmbGV4O2dhcDo0cHh9Lmljb25idG57bWluLWhlaWdodDoyN3B4O3BhZGRpbmc6NHB4IDdweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6N3B4O2JhY2tncm91bmQ6dmFyKC0tcGFuZWwpO2NvbG9yOnZhcigtLXRleHQpO2ZvbnQtc2l6ZToxMHB4fQoucGluLXByaW1hcnl7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmZsZXgtZW5kO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDo4cHg7cGFkZGluZzowIDExcHggOXB4fS5iaWd7Zm9udC1zaXplOjI5cHg7Zm9udC13ZWlnaHQ6ODAwO2xldHRlci1zcGFjaW5nOi0uMDM1ZW07Zm9udC12YXJpYW50LW51bWVyaWM6dGFidWxhci1udW1zfS5zbWFsbG1vZGV7Zm9udC1zaXplOjlweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDoycHh9Ci5zdGF0Z3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOnJlcGVhdCg0LDFmcik7Z2FwOjFweDtiYWNrZ3JvdW5kOnZhcigtLWxpbmUtc29mdCk7Ym9yZGVyLXRvcDoxcHggc29saWQgdmFyKC0tbGluZS1zb2Z0KTtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lLXNvZnQpfQouc2JveHtiYWNrZ3JvdW5kOnZhcigtLXBhbmVsKTtwYWRkaW5nOjZweCA3cHg7bWluLXdpZHRoOjB9LnNib3ggLmt7Zm9udC1zaXplOjhweDtjb2xvcjp2YXIoLS1tdXRlZCk7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wNWVtfS5zYm94IC52e2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjY1MDttYXJnaW4tdG9wOjJweDt3aGl0ZS1zcGFjZTpub3dyYXA7b3ZlcmZsb3c6aGlkZGVuO3RleHQtb3ZlcmZsb3c6ZWxsaXBzaXM7Zm9udC12YXJpYW50LW51bWVyaWM6dGFidWxhci1udW1zfQoucGluLWNoYXJ0e2hlaWdodDoxMjZweDtwb3NpdGlvbjpyZWxhdGl2ZTtwYWRkaW5nOjZweCA4cHggOHB4O3RvdWNoLWFjdGlvbjpub25lfS5jaGFydC1sZWdlbmR7cG9zaXRpb246YWJzb2x1dGU7bGVmdDoxMHB4O2JvdHRvbTo3cHg7Zm9udC1zaXplOjhweDtjb2xvcjp2YXIoLS1tdXRlZCk7cG9pbnRlci1ldmVudHM6bm9uZX0KLm5vLWhpc3Rvcnl7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDtkaXNwbGF5OmdyaWQ7cGxhY2UtaXRlbXM6Y2VudGVyO3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MTRweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjlweDtwb2ludGVyLWV2ZW50czpub25lfQouY2FyZHNFbXB0eXtib3JkZXI6MXB4IGRhc2hlZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoyMHB4O3RleHQtYWxpZ246Y2VudGVyO2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTBweH0KCi8qIEV4dHJhLW1ldHJpYyBtb2RhbCBncm91cGVkIHdpdGggQWRkIGJ1dHRvbnMgKi8KLm1vZGFsYmFja3twb3NpdGlvbjpmaXhlZDtpbnNldDowO3otaW5kZXg6MzAwO2Rpc3BsYXk6bm9uZTtwbGFjZS1pdGVtczpjZW50ZXI7cGFkZGluZzoxOHB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNTUpO2JhY2tkcm9wLWZpbHRlcjpibHVyKDRweCl9Ci5tb2RhbHt3aWR0aDptaW4oNzgwcHgsOTZ2dyk7bWF4LWhlaWdodDptaW4oNzkwcHgsOTB2aCk7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtvdmVyZmxvdzpoaWRkZW47YmFja2dyb3VuZDp2YXIoLS1wYW5lbCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjE0cHg7Ym94LXNoYWRvdzowIDI0cHggODBweCByZ2JhKDAsMCwwLC40NSl9Ci5tb2RhbGhlYWR7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDtwYWRkaW5nOjExcHggMTJweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lLXNvZnQpO2JhY2tncm91bmQ6dmFyKC0tcGFuZWwyKX0KLm1vZGFsaGVhZCBzdHJvbmd7Zm9udC1zaXplOjEycHh9Lm1vZGFsaGVhZCBzcGFue2Rpc3BsYXk6YmxvY2s7bWFyZ2luLXRvcDoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZTo5cHh9Ci5tb2RhbHNlYXJjaHtwYWRkaW5nOjlweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lLXNvZnQpfQouZ3JvdXBlZExpc3R7b3ZlcmZsb3c6YXV0bztwYWRkaW5nOjZweH0KLm1ncm91cHtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCk7Ym9yZGVyLXJhZGl1czoxMHB4O292ZXJmbG93OmhpZGRlbjttYXJnaW4tYm90dG9tOjdweH0ubWdyb3VwOmxhc3QtY2hpbGR7bWFyZ2luLWJvdHRvbTowfQoubWdyb3VwSGVhZHtwYWRkaW5nOjdweCA5cHg7YmFja2dyb3VuZDp2YXIoLS1wYW5lbDIpO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCk7Zm9udC1zaXplOjlweDtmb250LXdlaWdodDo3NTA7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wNmVtO2NvbG9yOnZhcigtLW11dGVkKX0KLmV4dHJhUm93e2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6bWlubWF4KDAsMWZyKSBhdXRvIGF1dG87Z2FwOjhweDthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzo3cHggOXB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCl9LmV4dHJhUm93Omxhc3QtY2hpbGR7Ym9yZGVyLWJvdHRvbTowfQouZXh0cmFDb3B5e21pbi13aWR0aDowfS5leHRyYUNvcHkgc3Ryb25ne2Rpc3BsYXk6YmxvY2s7Zm9udC1zaXplOjEwcHg7d2hpdGUtc3BhY2U6bm93cmFwO292ZXJmbG93OmhpZGRlbjt0ZXh0LW92ZXJmbG93OmVsbGlwc2lzfS5leHRyYUNvcHkgc21hbGx7ZGlzcGxheTpibG9jazttYXJnaW4tdG9wOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjhweDt3aGl0ZS1zcGFjZTpub3dyYXA7b3ZlcmZsb3c6aGlkZGVuO3RleHQtb3ZlcmZsb3c6ZWxsaXBzaXN9Ci5iYWRnZXtwYWRkaW5nOjJweCA2cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjk5OXB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6OHB4O3doaXRlLXNwYWNlOm5vd3JhcH0uYmFkZ2Uub2t7Y29sb3I6dmFyKC0tZ29vZCk7Ym9yZGVyLWNvbG9yOmNvbG9yLW1peChpbiBzcmdiLHZhcigtLWdvb2QpIDQwJSx2YXIoLS1saW5lKSl9Ci5tb2RhbGZvb3R7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpmbGV4LWVuZDtnYXA6N3B4O3BhZGRpbmc6OXB4IDEwcHg7Ym9yZGVyLXRvcDoxcHggc29saWQgdmFyKC0tbGluZS1zb2Z0KTtiYWNrZ3JvdW5kOnZhcigtLXBhbmVsMil9CgoubG9hZGVyV3JhcHtkaXNwbGF5Om5vbmU7bWFyZ2luLXRvcDoxMnB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMXB4O2JhY2tncm91bmQ6dmFyKC0tcGFuZWwpO21pbi1oZWlnaHQ6MTYwcHg7cGxhY2UtaXRlbXM6Y2VudGVyfS5sb2FkZXJib3h7dGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMHB4fS5zcGlubmVye3dpZHRoOjMwcHg7aGVpZ2h0OjMwcHg7bWFyZ2luOjAgYXV0byA5cHg7Ym9yZGVyOjNweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItdG9wLWNvbG9yOnZhcigtLWFjY2VudCk7Ym9yZGVyLXJhZGl1czo1MCU7YW5pbWF0aW9uOnNwaW4gLjcycyBsaW5lYXIgaW5maW5pdGV9QGtleWZyYW1lcyBzcGlue3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19Ci5wbGFjZWhvbGRlcnttYXJnaW4tdG9wOjEycHg7Ym9yZGVyOjFweCBkYXNoZWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMXB4O3BhZGRpbmc6MjZweDt0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEwcHh9CiNjb250ZW50e2Rpc3BsYXk6bm9uZX0KQG1lZGlhKG1heC13aWR0aDoxMDUwcHgpey5oYXJkd2FyZUxheW91dHtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS5jb3JlUGFuZWx7cG9zaXRpb246c3RhdGljfS5jb3JlTGlzdHtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDIsMWZyKX0uY29yZVJvdzpudGgtY2hpbGQob2RkKXtib3JkZXItcmlnaHQ6MXB4IHNvbGlkIHZhcigtLWxpbmUtc29mdCl9fQpAbWVkaWEobWF4LXdpZHRoOjkwMHB4KXsubWFpbkdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn0ucmFuZ2ViYXJ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnIgYXV0byBhdXRvfS5yYW5nZWluZm97Z3JpZC1jb2x1bW46MS8tMX0ucGluZ3JpZHtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfX0KQG1lZGlhKG1heC13aWR0aDo2MjBweCl7LnNoZWxse3dpZHRoOm1pbigxMDAlIC0gMTZweCwxNjIwcHgpfS5icmFuZCBzcGFue2Rpc3BsYXk6bm9uZX0uY2FwdHVyZWJhcntncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS5jYXB0dXJlbWV0YXt0ZXh0LWFsaWduOmxlZnR9LmNvcmVMaXN0e2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9LmNvcmVSb3c6bnRoLWNoaWxkKG9kZCl7Ym9yZGVyLXJpZ2h0OjB9LnN0YXRncmlke2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoMiwxZnIpfS5yYW5nZWJhcntncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcn19Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+CjxoZWFkZXIgY2xhc3M9InRvcGJhciI+PGRpdiBjbGFzcz0ic2hlbGwgdG9wYmFyaW4iPjxkaXYgY2xhc3M9ImJyYW5kIj5DYXB0dXJlIEFuYWx5emVyIDxzcGFuPldpbiBTdGF0IFNlcnZlciB2ODwvc3Bhbj48L2Rpdj48ZGl2IGNsYXNzPSJhY3Rpb25zIj48YSBjbGFzcz0iYnRuIiBocmVmPSIvIj5NYWluIGRhc2hib2FyZDwvYT48L2Rpdj48L2Rpdj48L2hlYWRlcj4KCjxtYWluIGNsYXNzPSJzaGVsbCI+CiA8ZGl2IGNsYXNzPSJjYXB0dXJlYmFyIj4KICA8ZGl2IGNsYXNzPSJmaWVsZCI+PGxhYmVsPkNhcHR1cmU8L2xhYmVsPjxzZWxlY3QgaWQ9ImNhcHR1cmVTZWxlY3QiPjxvcHRpb24gdmFsdWU9IiI+TG9hZGluZyBjYXB0dXJlIGxpc3TigKY8L29wdGlvbj48L3NlbGVjdD48L2Rpdj4KICA8ZGl2IGNsYXNzPSJjYXB0dXJlbWV0YSI+PGRpdiBjbGFzcz0ic3RhdHVzIj48c3BhbiBjbGFzcz0iZG90IiBpZD0iYXBpRG90Ij48L3NwYW4+PHN0cm9uZyBpZD0iYXBpU3RhdGUiPkNvbm5lY3Rpbmc8L3N0cm9uZz48L2Rpdj48ZGl2IGlkPSJjYXB0dXJlSW5mbyI+Q2hvb3NlIGEgY2FwdHVyZSB0byBiZWdpbi48L2Rpdj48L2Rpdj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9ImxvYWRlcldyYXAiIGlkPSJsb2FkZXIiPjxkaXYgY2xhc3M9ImxvYWRlcmJveCI+PGRpdiBjbGFzcz0ic3Bpbm5lciI+PC9kaXY+PHN0cm9uZz5Mb2FkaW5nIGNhcHR1cmXigKY8L3N0cm9uZz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+RnJhbWV0aW1lcyArIHJlY29yZGVkIHNlbnNvcnM8L2Rpdj48L2Rpdj48L2Rpdj4KIDxkaXYgY2xhc3M9InBsYWNlaG9sZGVyIiBpZD0icGxhY2Vob2xkZXIiPlNlbGVjdCBhIENhcEZyYW1lWCBjYXB0dXJlLiBOb3RoaW5nIGlzIGxvYWRlZCBhdXRvbWF0aWNhbGx5LjwvZGl2PgoKIDxkaXYgaWQ9ImNvbnRlbnQiPgogIDxkaXYgY2xhc3M9InNlY3Rpb25oZWFkIj48ZGl2PjxoMj5GcmFtZSBhbmFseXNpczwvaDI+PHA+SG92ZXIgc2hvd3Mgc3luY2hyb25pemVkIHZhbHVlcyBiZWxvdy4gRHJhZyBvbmx5IHdoZW4geW91IHdhbnQgdG8gc2VsZWN0IGEgcmFuZ2UuPC9wPjwvZGl2PjxkaXYgY2xhc3M9InNtYWxsbWV0YSIgaWQ9ImZyYW1lTWV0YSI+4oCUPC9kaXY+PC9kaXY+CgogIDxkaXYgY2xhc3M9ImZwc2dyaWQiPgogICA8ZGl2IGNsYXNzPSJtZXRyaWMiPjxkaXYgY2xhc3M9ImsiPkF2ZXJhZ2UgRlBTPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImtBdmciPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPmZ1bGwgY2FwdHVyZTwvZGl2PjwvZGl2PgogICA8ZGl2IGNsYXNzPSJtZXRyaWMiPjxkaXYgY2xhc3M9ImsiPjElIExvdyBBdmc8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0ia0xvdzEiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPmZ1bGwgY2FwdHVyZTwvZGl2PjwvZGl2PgogICA8ZGl2IGNsYXNzPSJtZXRyaWMiPjxkaXYgY2xhc3M9ImsiPjAuMiUgTG93IEF2ZzwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJrTG93MDIiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPmZ1bGwgY2FwdHVyZTwvZGl2PjwvZGl2PgogICA8ZGl2IGNsYXNzPSJtZXRyaWMiPjxkaXYgY2xhc3M9ImsiPlAxIEZQUzwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJrUDEiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPmZ1bGwgY2FwdHVyZTwvZGl2PjwvZGl2PgogICA8ZGl2IGNsYXNzPSJtZXRyaWMiPjxkaXYgY2xhc3M9ImsiPlAwLjIgRlBTPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImtQMDIiPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImQiPmZ1bGwgY2FwdHVyZTwvZGl2PjwvZGl2PgogICA8ZGl2IGNsYXNzPSJtZXRyaWMiPjxkaXYgY2xhc3M9ImsiPkFuYWx5c2lzIEF2ZyBGUFM8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBpZD0ia1NlbEF2ZyI+4oCUPC9kaXY+PGRpdiBjbGFzcz0iZCIgaWQ9ImtTZWxEZXNjIj5mdWxsIGNhcHR1cmU8L2Rpdj48L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0ibWFpbkdyaWQiPgogICA8ZGl2IGNsYXNzPSJwYW5lbCI+CiAgICA8ZGl2IGNsYXNzPSJwYW5lbGhlYWQiPjxzdHJvbmc+RnJhbWV0aW1lPC9zdHJvbmc+PHNwYW4gaWQ9InJhbmdlTGFiZWwiPk5vIHJhbmdlIHNlbGVjdGVkPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iZnJhbWVjaGFydCI+PGNhbnZhcyBpZD0iZnJhbWVDaGFydCI+PC9jYW52YXM+PGRpdiBjbGFzcz0iZW1wdHlPdmVybGF5IiBpZD0iZnJhbWVFbXB0eSI+Tm8gZnJhbWV0aW1lIGRhdGEuPC9kaXY+PC9kaXY+CiAgIDwvZGl2PgoKICAgPGRpdiBjbGFzcz0icGFuZWwiPgogICAgPGRpdiBjbGFzcz0icGFuZWxoZWFkIj48c3Ryb25nPkNhcHR1cmU8L3N0cm9uZz48c3BhbiBpZD0iY2FwRGF0ZSI+4oCUPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGV0YWlscyI+CiAgICAgPGRpdiBjbGFzcz0iZGV0YWlsIj48ZGl2IGNsYXNzPSJrIj5HYW1lPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImNhcEdhbWUiPuKAlDwvZGl2PjwvZGl2PgogICAgIDxkaXYgY2xhc3M9ImRldGFpbCI+PGRpdiBjbGFzcz0iayI+UHJvY2VzczwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJjYXBQcm9jZXNzIj7igJQ8L2Rpdj48L2Rpdj4KICAgICA8ZGl2IGNsYXNzPSJkZXRhaWwiPjxkaXYgY2xhc3M9ImsiPkR1cmF0aW9uPC9kaXY+PGRpdiBjbGFzcz0idiIgaWQ9ImNhcER1cmF0aW9uIj7igJQ8L2Rpdj48L2Rpdj4KICAgICA8ZGl2IGNsYXNzPSJkZXRhaWwiPjxkaXYgY2xhc3M9ImsiPkZyYW1lczwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJjYXBGcmFtZXMiPuKAlDwvZGl2PjwvZGl2PgogICAgIDxkaXYgY2xhc3M9ImRldGFpbCI+PGRpdiBjbGFzcz0iayI+TWV0cmljIHNvdXJjZTwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJjYXBTb3VyY2UiPuKAlDwvZGl2PjwvZGl2PgogICAgIDxkaXYgY2xhc3M9ImRldGFpbCI+PGRpdiBjbGFzcz0iayI+UmVjb3JkZWQgc2Vuc29yczwvZGl2PjxkaXYgY2xhc3M9InYiIGlkPSJjYXBTZW5zb3JzIj7igJQ8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogICA8L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0iaG92ZXJzdHJpcCI+CiAgIDxkaXYgY2xhc3M9ImhvdmVyc3RyaXAtaGVhZCI+PHN0cm9uZz5Ib3ZlcmVkIGZyYW1lPC9zdHJvbmc+PHNwYW4gaWQ9ImhvdmVyVGltZSI+TW92ZSBvdmVyIHRoZSBmcmFtZXRpbWUgZ3JhcGg8L3NwYW4+PC9kaXY+CiAgIDxkaXYgY2xhc3M9ImhvdmVyY2VsbHMiIGlkPSJob3ZlckNlbGxzIj48L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0icmFuZ2ViYXIiPgogICA8ZGl2IGNsYXNzPSJmaWVsZCI+PGxhYmVsPlN0YXJ0IChzKTwvbGFiZWw+PGlucHV0IGlkPSJyYW5nZVN0YXJ0IiB0eXBlPSJudW1iZXIiIG1pbj0iMCIgc3RlcD0iMC4xIiBwbGFjZWhvbGRlcj0i4oCUIj48L2Rpdj4KICAgPGRpdiBjbGFzcz0iZmllbGQiPjxsYWJlbD5FbmQgKHMpPC9sYWJlbD48aW5wdXQgaWQ9InJhbmdlRW5kIiB0eXBlPSJudW1iZXIiIG1pbj0iMCIgc3RlcD0iMC4xIiBwbGFjZWhvbGRlcj0i4oCUIj48L2Rpdj4KICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBpZD0iYXBwbHlSYW5nZSI+QXBwbHkgcmFuZ2U8L2J1dHRvbj4KICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBpZD0iY2xlYXJSYW5nZSIgZGlzYWJsZWQ+Q2xlYXIgc2VsZWN0aW9uPC9idXR0b24+CiAgIDxkaXYgY2xhc3M9InJhbmdlaW5mbyIgaWQ9InJhbmdlSW5mbyI+Tm8gc2VsZWN0aW9uIMK3IHN0YXRpc3RpY3MgdXNlIGZ1bGwgY2FwdHVyZTwvZGl2PgogIDwvZGl2PgoKICA8ZGV0YWlscyBjbGFzcz0id2FybmluZyIgaWQ9InNvdXJjZVdhcm5pbmciPjxzdW1tYXJ5PlNvdXJjZSAvIGZyYW1lLWdlbmVyYXRpb24gd2FybmluZzwvc3VtbWFyeT48ZGl2IGNsYXNzPSJ3YXJuaW5nYm9keSIgaWQ9Indhcm5pbmdUZXh0Ij48L2Rpdj48L2RldGFpbHM+CgogIDxkaXYgY2xhc3M9InNlY3Rpb25oZWFkIj4KICAgPGRpdj48aDI+SGFyZHdhcmUgbWV0cmljczwvaDI+PHA+RXNzZW50aWFsIGJvdHRsZW5lY2sgbWV0cmljcyBvbiB0aGUgbGVmdC4gU2VsZWN0ZWQgbWV0cmljcyByZW5kZXIgYXMgZnVsbCBncmFwaCBjYXJkcyBvbiB0aGUgcmlnaHQuPC9wPjwvZGl2PgogICA8ZGl2IGNsYXNzPSJzbWFsbG1ldGEiIGlkPSJzZWxlY3RlZENvdW50Ij7igJQ8L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0iaGFyZHdhcmVMYXlvdXQiPgogICA8YXNpZGUgY2xhc3M9ImNvcmVQYW5lbCI+CiAgICA8ZGl2IGNsYXNzPSJjb3JlSGVhZCI+PHN0cm9uZz5Db3JlIGJvdHRsZW5lY2sgbWV0cmljczwvc3Ryb25nPjxzcGFuPlRoZXNlIHN0YXkgaW4gdGhlIGRlZmF1bHQgbGlzdCBldmVuIHdoZW4gdGhleSBhcmUgc3dpdGNoZWQgb2ZmLjwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNvcmVMaXN0IiBpZD0iY29yZUxpc3QiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iY29yZUZvb3QiPjxidXR0b24gY2xhc3M9ImJ0biBwcmltYXJ5IiBpZD0iYWRkTW9yZSI+KyBBZGQgbW9yZSBtZXRyaWNzPC9idXR0b24+PC9kaXY+CiAgIDwvYXNpZGU+CiAgIDxkaXYgY2xhc3M9InBpbmdyaWQiIGlkPSJwaW5HcmlkIj48L2Rpdj4KICA8L2Rpdj4KIDwvZGl2Pgo8L21haW4+Cgo8ZGl2IGNsYXNzPSJtb2RhbGJhY2siIGlkPSJleHRyYU1vZGFsIj4KIDxkaXYgY2xhc3M9Im1vZGFsIj4KICA8ZGl2IGNsYXNzPSJtb2RhbGhlYWQiPjxkaXY+PHN0cm9uZz5BZGQgbW9yZSBtZXRyaWNzPC9zdHJvbmc+PHNwYW4+QWxsIGFkZGl0aW9uYWwgYXZhaWxhYmxlIG1ldHJpY3MsIGdyb3VwZWQgYnkgdHlwZS48L3NwYW4+PC9kaXY+PGJ1dHRvbiBjbGFzcz0iYnRuIiBpZD0iY2xvc2VNb2RhbCI+Q2xvc2U8L2J1dHRvbj48L2Rpdj4KICA8ZGl2IGNsYXNzPSJtb2RhbHNlYXJjaCI+PGlucHV0IHR5cGU9InNlYXJjaCIgaWQ9Im1ldHJpY1NlYXJjaCIgcGxhY2Vob2xkZXI9IlNlYXJjaCBtZXRyaWNz4oCmIj48L2Rpdj4KICA8ZGl2IGNsYXNzPSJncm91cGVkTGlzdCIgaWQ9Imdyb3VwZWRMaXN0Ij48L2Rpdj4KICA8ZGl2IGNsYXNzPSJtb2RhbGZvb3QiPjxidXR0b24gY2xhc3M9ImJ0biIgaWQ9ImNsb3NlTW9kYWxCb3R0b20iPkRvbmU8L2J1dHRvbj48L2Rpdj4KIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQ+CmNvbnN0ICQ9aWQ9PmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKY29uc3QgQ09SRT1bCiB7aWQ6J2dwdV91dGlsJyxsYWJlbDonR1BVIFV0aWxpemF0aW9uJyxyZTovZ3B1LioodXRpbHxsb2FkKXxncHUgY29yZSBsb2FkL2ksZGVmOnRydWV9LAoge2lkOidjcHVfdG90YWwnLGxhYmVsOidUb3RhbCBDUFUgVXNhZ2UnLHJlOi8oY3B1IHRvdGFsfHRvdGFsIGNwdSkuKnVzYWdlfGNwdSB0b3RhbCB1c2FnZXx0b3RhbCBjcHUgbG9hZC9pLGRlZjp0cnVlfSwKIHtpZDonY3B1X21heCcsbGFiZWw6J01heCBDUFUvVGhyZWFkIFVzYWdlJyxyZTovKG1heC4qdGhyZWFkfG1heC4qY29yZSkuKnVzYWdlfG1heGltdW0gY3B1IHRocmVhZC9pLGRlZjp0cnVlfSwKIHtpZDonZ3B1X3Bvd2VyJyxsYWJlbDonR1BVIFBvd2VyJyxyZTovZ3B1Lipwb3dlcnx0b3RhbCBib2FyZCBwb3dlcnxhc2ljIHBvd2VyfHZkZGNyX2dmeC9pLGRlZjp0cnVlfSwKIHtpZDonY3B1X3Bvd2VyJyxsYWJlbDonQ1BVIFBhY2thZ2UgUG93ZXInLHJlOi9jcHUgcGFja2FnZSBwb3dlcnxwYWNrYWdlIHBvd2VyfGNwdS4qcG93ZXIvaSxkZWY6ZmFsc2V9LAoge2lkOidjcHVfcHB0JyxsYWJlbDonQ1BVIFBQVCBMaW1pdCcscmU6L2NwdSBwcHR8cHB0LipsaW1pdC9pLGRlZjp0cnVlfSwKIHtpZDonZ3B1X3RlbXAnLGxhYmVsOidHUFUgVGVtcGVyYXR1cmUnLHJlOi9ncHUuKnRlbXBlcmF0dXJlfGdwdS4qdGVtcC9pLGRlZjpmYWxzZX0sCiB7aWQ6J2NwdV90ZW1wJyxsYWJlbDonQ1BVIFRlbXBlcmF0dXJlJyxyZTovY3B1Lip0ZW1wZXJhdHVyZXxjcHUgdGN0bHxwYWNrYWdlLip0ZW1wL2ksZGVmOmZhbHNlfSwKIHtpZDondnJhbScsbGFiZWw6J1ZSQU0gVXNhZ2UnLHJlOi92cmFtfGdwdSBtZW1vcnkgdXNlZHxkZWRpY2F0ZWQuKm1lbW9yeS9pLGRlZjp0cnVlfSwKIHtpZDoncmFtJyxsYWJlbDonUkFNIFVzYWdlJyxyZTovcGh5c2ljYWwgbWVtb3J5IGxvYWR8cmFtIHVzYWdlfG1lbW9yeSBsb2FkL2ksZGVmOmZhbHNlfQpdOwoKY29uc3QgUz17CiByZWNvcmRzOltdLGRhdGE6bnVsbCxsaXZlSHc6W10sY29yZUVuYWJsZWQ6bmV3IFNldCgpLGV4dHJhTmFtZXM6bmV3IFNldCgpLAogcmFuZ2VBY3RpdmU6ZmFsc2Usc3RhcnQ6MCxlbmQ6MCxob3ZlclQ6bnVsbCxkcmFnOmZhbHNlLGRyYWdTdGFydFQ6MCwKIGZpbHRlcjonJyxsb2FkSWQ6MCxmcmFtZVBsb3Q6bnVsbCxpbml0aWFsaXplZFByZWZzOmZhbHNlLAogY2F0YWxvZ0NhY2hlOm51bGwsY29yZUNhY2hlOm5ldyBNYXAoKSxzZWxlY3RlZENhY2hlOm51bGwsZnJhbWVDYWNoZTpudWxsLAogcmFuZ2VQb2ludENhY2hlOm5ldyBNYXAoKSxob3ZlclJhZjowLG1vZGFsU2VhcmNoVGltZXI6MAp9OwoKY29uc3QgZm10PSh2LGQ9MSk9PnYhPT1udWxsJiZ2IT09dW5kZWZpbmVkJiZOdW1iZXIuaXNGaW5pdGUoTnVtYmVyKHYpKT9OdW1iZXIodikudG9Mb2NhbGVTdHJpbmcodW5kZWZpbmVkLHttaW5pbXVtRnJhY3Rpb25EaWdpdHM6ZCxtYXhpbXVtRnJhY3Rpb25EaWdpdHM6ZH0pOifigJQnOwpjb25zdCBjbGFtcD0odixhLGIpPT5NYXRoLm1heChhLE1hdGgubWluKGIsdikpOwpjb25zdCBtZWFuPWE9PmEubGVuZ3RoP2EucmVkdWNlKChzLHgpPT5zK3gsMCkvYS5sZW5ndGg6bnVsbDsKY29uc3QgcXVhbnQ9KGFycixxKT0+e2lmKCFhcnIubGVuZ3RoKXJldHVybiBudWxsO2NvbnN0IGE9Wy4uLmFycl0uc29ydCgoeCx5KT0+eC15KSxwPShhLmxlbmd0aC0xKSpxLGk9TWF0aC5mbG9vcihwKSxmPXAtaTtyZXR1cm4gYVtpKzFdIT09dW5kZWZpbmVkP2FbaV0rZiooYVtpKzFdLWFbaV0pOmFbaV19Owpjb25zdCBtZWRpYW49YT0+cXVhbnQoYSwuNSk7CmNvbnN0IG5vcm09cz0+U3RyaW5nKHN8fCcnKS50b0xvd2VyQ2FzZSgpLnJlcGxhY2UoL1teYS16MC05JV0rL2csJyAnKS5yZXBsYWNlKC9ccysvZywnICcpLnRyaW0oKTsKY29uc3QgZXNjPXM9PlN0cmluZyhzPz8nJykucmVwbGFjZSgvWyY8PiInXS9nLGM9Pih7JyYnOicmYW1wOycsJzwnOicmbHQ7JywnPic6JyZndDsnLCciJzonJnF1b3Q7JywiJyI6JyYjMzk7J31bY10pKTsKCmZ1bmN0aW9uIHVuaXRGb3IodHlwZSxuYW1lLHVuaXQ9JycpewogaWYodW5pdClyZXR1cm4gdW5pdDsKIGNvbnN0IHQ9bm9ybSh0eXBlKSxuPW5vcm0obmFtZSk7CiBpZih0LmluY2x1ZGVzKCd0ZW1wZXJhdHVyZScpfHxuLmluY2x1ZGVzKCd0ZW1wZXJhdHVyZScpfHxuLmluY2x1ZGVzKCdob3Qgc3BvdCcpKXJldHVybiAnwrBDJzsKIGlmKHQuaW5jbHVkZXMoJ3Bvd2VyJyl8fG4uaW5jbHVkZXMoJ3Bvd2VyJykpcmV0dXJuICdXJzsKIGlmKHQuaW5jbHVkZXMoJ2xvYWQnKXx8dC5pbmNsdWRlcygndXNhZ2UnKXx8bi5pbmNsdWRlcygndXRpbGl6YXRpb24nKXx8bi5pbmNsdWRlcygndXNhZ2UnKXx8bi5pbmNsdWRlcygnbG9hZCcpfHxuLmluY2x1ZGVzKCdsaW1pdCcpKXJldHVybiAnJSc7CiBpZih0LmluY2x1ZGVzKCdjbG9jaycpfHxuLmluY2x1ZGVzKCdjbG9jaycpKXJldHVybiAnTUh6JzsKIGlmKHQuaW5jbHVkZXMoJ3ZvbHRhZ2UnKXx8bi5pbmNsdWRlcygndm9sdGFnZScpKXJldHVybiAnVic7CiBpZih0LmluY2x1ZGVzKCdmYW4nKXx8bi5pbmNsdWRlcygnZmFuJykpcmV0dXJuICdSUE0nOwogaWYobi5pbmNsdWRlcygnbWVtb3J5IHVzZWQnKXx8bi5pbmNsdWRlcygndnJhbSB1c2VkJykpcmV0dXJuICdNQic7CiByZXR1cm4gJyc7Cn0KCmZ1bmN0aW9uIGxvYWRQcmVmcygpewogaWYoUy5pbml0aWFsaXplZFByZWZzKXJldHVybjsKIFMuaW5pdGlhbGl6ZWRQcmVmcz10cnVlOwogbGV0IGNvcmU9bnVsbCxleHRyYT1udWxsOwogdHJ5e2NvcmU9SlNPTi5wYXJzZShsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnd3NzLXY4LXYyOS1jb3JlJyl8fCdudWxsJyl9Y2F0Y2h7fQogdHJ5e2V4dHJhPUpTT04ucGFyc2UobG9jYWxTdG9yYWdlLmdldEl0ZW0oJ3dzcy12OC12MjktZXh0cmEnKXx8J251bGwnKX1jYXRjaHt9CiBTLmNvcmVFbmFibGVkPW5ldyBTZXQoQXJyYXkuaXNBcnJheShjb3JlKT9jb3JlOkNPUkUuZmlsdGVyKHg9PnguZGVmKS5tYXAoeD0+eC5pZCkpOwogUy5leHRyYU5hbWVzPW5ldyBTZXQoQXJyYXkuaXNBcnJheShleHRyYSk/ZXh0cmE6W10pOwp9CmZ1bmN0aW9uIHNhdmVQcmVmcygpewogbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ3dzcy12OC12MjktY29yZScsSlNPTi5zdHJpbmdpZnkoWy4uLlMuY29yZUVuYWJsZWRdKSk7CiBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnd3NzLXY4LXYyOS1leHRyYScsSlNPTi5zdHJpbmdpZnkoWy4uLlMuZXh0cmFOYW1lc10pKTsKfQpmdW5jdGlvbiBpbnZhbGlkYXRlQ2F0YWxvZygpewogUy5jYXRhbG9nQ2FjaGU9bnVsbDtTLmNvcmVDYWNoZS5jbGVhcigpO1Muc2VsZWN0ZWRDYWNoZT1udWxsO1MucmFuZ2VQb2ludENhY2hlLmNsZWFyKCk7Cn0KZnVuY3Rpb24gaW52YWxpZGF0ZVNlbGVjdGlvbigpewogUy5zZWxlY3RlZENhY2hlPW51bGw7Uy5yYW5nZVBvaW50Q2FjaGUuY2xlYXIoKTsKfQpmdW5jdGlvbiBpbnZhbGlkYXRlUmFuZ2UoKXsKIFMucmFuZ2VQb2ludENhY2hlLmNsZWFyKCk7Cn0KCmFzeW5jIGZ1bmN0aW9uIGxvYWRMaXZlSHcoKXsKIHRyeXsKICBjb25zdCByPWF3YWl0IGZldGNoKCcvYXBpL3NlbnNvcnM/Xz0nK0RhdGUubm93KCkse2NhY2hlOiduby1zdG9yZSd9KSxkPWF3YWl0IHIuanNvbigpOwogIFMubGl2ZUh3PShkPy5Paz9kLlJlYWRpbmdzOltdKXx8W107aW52YWxpZGF0ZUNhdGFsb2coKTsKIH1jYXRjaHtTLmxpdmVIdz1bXTtpbnZhbGlkYXRlQ2F0YWxvZygpfQp9Cgphc3luYyBmdW5jdGlvbiBsb2FkUmVjb3JkcygpewogdHJ5ewogIGxvYWRQcmVmcygpO2F3YWl0IGxvYWRMaXZlSHcoKTsKICBjb25zdCByPWF3YWl0IGZldGNoKCcvYXBpL2NhcHR1cmUvcmVjb3Jkcz9fPScrRGF0ZS5ub3coKSx7Y2FjaGU6J25vLXN0b3JlJ30pOwogIGNvbnN0IHRleHQ9YXdhaXQgci50ZXh0KCk7bGV0IGQ7dHJ5e2Q9SlNPTi5wYXJzZSh0ZXh0KX1jYXRjaHt0aHJvdyBuZXcgRXJyb3IoYENhcHR1cmUgQVBJIHJldHVybmVkICR7dGV4dC5zbGljZSgwLDcwKX1gKX0KICBpZighZC5BdmFpbGFibGUpdGhyb3cgbmV3IEVycm9yKGQuTWVzc2FnZXx8J0NhcEZyYW1lWCB1bmF2YWlsYWJsZScpOwogIFMucmVjb3Jkcz1kLlJlY29yZHN8fFtdOwogICQoJ2FwaURvdCcpLmNsYXNzTmFtZT0nZG90IGdvb2QnOyQoJ2FwaVN0YXRlJykudGV4dENvbnRlbnQ9J0NhcEZyYW1lWCBjb25uZWN0ZWQnOwogICQoJ2NhcHR1cmVTZWxlY3QnKS5pbm5lckhUTUw9JzxvcHRpb24gdmFsdWU9IiI+4oCUIFNlbGVjdCBjYXB0dXJlIOKAlDwvb3B0aW9uPic7CiAgZm9yKGNvbnN0IHJlYyBvZiBTLnJlY29yZHMpewogICBjb25zdCBvPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ29wdGlvbicpO28udmFsdWU9cmVjLlRva2VuOwogICBjb25zdCBkdD1yZWMuUmVjb3JkZWRBdD9uZXcgRGF0ZShyZWMuUmVjb3JkZWRBdCkudG9Mb2NhbGVTdHJpbmcoKTondW5rbm93biBkYXRlJzsKICAgby50ZXh0Q29udGVudD1gJHtyZWMuR2FtZXx8cmVjLlByb2Nlc3NOYW1lfHwnQ2FwdHVyZSd9IMK3ICR7ZHR9IMK3ICR7Zm10KHJlYy5EdXJhdGlvblNlYywxKX0gc2A7CiAgICQoJ2NhcHR1cmVTZWxlY3QnKS5hcHBlbmRDaGlsZChvKTsKICB9CiAgJCgnY2FwdHVyZUluZm8nKS50ZXh0Q29udGVudD1TLnJlY29yZHMubGVuZ3RoP2Ake1MucmVjb3Jkcy5sZW5ndGh9IGNhcHR1cmVzIGF2YWlsYWJsZS5gOidObyBjYXB0dXJlcyBmb3VuZC4nOwogfWNhdGNoKGUpewogICQoJ2FwaURvdCcpLmNsYXNzTmFtZT0nZG90IGJhZCc7JCgnYXBpU3RhdGUnKS50ZXh0Q29udGVudD1lLm1lc3NhZ2U7JCgnY2FwdHVyZVNlbGVjdCcpLmlubmVySFRNTD0nPG9wdGlvbiB2YWx1ZT0iIj5VbmF2YWlsYWJsZTwvb3B0aW9uPic7CiB9Cn0KCmZ1bmN0aW9uIGNsZWFyRm9yTG9hZCgpewogUy5kYXRhPW51bGw7Uy5ob3ZlclQ9bnVsbDtTLnJhbmdlQWN0aXZlPWZhbHNlOyQoJ2NvbnRlbnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzskKCdwbGFjZWhvbGRlcicpLnN0eWxlLmRpc3BsYXk9J25vbmUnOyQoJ2xvYWRlcicpLnN0eWxlLmRpc3BsYXk9J2dyaWQnOwp9Cgphc3luYyBmdW5jdGlvbiBjaG9vc2VDYXB0dXJlKHRva2VuKXsKIGNvbnN0IGlkPSsrUy5sb2FkSWQ7CiBpZighdG9rZW4pewogIFMuZGF0YT1udWxsOyQoJ2xvYWRlcicpLnN0eWxlLmRpc3BsYXk9J25vbmUnOyQoJ2NvbnRlbnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzskKCdwbGFjZWhvbGRlcicpLnN0eWxlLmRpc3BsYXk9J2Jsb2NrJzsKICAkKCdjYXB0dXJlSW5mbycpLnRleHRDb250ZW50PWAke1MucmVjb3Jkcy5sZW5ndGh9IGNhcHR1cmVzIGF2YWlsYWJsZS5gO3JldHVybjsKIH0KIGNsZWFyRm9yTG9hZCgpOyQoJ2NhcHR1cmVJbmZvJykudGV4dENvbnRlbnQ9J0xvYWRpbmcgc2VsZWN0ZWQgY2FwdHVyZeKApic7CiB0cnl7CiAgY29uc3Qgcj1hd2FpdCBmZXRjaCgnL2FwaS9jYXB0dXJlL3JlY29yZD90b2tlbj0nK2VuY29kZVVSSUNvbXBvbmVudCh0b2tlbikrJyZfPScrRGF0ZS5ub3coKSx7Y2FjaGU6J25vLXN0b3JlJ30pOwogIGNvbnN0IHRleHQ9YXdhaXQgci50ZXh0KCk7bGV0IGQ7dHJ5e2Q9SlNPTi5wYXJzZSh0ZXh0KX1jYXRjaHt0aHJvdyBuZXcgRXJyb3IoYENhcHR1cmUgQVBJIHJldHVybmVkICR7dGV4dC5zbGljZSgwLDcwKX1gKX0KICBpZihpZCE9PVMubG9hZElkKXJldHVybjsKICBpZighZC5BdmFpbGFibGUpdGhyb3cgbmV3IEVycm9yKGQuTWVzc2FnZXx8J0NhcHR1cmUgY291bGQgbm90IGJlIGxvYWRlZCcpOwogIFMuZGF0YT1kO1Muc3RhcnQ9MDtTLmVuZD1OdW1iZXIoZC5EdXJhdGlvblNlYyl8fDA7Uy5ob3ZlclQ9bnVsbDtTLnJhbmdlQWN0aXZlPWZhbHNlOwogIFMuZnJhbWVDYWNoZT1udWxsO2ludmFsaWRhdGVDYXRhbG9nKCk7CiAgJCgnbG9hZGVyJykuc3R5bGUuZGlzcGxheT0nbm9uZSc7JCgnY29udGVudCcpLnN0eWxlLmRpc3BsYXk9J2Jsb2NrJzsKICBwb3B1bGF0ZUNhcHR1cmUoKTtyZW5kZXJBbGwoKTsKIH1jYXRjaChlKXsKICBpZihpZCE9PVMubG9hZElkKXJldHVybjsKICAkKCdsb2FkZXInKS5zdHlsZS5kaXNwbGF5PSdub25lJzskKCdwbGFjZWhvbGRlcicpLnN0eWxlLmRpc3BsYXk9J2Jsb2NrJzskKCdwbGFjZWhvbGRlcicpLnRleHRDb250ZW50PSdGYWlsZWQgdG8gbG9hZCBjYXB0dXJlOiAnK2UubWVzc2FnZTskKCdjYXB0dXJlSW5mbycpLnRleHRDb250ZW50PSdMb2FkIGZhaWxlZC4nOwogfQp9CgpmdW5jdGlvbiBwb3B1bGF0ZUNhcHR1cmUoKXsKIGNvbnN0IGQ9Uy5kYXRhLG09ZC5NZXRyaWNzfHx7fTsKICQoJ2tBdmcnKS50ZXh0Q29udGVudD1mbXQobS5BdmVyYWdlLDEpKycgRlBTJzskKCdrTG93MScpLnRleHRDb250ZW50PWZtdChtLk9uZVBlcmNlbnRMb3dBdmVyYWdlLDEpKycgRlBTJzskKCdrTG93MDInKS50ZXh0Q29udGVudD1mbXQobS5aZXJvZG90VHdvUGVyY2VudExvd0F2ZXJhZ2UsMSkrJyBGUFMnOyQoJ2tQMScpLnRleHRDb250ZW50PWZtdChtLlAxLDEpKycgRlBTJzskKCdrUDAyJykudGV4dENvbnRlbnQ9Zm10KG0uUDBkb3QyLDEpKycgRlBTJzsKICQoJ2NhcEdhbWUnKS50ZXh0Q29udGVudD1kLkdhbWV8fCfigJQnOyQoJ2NhcFByb2Nlc3MnKS50ZXh0Q29udGVudD1kLlByb2Nlc3NOYW1lfHwn4oCUJzskKCdjYXBEdXJhdGlvbicpLnRleHRDb250ZW50PWZtdChkLkR1cmF0aW9uU2VjLDEpKycgcyc7JCgnY2FwRnJhbWVzJykudGV4dENvbnRlbnQ9TnVtYmVyKGQuRnJhbWVDb3VudHx8MCkudG9Mb2NhbGVTdHJpbmcoKTskKCdjYXBTb3VyY2UnKS50ZXh0Q29udGVudD1kLk1ldHJpY1NvdXJjZXx8J+KAlCc7JCgnY2FwU2Vuc29ycycpLnRleHRDb250ZW50PShkLlNlbnNvcnN8fFtdKS5sZW5ndGgudG9Mb2NhbGVTdHJpbmcoKTsKICQoJ2NhcERhdGUnKS50ZXh0Q29udGVudD1kLlJlY29yZGVkQXQ/bmV3IERhdGUoZC5SZWNvcmRlZEF0KS50b0xvY2FsZVN0cmluZygpOifigJQnOyQoJ2ZyYW1lTWV0YScpLnRleHRDb250ZW50PWAke051bWJlcihkLkZyYW1lQ291bnR8fDApLnRvTG9jYWxlU3RyaW5nKCl9IGZyYW1lcyDCtyAke2QuTWV0cmljU291cmNlfHwnZnJhbWV0aW1lJ31gOwogJCgncmFuZ2VTdGFydCcpLm1heD1TLmVuZDskKCdyYW5nZUVuZCcpLm1heD1TLmVuZDskKCdyYW5nZVN0YXJ0JykudmFsdWU9Jyc7JCgncmFuZ2VFbmQnKS52YWx1ZT0nJzsKIGNvbnN0IHdhcm5pbmc9U3RyaW5nKGQuTWV0cmljU291cmNlV2FybmluZ3x8JycpLnJlcGxhY2VBbGwoJ8OD4oCUJywnw5cnKS5yZXBsYWNlQWxsKCfDouKCrOKAnScsJ+KAlCcpLnJlcGxhY2VBbGwoJ8Oi4oKs4oCcJywn4oCTJyk7CiAkKCd3YXJuaW5nVGV4dCcpLnRleHRDb250ZW50PXdhcm5pbmc7JCgnc291cmNlV2FybmluZycpLnN0eWxlLmRpc3BsYXk9d2FybmluZz8nYmxvY2snOidub25lJzskKCdjYXB0dXJlSW5mbycpLnRleHRDb250ZW50PWAke2QuR2FtZXx8ZC5Qcm9jZXNzTmFtZXx8J0NhcHR1cmUnfSDCtyAke2ZtdChkLkR1cmF0aW9uU2VjLDEpfSBzYDsKfQoKZnVuY3Rpb24gY2FwdHVyZVNlbnNvcnMoKXtyZXR1cm4gUy5kYXRhPy5TZW5zb3JzfHxbXX0KZnVuY3Rpb24gc2VyaWVzSWQocyl7cmV0dXJuICdjYXA6Jytub3JtKChzLklkZW50aWZpZXJ8fHMuTmFtZXx8JycpKyd8Jysocy5UeXBlfHwnJykpfQpmdW5jdGlvbiB3b3JkcyhzKXtyZXR1cm4gbmV3IFNldChub3JtKHMpLnNwbGl0KCcgJykuZmlsdGVyKHg9PngubGVuZ3RoPjImJiFbJ2NwdScsJ2dwdScsJ2FtZCcsJ2ludGVsJywnbnZpZGlhJywnc2Vuc29yJywndXNhZ2UnLCdjb3JlJ10uaW5jbHVkZXMoeCkpKX0KZnVuY3Rpb24gb3ZlcmxhcFNjb3JlKGEsYil7Y29uc3QgQT13b3JkcyhhKSxCPXdvcmRzKGIpO2lmKCFBLnNpemV8fCFCLnNpemUpcmV0dXJuIDA7bGV0IGhpdD0wO2Zvcihjb25zdCB4IG9mIEEpaWYoQi5oYXMoeCkpaGl0Kys7cmV0dXJuIGhpdC9NYXRoLm1heChBLnNpemUsQi5zaXplKX0KCmZ1bmN0aW9uIHNlbWFudGljU2NvcmUobGFiZWwscyl7CiBjb25zdCBhPW5vcm0obGFiZWwpLGI9bm9ybShzLk5hbWV8fHMuSWRlbnRpZmllcnx8JycpOwogY29uc3QgcGFpcnM9WwogIFsvZ3B1IHV0aWxpemF0aW9ufGdwdSBjb3JlIGxvYWR8Z3B1IGxvYWQvLC9ncHUuKih1dGlsfGxvYWQpfGNvcmUgbG9hZC9dLAogIFsvdG90YWwgY3B1IHVzYWdlfGNwdSB0b3RhbCB1c2FnZXx0b3RhbCBjcHUgbG9hZHxjcHUgdXNhZ2UvLC8odG90YWwuKmNwdXxjcHUuKnRvdGFsfGNwdSB1c2FnZXxjcHUgbG9hZCkvXSwKICBbL21heCBjcHUgdGhyZWFkIHVzYWdlfG1heCBjcHUgY29yZSB1c2FnZXxtYXggdGhyZWFkIHVzYWdlLywvKG1heC4qdGhyZWFkfG1heC4qY29yZSkuKnVzYWdlfG1heGltdW0uKnRocmVhZC9dLAogIFsvY3B1IHBwdCBsaW1pdHxwcHQgbGltaXR8Y3B1IHBwdC8sLyhwcHQuKmxpbWl0fGNwdSBwcHR8cHB0KS9dLAogIFsvY3B1IHRkYyBsaW1pdHx0ZGMgbGltaXR8Y3B1IHRkYy8sLyh0ZGMuKmxpbWl0fGNwdSB0ZGN8dGRjKS9dLAogIFsvY3B1IGVkYyBsaW1pdHxlZGMgbGltaXR8Y3B1IGVkYy8sLyhlZGMuKmxpbWl0fGNwdSBlZGN8ZWRjKS9dLAogIFsvZ3B1IHRlbXBlcmF0dXJlfGdwdSB0ZW1wLywvZ3B1Lip0ZW1wL10sCiAgWy9jcHUgdGVtcGVyYXR1cmV8Y3B1IHBhY2thZ2UgdGVtcGVyYXR1cmV8Y3B1IHRjdGwvLC8oY3B1Lip0ZW1wfHRjdGx8cGFja2FnZS4qdGVtcCkvXSwKICBbL2dwdSBwb3dlcnx0b3RhbCBib2FyZCBwb3dlcnxncHUgYXNpYyBwb3dlcnx2ZGRjciBnZngvLC8oZ3B1Lipwb3dlcnxib2FyZCBwb3dlcnxhc2ljIHBvd2VyfHZkZGNyIGdmeHx2ZGRjcl9nZngpL10sCiAgWy9jcHUgcGFja2FnZSBwb3dlcnxjcHUgcG93ZXIvLC8oY3B1Lipwb3dlcnxwYWNrYWdlIHBvd2VyKS9dLAogIFsvZ3B1IGNsb2NrLywvZ3B1LipjbG9jay9dLAogIFsvZWZmZWN0aXZlIGNsb2NrfGNwdSBlZmZlY3RpdmUgY2xvY2svLC8oZWZmZWN0aXZlLipjbG9ja3xjcHUuKmNsb2NrKS9dLAogIFsvdnJhbXxncHUgbWVtb3J5LywvKHZyYW18Z3B1IG1lbW9yeXxkZWRpY2F0ZWQgbWVtb3J5KS9dLAogIFsvcmFtIHVzYWdlfHBoeXNpY2FsIG1lbW9yeS8sLyhwaHlzaWNhbCBtZW1vcnl8cmFtfG1lbW9yeSBsb2FkKS9dCiBdOwogZm9yKGNvbnN0IFtyYSxyYl0gb2YgcGFpcnMpaWYocmEudGVzdChhKSYmcmIudGVzdChiKSlyZXR1cm4gOTU7CiBpZihhPT09YilyZXR1cm4gMTAwOwogaWYoYS5pbmNsdWRlcyhiKXx8Yi5pbmNsdWRlcyhhKSlyZXR1cm4gODI7CiByZXR1cm4gb3ZlcmxhcFNjb3JlKGEsYikqNzA7Cn0KCmZ1bmN0aW9uIGNhdGFsb2coKXsKIGlmKFMuY2F0YWxvZ0NhY2hlKXJldHVybiBTLmNhdGFsb2dDYWNoZTsKIGNvbnN0IG1hcD1uZXcgTWFwKCksY2Fwcz1jYXB0dXJlU2Vuc29ycygpOwogZm9yKGNvbnN0IHMgb2YgY2Fwcyl7CiAgY29uc3Qga2V5PXNlcmllc0lkKHMpOwogIG1hcC5zZXQoa2V5LHtLZXk6a2V5LE5hbWU6cy5OYW1lfHxzLklkZW50aWZpZXJ8fCdTZW5zb3InLE9yaWdpbmFsTmFtZTpzLk5hbWV8fHMuSWRlbnRpZmllcnx8JycsVHlwZTpzLlR5cGV8fCdSZWNvcmRlZCBzZW5zb3InLFVuaXQ6dW5pdEZvcihzLlR5cGUscy5OYW1lKSxTZXJpZXM6cyxSZWNvcmRlZDp0cnVlLE1hdGNoTm90ZTpudWxsfSk7CiB9CiBmb3IoY29uc3QgciBvZiBTLmxpdmVIdyl7CiAgY29uc3QgbGFiZWw9KHIuTGFiZWx8fHIuTGFiZWxPcmlnaW5hbHx8JycpLnRyaW0oKTtpZighbGFiZWwpY29udGludWU7CiAgbGV0IGJlc3Q9bnVsbCxiZXN0U2NvcmU9MDsKICBmb3IoY29uc3QgcyBvZiBjYXBzKXtjb25zdCBzY29yZT1zZW1hbnRpY1Njb3JlKGxhYmVsLHMpO2lmKHNjb3JlPmJlc3RTY29yZSl7YmVzdFNjb3JlPXNjb3JlO2Jlc3Q9c319CiAgaWYoYmVzdCYmYmVzdFNjb3JlPj03Mil7CiAgIGNvbnN0IGtleT1zZXJpZXNJZChiZXN0KSx4PW1hcC5nZXQoa2V5KTsKICAgaWYoeCl7eC5OYW1lPWxhYmVsO3guVHlwZT1yLlNlbnNvcnx8eC5UeXBlO3guVW5pdD1yLlVuaXR8fHguVW5pdDt4Lk1hdGNoTm90ZT1ub3JtKHguT3JpZ2luYWxOYW1lKSE9PW5vcm0obGFiZWwpP2ByZWNvcmRlZCBhcyAke3guT3JpZ2luYWxOYW1lfWA6bnVsbH0KICAgY29udGludWU7CiAgfQogIGNvbnN0IGtleT0naHc6Jytub3JtKGxhYmVsKyd8Jysoci5Vbml0fHwnJykpOwogIGlmKCFtYXAuaGFzKGtleSkpbWFwLnNldChrZXkse0tleTprZXksTmFtZTpsYWJlbCxPcmlnaW5hbE5hbWU6bGFiZWwsVHlwZTpyLlNlbnNvcnx8J0hXaU5GTycsVW5pdDpyLlVuaXR8fCcnLFNlcmllczpudWxsLFJlY29yZGVkOmZhbHNlLE1hdGNoTm90ZTpudWxsfSk7CiB9CiBTLmNhdGFsb2dDYWNoZT1bLi4ubWFwLnZhbHVlcygpXTsKIHJldHVybiBTLmNhdGFsb2dDYWNoZTsKfQoKZnVuY3Rpb24gcmVzb2x2ZUNvcmUoZGVmKXsKIGlmKFMuY29yZUNhY2hlLmhhcyhkZWYuaWQpKXJldHVybiBTLmNvcmVDYWNoZS5nZXQoZGVmLmlkKTsKIGNvbnN0IGl0ZW1zPWNhdGFsb2coKTtsZXQgYmVzdD1udWxsLGJlc3RTY29yZT0tMTsKIGZvcihjb25zdCB4IG9mIGl0ZW1zKXsKICBjb25zdCBoYXk9YCR7eC5OYW1lfSAke3guT3JpZ2luYWxOYW1lfSAke3guVHlwZX1gOwogIGxldCBzY29yZT1kZWYucmUudGVzdChoYXkpPzgwOjA7aWYoc2NvcmUmJnguUmVjb3JkZWQpc2NvcmUrPTIwOwogIGlmKHNjb3JlPmJlc3RTY29yZSl7YmVzdD14O2Jlc3RTY29yZT1zY29yZX0KIH0KIGNvbnN0IHJlc3VsdD1iZXN0U2NvcmU+MD9iZXN0Om51bGw7Uy5jb3JlQ2FjaGUuc2V0KGRlZi5pZCxyZXN1bHQpO3JldHVybiByZXN1bHQ7Cn0KCmZ1bmN0aW9uIHNlbGVjdGVkSXRlbXMoKXsKIGlmKFMuc2VsZWN0ZWRDYWNoZSlyZXR1cm4gUy5zZWxlY3RlZENhY2hlOwogY29uc3Qgb3V0PVtdLHNlZW49bmV3IFNldCgpLGNhdD1jYXRhbG9nKCk7CiBmb3IoY29uc3QgZGVmIG9mIENPUkUpewogIGlmKCFTLmNvcmVFbmFibGVkLmhhcyhkZWYuaWQpKWNvbnRpbnVlOwogIGNvbnN0IHg9cmVzb2x2ZUNvcmUoZGVmKTtpZih4JiYhc2Vlbi5oYXMoeC5LZXkpKXtvdXQucHVzaCh4KTtzZWVuLmFkZCh4LktleSl9CiB9CiBmb3IoY29uc3QgbmFtZSBvZiBTLmV4dHJhTmFtZXMpewogIGNvbnN0IHg9Y2F0LmZpbmQodj0+bm9ybSh2Lk5hbWUpPT09bmFtZXx8bm9ybSh2Lk9yaWdpbmFsTmFtZSk9PT1uYW1lKTsKICBpZih4JiYhc2Vlbi5oYXMoeC5LZXkpKXtvdXQucHVzaCh4KTtzZWVuLmFkZCh4LktleSl9CiB9CiBTLnNlbGVjdGVkQ2FjaGU9b3V0O3JldHVybiBvdXQ7Cn0KCmZ1bmN0aW9uIHBvaW50cyh4KXtyZXR1cm4geD8uU2VyaWVzPy5Qb2ludHN8fFtdfQpmdW5jdGlvbiBhY3RpdmVTdGFydCgpe3JldHVybiBTLnJhbmdlQWN0aXZlP1Muc3RhcnQ6MH0KZnVuY3Rpb24gYWN0aXZlRW5kKCl7cmV0dXJuIFMucmFuZ2VBY3RpdmU/Uy5lbmQ6KE51bWJlcihTLmRhdGE/LkR1cmF0aW9uU2VjKXx8MCl9CmZ1bmN0aW9uIHJhbmdlUG9pbnRzKHgpewogY29uc3Qga2V5PWAke3g/LktleXx8Jyd9fCR7YWN0aXZlU3RhcnQoKS50b0ZpeGVkKDMpfXwke2FjdGl2ZUVuZCgpLnRvRml4ZWQoMyl9YDsKIGlmKFMucmFuZ2VQb2ludENhY2hlLmhhcyhrZXkpKXJldHVybiBTLnJhbmdlUG9pbnRDYWNoZS5nZXQoa2V5KTsKIGNvbnN0IGE9YWN0aXZlU3RhcnQoKSxiPWFjdGl2ZUVuZCgpLG91dD1wb2ludHMoeCkuZmlsdGVyKHA9Pk51bWJlcihwLlRTZWMpPj1hJiZOdW1iZXIocC5UU2VjKTw9YiYmTnVtYmVyLmlzRmluaXRlKE51bWJlcihwLlZhbHVlKSkpLm1hcChwPT4oe3Q6TnVtYmVyKHAuVFNlYyksdjpOdW1iZXIocC5WYWx1ZSl9KSk7CiBTLnJhbmdlUG9pbnRDYWNoZS5zZXQoa2V5LG91dCk7cmV0dXJuIG91dDsKfQpmdW5jdGlvbiBuZWFyZXN0KGFycix0LGdldFQpe2lmKCFhcnIubGVuZ3RoKXJldHVybiBudWxsO2xldCBsbz0wLGhpPWFyci5sZW5ndGgtMTt3aGlsZShsbzxoaSl7Y29uc3QgbWlkPShsbytoaSk+PjE7aWYoZ2V0VChhcnJbbWlkXSk8dClsbz1taWQrMTtlbHNlIGhpPW1pZH1jb25zdCBhPWFycltsb10sYj1sbz4wP2Fycltsby0xXTphO3JldHVybiBNYXRoLmFicyhnZXRUKGEpLXQpPE1hdGguYWJzKGdldFQoYiktdCk/YTpifQpmdW5jdGlvbiBob3ZlclZhbHVlKHgpe2lmKCFOdW1iZXIuaXNGaW5pdGUoUy5ob3ZlclQpfHwheClyZXR1cm4gbnVsbDtjb25zdCBwPW5lYXJlc3QocG9pbnRzKHgpLFMuaG92ZXJULHo9Pk51bWJlcih6LlRTZWMpKTtyZXR1cm4gcCYmTnVtYmVyLmlzRmluaXRlKE51bWJlcihwLlZhbHVlKSk/TnVtYmVyKHAuVmFsdWUpOm51bGx9CgpmdW5jdGlvbiBmcmFtZVBvaW50cygpewogaWYoUy5mcmFtZUNhY2hlKXJldHVybiBTLmZyYW1lQ2FjaGU7CiBTLmZyYW1lQ2FjaGU9KFMuZGF0YT8uRnJhbWV0aW1lc3x8W10pLmZpbHRlcihwPT5OdW1iZXIocC5GcmFtZXRpbWVNcyk+MCkubWFwKHA9Pih7dDpOdW1iZXIocC5UU2VjKSxtczpOdW1iZXIocC5GcmFtZXRpbWVNcyl9KSk7CiByZXR1cm4gUy5mcmFtZUNhY2hlOwp9CmZ1bmN0aW9uIGFuYWx5c2lzRnJhbWVzKCl7Y29uc3QgYT1hY3RpdmVTdGFydCgpLGI9YWN0aXZlRW5kKCk7cmV0dXJuIGZyYW1lUG9pbnRzKCkuZmlsdGVyKHA9PnAudD49YSYmcC50PD1iKX0KCmZ1bmN0aW9uIHJlbmRlclJhbmdlKCl7CiBjb25zdCBmPWFuYWx5c2lzRnJhbWVzKCksbXM9Zi5tYXAoeD0+eC5tcyksYXZnRnQ9bWVhbihtcyksYXZnRnBzPWF2Z0Z0PzEwMDAvYXZnRnQ6bnVsbDsKIGNvbnN0IGR1cj1NYXRoLm1heCgwLGFjdGl2ZUVuZCgpLWFjdGl2ZVN0YXJ0KCkpOwogJCgna1NlbEF2ZycpLnRleHRDb250ZW50PWZtdChhdmdGcHMsMSkrJyBGUFMnOwogJCgna1NlbERlc2MnKS50ZXh0Q29udGVudD1TLnJhbmdlQWN0aXZlP2Ake2ZtdChkdXIsMSl9IHMgwrcgJHtmLmxlbmd0aC50b0xvY2FsZVN0cmluZygpfSBmcmFtZXNgOidmdWxsIGNhcHR1cmUnOwogJCgncmFuZ2VMYWJlbCcpLnRleHRDb250ZW50PVMucmFuZ2VBY3RpdmU/YCR7Uy5zdGFydC50b0ZpeGVkKDEpfeKAkyR7Uy5lbmQudG9GaXhlZCgxKX0gc2A6J05vIHJhbmdlIHNlbGVjdGVkJzsKICQoJ2NsZWFyUmFuZ2UnKS5kaXNhYmxlZD0hUy5yYW5nZUFjdGl2ZTsKICQoJ3JhbmdlSW5mbycpLnRleHRDb250ZW50PVMucmFuZ2VBY3RpdmUKICA/YFNlbGVjdGVkICR7Zm10KGR1ciwxKX0gcyDCtyBBdmcgRlQgJHtmbXQoYXZnRnQsMil9IG1zIMK3IFA5NSAke2ZtdChxdWFudChtcywuOTUpLDIpfSBtcyDCtyBQOTkgJHtmbXQocXVhbnQobXMsLjk5KSwyKX0gbXNgCiAgOidObyBzZWxlY3Rpb24gwrcgc3RhdGlzdGljcyB1c2UgZnVsbCBjYXB0dXJlJzsKfQoKZnVuY3Rpb24gY2FudmFzU2V0dXAoY2FudmFzKXsKIGNvbnN0IHI9Y2FudmFzLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpLGRwcj1NYXRoLm1heCgxLGRldmljZVBpeGVsUmF0aW98fDEpLHc9TWF0aC5tYXgoMSxNYXRoLmZsb29yKHIud2lkdGgqZHByKSksaD1NYXRoLm1heCgxLE1hdGguZmxvb3Ioci5oZWlnaHQqZHByKSk7CiBpZihjYW52YXMud2lkdGghPT13fHxjYW52YXMuaGVpZ2h0IT09aCl7Y2FudmFzLndpZHRoPXc7Y2FudmFzLmhlaWdodD1ofQogcmV0dXJue2N0eDpjYW52YXMuZ2V0Q29udGV4dCgnMmQnKSx3LGgsZHByfTsKfQpmdW5jdGlvbiBjb2xvcnMoKXtjb25zdCBjcz1nZXRDb21wdXRlZFN0eWxlKGRvY3VtZW50LmRvY3VtZW50RWxlbWVudCk7cmV0dXJue2dyaWQ6Y3MuZ2V0UHJvcGVydHlWYWx1ZSgnLS1jaGFydC1ncmlkJykudHJpbSgpLGxpbmU6Y3MuZ2V0UHJvcGVydHlWYWx1ZSgnLS1jaGFydC1saW5lJykudHJpbSgpLGhvdmVyOmNzLmdldFByb3BlcnR5VmFsdWUoJy0tY2hhcnQtaG92ZXInKS50cmltKCksdGV4dDpjcy5nZXRQcm9wZXJ0eVZhbHVlKCctLXRleHQnKS50cmltKCl9fQoKZnVuY3Rpb24gZHJhd0ZyYW1lKCl7CiBjb25zdCBjYW52YXM9JCgnZnJhbWVDaGFydCcpLHB0cz1mcmFtZVBvaW50cygpOwogaWYoIXB0cy5sZW5ndGgpeyQoJ2ZyYW1lRW1wdHknKS5zdHlsZS5kaXNwbGF5PSdncmlkJztyZXR1cm59CiAkKCdmcmFtZUVtcHR5Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiBjb25zdHtjdHgsdyxoLGRwcn09Y2FudmFzU2V0dXAoY2FudmFzKTtjdHguY2xlYXJSZWN0KDAsMCx3LGgpOwogY29uc3QgdmFscz1wdHMubWFwKHA9PnAubXMpLnNvcnQoKGEsYik9PmEtYikseW1heD1NYXRoLm1heCgxNi43LChxdWFudCh2YWxzLC45OTUpfHwxNi43KSoxLjI1KTsKIGNvbnN0IGR1cmF0aW9uPU51bWJlcihTLmRhdGEuRHVyYXRpb25TZWMpfHxwdHMuYXQoLTEpLnR8fDEsTD01KmRwcixSPXctNSpkcHIsVD01KmRwcixCPWgtMTUqZHByLGM9Y29sb3JzKCk7CgogY3R4LnN0cm9rZVN0eWxlPWMuZ3JpZDtjdHgubGluZVdpZHRoPWRwcjsKIGZvcihsZXQgaT0wO2k8MztpKyspe2NvbnN0IHk9VCsoQi1UKSppLzI7Y3R4LmJlZ2luUGF0aCgpO2N0eC5tb3ZlVG8oTCx5KTtjdHgubGluZVRvKFIseSk7Y3R4LnN0cm9rZSgpfQoKIGN0eC5zdHJva2VTdHlsZT1jLmxpbmU7Y3R4LmxpbmVXaWR0aD0xLjU1KmRwcjtjdHguYmVnaW5QYXRoKCk7CiBwdHMuZm9yRWFjaCgocCxpKT0+e2NvbnN0IHg9TCsoUi1MKSpwLnQvZHVyYXRpb24seT1CLShCLVQpKk1hdGgubWluKHltYXgscC5tcykveW1heDtpP2N0eC5saW5lVG8oeCx5KTpjdHgubW92ZVRvKHgseSl9KTtjdHguc3Ryb2tlKCk7CgogaWYoUy5yYW5nZUFjdGl2ZSl7CiAgY29uc3QgeDE9TCsoUi1MKSpTLnN0YXJ0L2R1cmF0aW9uLHgyPUwrKFItTCkqUy5lbmQvZHVyYXRpb247CiAgY3R4LmZpbGxTdHlsZT0ncmdiYSgxMTAsMTY4LDI1NSwuMDcpJztjdHguZmlsbFJlY3QoeDEsVCxNYXRoLm1heCgxLHgyLXgxKSxCLVQpOwogIGN0eC5zdHJva2VTdHlsZT0ncmdiYSgxMTAsMTY4LDI1NSwuNDIpJztjdHguc3Ryb2tlUmVjdCh4MSxULE1hdGgubWF4KDEseDIteDEpLEItVCk7CiB9CgogaWYoTnVtYmVyLmlzRmluaXRlKFMuaG92ZXJUKSl7CiAgY29uc3QgaHg9TCsoUi1MKSpTLmhvdmVyVC9kdXJhdGlvbjsKICBjdHguc3Ryb2tlU3R5bGU9Yy5ob3ZlcjtjdHgubGluZVdpZHRoPWRwcjtjdHguYmVnaW5QYXRoKCk7Y3R4Lm1vdmVUbyhoeCxUKTtjdHgubGluZVRvKGh4LEIpO2N0eC5zdHJva2UoKTsKICBjb25zdCBwPW5lYXJlc3QocHRzLFMuaG92ZXJULHo9PnoudCk7CiAgaWYocCl7Y29uc3QgeT1CLShCLVQpKk1hdGgubWluKHltYXgscC5tcykveW1heDtjdHguZmlsbFN0eWxlPWMudGV4dDtjdHguYmVnaW5QYXRoKCk7Y3R4LmFyYyhoeCx5LDMqZHByLDAsTWF0aC5QSSoyKTtjdHguZmlsbCgpfQogfQoKIFMuZnJhbWVQbG90PXtkdXJhdGlvbn07Cn0KCmZ1bmN0aW9uIGNsZWFyU2VsZWN0aW9uKCl7CiBTLnJhbmdlQWN0aXZlPWZhbHNlO1Muc3RhcnQ9MDtTLmVuZD1OdW1iZXIoUy5kYXRhPy5EdXJhdGlvblNlYyl8fDA7JCgncmFuZ2VTdGFydCcpLnZhbHVlPScnOyQoJ3JhbmdlRW5kJykudmFsdWU9Jyc7aW52YWxpZGF0ZVJhbmdlKCk7cmVuZGVyQWxsKCk7Cn0KZnVuY3Rpb24gYXBwbHlSYW5nZUlucHV0cygpewogaWYoIVMuZGF0YSlyZXR1cm47CiBjb25zdCBkdXI9TnVtYmVyKFMuZGF0YS5EdXJhdGlvblNlYyl8fDAscmF3QT0kKCdyYW5nZVN0YXJ0JykudmFsdWUscmF3Qj0kKCdyYW5nZUVuZCcpLnZhbHVlOwogaWYocmF3QT09PScnfHxyYXdCPT09Jycpe2NsZWFyU2VsZWN0aW9uKCk7cmV0dXJufQogbGV0IGE9Y2xhbXAoTnVtYmVyKHJhd0EpLDAsZHVyKSxiPWNsYW1wKE51bWJlcihyYXdCKSwwLGR1cik7CiBpZighTnVtYmVyLmlzRmluaXRlKGEpfHwhTnVtYmVyLmlzRmluaXRlKGIpfHxNYXRoLmFicyhiLWEpPC4wNSl7Y2xlYXJTZWxlY3Rpb24oKTtyZXR1cm59CiBpZihiPGEpW2EsYl09W2IsYV07CiBTLnJhbmdlQWN0aXZlPXRydWU7Uy5zdGFydD1hO1MuZW5kPWI7JCgncmFuZ2VTdGFydCcpLnZhbHVlPWEudG9GaXhlZCgxKTskKCdyYW5nZUVuZCcpLnZhbHVlPWIudG9GaXhlZCgxKTtpbnZhbGlkYXRlUmFuZ2UoKTtyZW5kZXJBbGwoKTsKfQoKZnVuY3Rpb24gc2NoZWR1bGVIb3ZlclJlbmRlcigpewogaWYoUy5ob3ZlclJhZilyZXR1cm47CiBTLmhvdmVyUmFmPXJlcXVlc3RBbmltYXRpb25GcmFtZSgoKT0+e1MuaG92ZXJSYWY9MDtkcmF3RnJhbWUoKTtyZW5kZXJIb3ZlcigpO3VwZGF0ZUNhcmRIb3Zlck9ubHkoKX0pOwp9CgpmdW5jdGlvbiBiaW5kRnJhbWUoKXsKIGNvbnN0IGM9JCgnZnJhbWVDaGFydCcpOwogYy5vbnBvaW50ZXJkb3duPWU9PnsKICBpZighUy5kYXRhfHwhUy5mcmFtZVBsb3QpcmV0dXJuOwogIGNvbnN0IHI9Yy5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKSxyYXRpbz1jbGFtcCgoZS5jbGllbnRYLXIubGVmdCkvci53aWR0aCwwLDEpOwogIFMuZHJhZz10cnVlO1MuZHJhZ1N0YXJ0VD1yYXRpbypTLmZyYW1lUGxvdC5kdXJhdGlvbjtjLnNldFBvaW50ZXJDYXB0dXJlKGUucG9pbnRlcklkKTsKIH07CiBjLm9ucG9pbnRlcm1vdmU9ZT0+ewogIGlmKCFTLmRhdGF8fCFTLmZyYW1lUGxvdClyZXR1cm47CiAgY29uc3Qgcj1jLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpLHJhdGlvPWNsYW1wKChlLmNsaWVudFgtci5sZWZ0KS9yLndpZHRoLDAsMSksdD1yYXRpbypTLmZyYW1lUGxvdC5kdXJhdGlvbjsKICBTLmhvdmVyVD10OwogIGlmKFMuZHJhZyYmTWF0aC5hYnModC1TLmRyYWdTdGFydFQpPj0uMzApewogICBjb25zdCBucz1NYXRoLm1pbihTLmRyYWdTdGFydFQsdCksbmU9TWF0aC5tYXgoUy5kcmFnU3RhcnRULHQpOwogICBpZighUy5yYW5nZUFjdGl2ZXx8TWF0aC5hYnMobnMtUy5zdGFydCk+LjAzfHxNYXRoLmFicyhuZS1TLmVuZCk+LjAzKXsKICAgIFMucmFuZ2VBY3RpdmU9dHJ1ZTtTLnN0YXJ0PW5zO1MuZW5kPW5lO2ludmFsaWRhdGVSYW5nZSgpOwogICAgJCgncmFuZ2VTdGFydCcpLnZhbHVlPVMuc3RhcnQudG9GaXhlZCgxKTskKCdyYW5nZUVuZCcpLnZhbHVlPVMuZW5kLnRvRml4ZWQoMSk7cmVuZGVyUmFuZ2UoKTt1cGRhdGVDYXJkUmFuZ2VTdGF0cygpOwogICB9CiAgfQogIHNjaGVkdWxlSG92ZXJSZW5kZXIoKTsKIH07CiBjLm9ucG9pbnRlcnVwPWU9PntTLmRyYWc9ZmFsc2U7dHJ5e2MucmVsZWFzZVBvaW50ZXJDYXB0dXJlKGUucG9pbnRlcklkKX1jYXRjaHt9fTsKIGMub25wb2ludGVybGVhdmU9KCk9PntTLmhvdmVyVD1udWxsO3NjaGVkdWxlSG92ZXJSZW5kZXIoKX07CiBjLm9uZGJsY2xpY2s9Y2xlYXJTZWxlY3Rpb247Cn0KCmZ1bmN0aW9uIHJlbmRlckhvdmVyKCl7CiBjb25zdCBjZWxscz0kKCdob3ZlckNlbGxzJyksZnJhbWU9TnVtYmVyLmlzRmluaXRlKFMuaG92ZXJUKT9uZWFyZXN0KGZyYW1lUG9pbnRzKCksUy5ob3ZlclQscD0+cC50KTpudWxsOwogJCgnaG92ZXJUaW1lJykudGV4dENvbnRlbnQ9TnVtYmVyLmlzRmluaXRlKFMuaG92ZXJUKT9gJHtTLmhvdmVyVC50b0ZpeGVkKDIpfSBzYDonTW92ZSBvdmVyIHRoZSBmcmFtZXRpbWUgZ3JhcGgnOwoKIGxldCBodG1sPWA8ZGl2IGNsYXNzPSJob3ZlcmNlbGwiPjxkaXYgY2xhc3M9ImsiPkZyYW1ldGltZTwvZGl2PjxkaXYgY2xhc3M9InYiPiR7ZnJhbWU/Zm10KGZyYW1lLm1zLDIpKycgbXMnOifigJQnfTwvZGl2PjxkaXYgY2xhc3M9ImQiPmZyYW1lIHNhbXBsZTwvZGl2PjwvZGl2PmA7CiBodG1sKz1gPGRpdiBjbGFzcz0iaG92ZXJjZWxsIj48ZGl2IGNsYXNzPSJrIj5GUFM8L2Rpdj48ZGl2IGNsYXNzPSJ2Ij4ke2ZyYW1lP2ZtdCgxMDAwL2ZyYW1lLm1zLDEpKycgRlBTJzon4oCUJ308L2Rpdj48ZGl2IGNsYXNzPSJkIj5pbnN0YW50YW5lb3VzPC9kaXY+PC9kaXY+YDsKCiBmb3IoY29uc3QgeCBvZiBzZWxlY3RlZEl0ZW1zKCkpewogIGNvbnN0IHY9aG92ZXJWYWx1ZSh4KSx1PXguVW5pdHx8Jyc7CiAgaHRtbCs9YDxkaXYgY2xhc3M9ImhvdmVyY2VsbCI+PGRpdiBjbGFzcz0iayI+JHtlc2MoeC5OYW1lKX08L2Rpdj48ZGl2IGNsYXNzPSJ2Ij4ke3Y9PT1udWxsPyfigJQnOmZtdCh2LDIpKyh1PycgJytlc2ModSk6JycpfTwvZGl2PjxkaXYgY2xhc3M9ImQiPiR7eC5SZWNvcmRlZD8nbmVhcmVzdCByZWNvcmRlZCBzYW1wbGUnOidubyBjYXB0dXJlIGhpc3RvcnknfTwvZGl2PjwvZGl2PmA7CiB9CiBjZWxscy5pbm5lckhUTUw9aHRtbDsKfQoKZnVuY3Rpb24gc3RhdEZtdCh2LHUsZD0yKXtyZXR1cm4gdiE9PW51bGwmJnYhPT11bmRlZmluZWQmJk51bWJlci5pc0Zpbml0ZShOdW1iZXIodikpP2ZtdCh2LGQpKyh1PycgJyt1OicnKTon4oCUJ30KCmZ1bmN0aW9uIGNhcmRIdG1sKHgsaXNDb3JlKXsKIHJldHVybiBgPGFydGljbGUgY2xhc3M9InBpbi1jYXJkIiBkYXRhLWtleT0iJHtlc2MoeC5LZXkpfSI+CiAgPGRpdiBjbGFzcz0icGluLWhlYWQiPgogICA8ZGl2IGNsYXNzPSJwaW4tdGl0bGUiPjxkaXYgY2xhc3M9ImwiPiR7ZXNjKHguTmFtZSl9PC9kaXY+PGRpdiBjbGFzcz0iZyI+JHtlc2MoeC5UeXBlfHwnc2Vuc29yJyl9JHt4Lk1hdGNoTm90ZT8nIMK3ICcrZXNjKHguTWF0Y2hOb3RlKTonJ308L2Rpdj48c3BhbiBjbGFzcz0iY2F0YmFkZ2UgJHt4LlJlY29yZGVkPydyZWNvcmRlZCc6Jyd9Ij4ke3guUmVjb3JkZWQ/J1JlY29yZGVkJzonTm8gaGlzdG9yeSd9PC9zcGFuPjwvZGl2PgogICA8ZGl2IGNsYXNzPSJwaW4tYWN0aW9ucyI+JHtpc0NvcmU/Jyc6YDxidXR0b24gY2xhc3M9Imljb25idG4iIGRhdGEtcmVtb3ZlIHR5cGU9ImJ1dHRvbiI+UmVtb3ZlPC9idXR0b24+YH08L2Rpdj4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJwaW4tcHJpbWFyeSI+PGRpdj48ZGl2IGNsYXNzPSJiaWciIGRhdGEtcHJpbWFyeT7igJQ8L2Rpdj48ZGl2IGNsYXNzPSJzbWFsbG1vZGUiIGRhdGEtbW9kZT5BbmFseXNpcyBhdmVyYWdlPC9kaXY+PC9kaXY+PC9kaXY+CiAgPGRpdiBjbGFzcz0ic3RhdGdyaWQiPgogICA8ZGl2IGNsYXNzPSJzYm94Ij48ZGl2IGNsYXNzPSJrIj5Ib3ZlcjwvZGl2PjxkaXYgY2xhc3M9InYiIGRhdGEtaG92ZXI+4oCUPC9kaXY+PC9kaXY+CiAgIDxkaXYgY2xhc3M9InNib3giPjxkaXYgY2xhc3M9ImsiPk1pbjwvZGl2PjxkaXYgY2xhc3M9InYiIGRhdGEtbWluPuKAlDwvZGl2PjwvZGl2PgogICA8ZGl2IGNsYXNzPSJzYm94Ij48ZGl2IGNsYXNzPSJrIj5Bdmc8L2Rpdj48ZGl2IGNsYXNzPSJ2IiBkYXRhLWF2Zz7igJQ8L2Rpdj48L2Rpdj4KICAgPGRpdiBjbGFzcz0ic2JveCI+PGRpdiBjbGFzcz0iayI+TWF4PC9kaXY+PGRpdiBjbGFzcz0idiIgZGF0YS1tYXg+4oCUPC9kaXY+PC9kaXY+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0icGluLWNoYXJ0Ij48Y2FudmFzPjwvY2FudmFzPjxkaXYgY2xhc3M9ImNoYXJ0LWxlZ2VuZCIgZGF0YS1sZWdlbmQ+MCBzYW1wbGVzPC9kaXY+JHt4LlJlY29yZGVkPycnOic8ZGl2IGNsYXNzPSJuby1oaXN0b3J5Ij5ObyBoaXN0b3JpY2FsIHNhbXBsZXMgZm9yIHRoaXMgbWV0cmljIGluIHRoaXMgY2FwdHVyZS48L2Rpdj4nfTwvZGl2PgogPC9hcnRpY2xlPmA7Cn0KCmZ1bmN0aW9uIG1ldHJpY1Bsb3QoY2FudmFzLHgpewogY29uc3QgcHRzPXJhbmdlUG9pbnRzKHgpLHtjdHgsdyxoLGRwcn09Y2FudmFzU2V0dXAoY2FudmFzKTtjdHguY2xlYXJSZWN0KDAsMCx3LGgpOwogaWYocHRzLmxlbmd0aDwyKXJldHVybjsKIGNvbnN0IHZhbHM9cHRzLm1hcChwPT5wLnYpLGxvMD1NYXRoLm1pbiguLi52YWxzKSxoaTA9TWF0aC5tYXgoLi4udmFscykscGFkPShoaTAtbG8wKSouMTB8fDEsbG89bG8wLXBhZCxoaT1oaTArcGFkOwogY29uc3QgdDA9YWN0aXZlU3RhcnQoKSx0MT1hY3RpdmVFbmQoKSxMPTQqZHByLFI9dy00KmRwcixUPTQqZHByLEI9aC0xNCpkcHIsYz1jb2xvcnMoKTsKIGN0eC5zdHJva2VTdHlsZT1jLmdyaWQ7Y3R4LmxpbmVXaWR0aD1kcHI7CiBmb3IobGV0IGk9MDtpPDM7aSsrKXtjb25zdCB5PVQrKEItVCkqaS8yO2N0eC5iZWdpblBhdGgoKTtjdHgubW92ZVRvKEwseSk7Y3R4LmxpbmVUbyhSLHkpO2N0eC5zdHJva2UoKX0KIGN0eC5zdHJva2VTdHlsZT1jLmxpbmU7Y3R4LmxpbmVXaWR0aD0xLjU1KmRwcjtjdHguYmVnaW5QYXRoKCk7CiBwdHMuZm9yRWFjaCgocCxpKT0+e2NvbnN0IHB4PUwrKFItTCkqKHAudC10MCkvTWF0aC5tYXgoLjAwMSx0MS10MCkscHk9Qi0oQi1UKSoocC52LWxvKS8oaGktbG8pO2k/Y3R4LmxpbmVUbyhweCxweSk6Y3R4Lm1vdmVUbyhweCxweSl9KTtjdHguc3Ryb2tlKCk7CiBpZihOdW1iZXIuaXNGaW5pdGUoUy5ob3ZlclQpJiZTLmhvdmVyVD49dDAmJlMuaG92ZXJUPD10MSl7CiAgY29uc3QgaHg9TCsoUi1MKSooUy5ob3ZlclQtdDApL01hdGgubWF4KC4wMDEsdDEtdDApLHA9bmVhcmVzdChwdHMsUy5ob3ZlclQsej0+ei50KTsKICBjdHguc3Ryb2tlU3R5bGU9Yy5ob3ZlcjtjdHgubGluZVdpZHRoPWRwcjtjdHguYmVnaW5QYXRoKCk7Y3R4Lm1vdmVUbyhoeCxUKTtjdHgubGluZVRvKGh4LEIpO2N0eC5zdHJva2UoKTsKICBpZihwKXtjb25zdCBweT1CLShCLVQpKihwLnYtbG8pLyhoaS1sbyk7Y3R4LmZpbGxTdHlsZT1jLnRleHQ7Y3R4LmJlZ2luUGF0aCgpO2N0eC5hcmMoaHgscHksMypkcHIsMCxNYXRoLlBJKjIpO2N0eC5maWxsKCl9CiB9Cn0KCmZ1bmN0aW9uIGJpbmRNZXRyaWNDYW52YXMoY2FudmFzLGtleSl7CiBjYW52YXMub25wb2ludGVybW92ZT1lPT57CiAgY29uc3QgeD1jYXRhbG9nKCkuZmluZCh2PT52LktleT09PWtleSk7aWYoIXh8fCFTLmRhdGEpcmV0dXJuOwogIGNvbnN0IHI9Y2FudmFzLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpLHJhdGlvPWNsYW1wKChlLmNsaWVudFgtci5sZWZ0KS9yLndpZHRoLDAsMSk7CiAgUy5ob3ZlclQ9YWN0aXZlU3RhcnQoKStyYXRpbypNYXRoLm1heCguMDAxLGFjdGl2ZUVuZCgpLWFjdGl2ZVN0YXJ0KCkpO3NjaGVkdWxlSG92ZXJSZW5kZXIoKTsKIH07CiBjYW52YXMub25wb2ludGVybGVhdmU9KCk9PntTLmhvdmVyVD1udWxsO3NjaGVkdWxlSG92ZXJSZW5kZXIoKX07Cn0KCmZ1bmN0aW9uIHN5bmNDYXJkcygpewogY29uc3QgZ3JpZD0kKCdwaW5HcmlkJyksd2FudGVkPXNlbGVjdGVkSXRlbXMoKTsKIGlmKCF3YW50ZWQubGVuZ3RoKXtncmlkLmlubmVySFRNTD0nPGRpdiBjbGFzcz0iY2FyZHNFbXB0eSI+Tm8gbWV0cmljcyBlbmFibGVkLiBUdXJuIG9uIGEgY29yZSBtZXRyaWMgb3IgYWRkIG1vcmUuPC9kaXY+JzskKCdzZWxlY3RlZENvdW50JykudGV4dENvbnRlbnQ9JzAgbWV0cmljcyBzZWxlY3RlZCc7cmV0dXJufQogY29uc3QgZXhpc3Rpbmc9bmV3IE1hcChbLi4uZ3JpZC5xdWVyeVNlbGVjdG9yQWxsKCcucGluLWNhcmQnKV0ubWFwKGM9PltjLmRhdGFzZXQua2V5LGNdKSk7CiBncmlkLnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXJkc0VtcHR5JykuZm9yRWFjaChlPT5lLnJlbW92ZSgpKTsKIGxldCBjdXJzb3I9Z3JpZC5maXJzdEVsZW1lbnRDaGlsZDsKIGZvcihjb25zdCB4IG9mIHdhbnRlZCl7CiAgbGV0IGNhcmQ9ZXhpc3RpbmcuZ2V0KHguS2V5KTsKICBpZighY2FyZCl7CiAgIGNvbnN0IGNvcmVEZWY9Q09SRS5maW5kKGRlZj0+Uy5jb3JlRW5hYmxlZC5oYXMoZGVmLmlkKSYmcmVzb2x2ZUNvcmUoZGVmKT8uS2V5PT09eC5LZXkpOwogICBjb25zdCB0PWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3RlbXBsYXRlJyk7dC5pbm5lckhUTUw9Y2FyZEh0bWwoeCwhIWNvcmVEZWYpLnRyaW0oKTtjYXJkPXQuY29udGVudC5maXJzdEVsZW1lbnRDaGlsZDsKICAgY29uc3Qgcm09Y2FyZC5xdWVyeVNlbGVjdG9yKCdbZGF0YS1yZW1vdmVdJyk7CiAgIGlmKHJtKXJtLm9uY2xpY2s9KCk9PntTLmV4dHJhTmFtZXMuZGVsZXRlKG5vcm0oeC5OYW1lKSk7aW52YWxpZGF0ZVNlbGVjdGlvbigpO3NhdmVQcmVmcygpO3JlbmRlckFsbCgpfTsKICAgYmluZE1ldHJpY0NhbnZhcyhjYXJkLnF1ZXJ5U2VsZWN0b3IoJ2NhbnZhcycpLHguS2V5KTsKICB9CiAgaWYoY2FyZCE9PWN1cnNvcilncmlkLmluc2VydEJlZm9yZShjYXJkLGN1cnNvcik7CiAgY3Vyc29yPWNhcmQubmV4dEVsZW1lbnRTaWJsaW5nO2V4aXN0aW5nLmRlbGV0ZSh4LktleSk7CiB9CiBleGlzdGluZy5mb3JFYWNoKGM9PmMucmVtb3ZlKCkpOwogJCgnc2VsZWN0ZWRDb3VudCcpLnRleHRDb250ZW50PWAke3dhbnRlZC5sZW5ndGh9IG1ldHJpY3Mgc2VsZWN0ZWRgOwp9CgpmdW5jdGlvbiB1cGRhdGVDYXJkKGNhcmQseCl7CiBjb25zdCBwdHM9cmFuZ2VQb2ludHMoeCksdmFscz1wdHMubWFwKHA9PnAudiksdT14LlVuaXR8fCcnLGF2Zz1tZWFuKHZhbHMpLG1uPXZhbHMubGVuZ3RoP01hdGgubWluKC4uLnZhbHMpOm51bGwsbXg9dmFscy5sZW5ndGg/TWF0aC5tYXgoLi4udmFscyk6bnVsbCxodj1ob3ZlclZhbHVlKHgpOwogY29uc3QgcHJpbWFyeT1odiE9PW51bGw/aHY6YXZnOwogY2FyZC5kYXRhc2V0LmF2Z1RleHQ9c3RhdEZtdChhdmcsdSwyKTsKIGNhcmQucXVlcnlTZWxlY3RvcignW2RhdGEtcHJpbWFyeV0nKS50ZXh0Q29udGVudD1zdGF0Rm10KHByaW1hcnksdSwyKTsKIGNhcmQucXVlcnlTZWxlY3RvcignW2RhdGEtbW9kZV0nKS50ZXh0Q29udGVudD1odiE9PW51bGwmJk51bWJlci5pc0Zpbml0ZShTLmhvdmVyVCk/YEhvdmVyZWQgQCAke1MuaG92ZXJULnRvRml4ZWQoMil9IHNgOihTLnJhbmdlQWN0aXZlPydSYW5nZSBhdmVyYWdlJzonRnVsbC1jYXB0dXJlIGF2ZXJhZ2UnKTsKIGNhcmQucXVlcnlTZWxlY3RvcignW2RhdGEtaG92ZXJdJykudGV4dENvbnRlbnQ9c3RhdEZtdChodix1LDIpOwogY2FyZC5xdWVyeVNlbGVjdG9yKCdbZGF0YS1taW5dJykudGV4dENvbnRlbnQ9c3RhdEZtdChtbix1LDIpOwogY2FyZC5xdWVyeVNlbGVjdG9yKCdbZGF0YS1hdmddJykudGV4dENvbnRlbnQ9c3RhdEZtdChhdmcsdSwyKTsKIGNhcmQucXVlcnlTZWxlY3RvcignW2RhdGEtbWF4XScpLnRleHRDb250ZW50PXN0YXRGbXQobXgsdSwyKTsKIGNhcmQucXVlcnlTZWxlY3RvcignW2RhdGEtbGVnZW5kXScpLnRleHRDb250ZW50PWAke2FjdGl2ZVN0YXJ0KCkudG9GaXhlZCgxKX3igJMke2FjdGl2ZUVuZCgpLnRvRml4ZWQoMSl9IHMgwrcgJHt2YWxzLmxlbmd0aH0gc2FtcGxlcyDCtyBQOTUgJHtzdGF0Rm10KHF1YW50KHZhbHMsLjk1KSx1LDIpfWA7CiBpZih4LlJlY29yZGVkKW1ldHJpY1Bsb3QoY2FyZC5xdWVyeVNlbGVjdG9yKCdjYW52YXMnKSx4KTsKfQoKZnVuY3Rpb24gdXBkYXRlQ2FyZHMoKXsKIHN5bmNDYXJkcygpOwogY29uc3QgY2F0QnlLZXk9bmV3IE1hcChjYXRhbG9nKCkubWFwKHg9Plt4LktleSx4XSkpOwogZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnBpbi1jYXJkJykuZm9yRWFjaChjYXJkPT57Y29uc3QgeD1jYXRCeUtleS5nZXQoY2FyZC5kYXRhc2V0LmtleSk7aWYoeCl1cGRhdGVDYXJkKGNhcmQseCl9KTsKfQpmdW5jdGlvbiB1cGRhdGVDYXJkUmFuZ2VTdGF0cygpewogY29uc3QgY2F0QnlLZXk9bmV3IE1hcChjYXRhbG9nKCkubWFwKHg9Plt4LktleSx4XSkpOwogZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnBpbi1jYXJkJykuZm9yRWFjaChjYXJkPT57Y29uc3QgeD1jYXRCeUtleS5nZXQoY2FyZC5kYXRhc2V0LmtleSk7aWYoeCl1cGRhdGVDYXJkKGNhcmQseCl9KTsKfQpmdW5jdGlvbiB1cGRhdGVDYXJkSG92ZXJPbmx5KCl7CiBjb25zdCBjYXRCeUtleT1uZXcgTWFwKGNhdGFsb2coKS5tYXAoeD0+W3guS2V5LHhdKSk7CiBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcucGluLWNhcmQnKS5mb3JFYWNoKGNhcmQ9PnsKICBjb25zdCB4PWNhdEJ5S2V5LmdldChjYXJkLmRhdGFzZXQua2V5KTtpZigheClyZXR1cm47CiAgY29uc3QgaHY9aG92ZXJWYWx1ZSh4KSx1PXguVW5pdHx8Jyc7CiAgY29uc3QgYXZnVGV4dD1jYXJkLmRhdGFzZXQuYXZnVGV4dHx8J+KAlCc7CiAgY2FyZC5xdWVyeVNlbGVjdG9yKCdbZGF0YS1wcmltYXJ5XScpLnRleHRDb250ZW50PWh2IT09bnVsbD9zdGF0Rm10KGh2LHUsMik6YXZnVGV4dDsKICBjYXJkLnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLW1vZGVdJykudGV4dENvbnRlbnQ9aHYhPT1udWxsJiZOdW1iZXIuaXNGaW5pdGUoUy5ob3ZlclQpP2BIb3ZlcmVkIEAgJHtTLmhvdmVyVC50b0ZpeGVkKDIpfSBzYDooUy5yYW5nZUFjdGl2ZT8nUmFuZ2UgYXZlcmFnZSc6J0Z1bGwtY2FwdHVyZSBhdmVyYWdlJyk7CiAgY2FyZC5xdWVyeVNlbGVjdG9yKCdbZGF0YS1ob3Zlcl0nKS50ZXh0Q29udGVudD1zdGF0Rm10KGh2LHUsMik7CiAgaWYoeC5SZWNvcmRlZCltZXRyaWNQbG90KGNhcmQucXVlcnlTZWxlY3RvcignY2FudmFzJykseCk7CiB9KTsKfQoKLyogQ29yZSB0b2dnbGVzICovCmZ1bmN0aW9uIHJlbmRlckNvcmUoKXsKIGNvbnN0IGhvc3Q9JCgnY29yZUxpc3QnKTtob3N0LmlubmVySFRNTD0nJzsKIGZvcihjb25zdCBkZWYgb2YgQ09SRSl7CiAgY29uc3QgeD1yZXNvbHZlQ29yZShkZWYpLHJvdz1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTtyb3cuY2xhc3NOYW1lPSdjb3JlUm93JzsKICBjb25zdCBjb3B5PWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpO2NvcHkuY2xhc3NOYW1lPSdjb3JlQ29weSc7CiAgY29uc3Qgc3Ryb25nPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3N0cm9uZycpO3N0cm9uZy50ZXh0Q29udGVudD1kZWYubGFiZWw7CiAgY29uc3Qgc21hbGw9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc21hbGwnKTsKICBzbWFsbC50ZXh0Q29udGVudD14Pyh4LlJlY29yZGVkPydSZWNvcmRlZCBoaXN0b3J5IGF2YWlsYWJsZSc6J0F2YWlsYWJsZSBub3cgwrcgbm8gY2FwdHVyZSBoaXN0b3J5Jyk6J05vdCBhdmFpbGFibGUgb24gdGhpcyBzeXN0ZW0nOwogIGNvcHkuYXBwZW5kKHN0cm9uZyxzbWFsbCk7CgogIGNvbnN0IGxhYmVsPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2xhYmVsJyk7bGFiZWwuY2xhc3NOYW1lPSdzd2l0Y2gnOwogIGNvbnN0IGNiPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2lucHV0Jyk7Y2IudHlwZT0nY2hlY2tib3gnO2NiLmNoZWNrZWQ9Uy5jb3JlRW5hYmxlZC5oYXMoZGVmLmlkKTtjYi5kaXNhYmxlZD0heDsKICBjb25zdCB0cmFjaz1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7dHJhY2suY2xhc3NOYW1lPSd0cmFjayc7dHJhY2suaW5uZXJIVE1MPSc8c3BhbiBjbGFzcz0idGh1bWIiPjwvc3Bhbj4nOwogIGNiLm9uY2hhbmdlPSgpPT57Y2IuY2hlY2tlZD9TLmNvcmVFbmFibGVkLmFkZChkZWYuaWQpOlMuY29yZUVuYWJsZWQuZGVsZXRlKGRlZi5pZCk7aW52YWxpZGF0ZVNlbGVjdGlvbigpO3NhdmVQcmVmcygpO3JlbmRlckhvdmVyKCk7dXBkYXRlQ2FyZHMoKX07CiAgbGFiZWwuYXBwZW5kKGNiLHRyYWNrKTtyb3cuYXBwZW5kKGNvcHksbGFiZWwpO2hvc3QuYXBwZW5kQ2hpbGQocm93KTsKIH0KfQoKLyogR3JvdXBlZCBleHRyYSBtb2RhbCAqLwpmdW5jdGlvbiBtZXRyaWNHcm91cCh4KXsKIGNvbnN0IG49bm9ybShgJHt4Lk5hbWV9ICR7eC5UeXBlfWApOwogaWYoL2dwdXx2cmFtfHZpZGVvIG1lbW9yeS8udGVzdChuKSlyZXR1cm4gJ0dQVSc7CiBpZigvY3B1fHBwdHx0ZGN8ZWRjLy50ZXN0KG4pKXJldHVybiAnQ1BVJzsKIGlmKC9tZW1vcnl8cmFtLy50ZXN0KG4pKXJldHVybiAnTWVtb3J5JzsKIGlmKC90ZW1wZXJhdHVyZXx0aGVybWFsfGhvdCBzcG90Ly50ZXN0KG4pKXJldHVybiAnVGVtcGVyYXR1cmVzJzsKIGlmKC9wb3dlcnx2b2x0YWdlfGN1cnJlbnR8bGltaXQvLnRlc3QobikpcmV0dXJuICdQb3dlciAmIGxpbWl0cyc7CiBpZigvY2xvY2t8ZmFufHJwbS8udGVzdChuKSlyZXR1cm4gJ0Nsb2NrcyAmIGZhbnMnOwogcmV0dXJuICdPdGhlcic7Cn0KZnVuY3Rpb24gY29yZUtleXMoKXtyZXR1cm4gbmV3IFNldChDT1JFLm1hcChyZXNvbHZlQ29yZSkuZmlsdGVyKEJvb2xlYW4pLm1hcCh4PT54LktleSkpfQoKZnVuY3Rpb24gcmVuZGVyRXh0cmFNb2RhbCgpewogY29uc3QgaG9zdD0kKCdncm91cGVkTGlzdCcpLHE9bm9ybShTLmZpbHRlciksY2s9Y29yZUtleXMoKSxncm91cHM9bmV3IE1hcCgpLGNhdD1jYXRhbG9nKCk7CiBjb25zdCBzZWxlY3RlZEtleXM9bmV3IFNldChzZWxlY3RlZEl0ZW1zKCkubWFwKHY9PnYuS2V5KSk7CiBjb25zdCBpdGVtcz1jYXQuZmlsdGVyKHg9PiFjay5oYXMoeC5LZXkpKS5maWx0ZXIoeD0+IXF8fG5vcm0oYCR7eC5OYW1lfSAke3guVHlwZX0gJHt4LlVuaXR9YCkuaW5jbHVkZXMocSkpLnNvcnQoKGEsYik9PmEuTmFtZS5sb2NhbGVDb21wYXJlKGIuTmFtZSkpOwogZm9yKGNvbnN0IHggb2YgaXRlbXMpe2NvbnN0IGc9bWV0cmljR3JvdXAoeCk7aWYoIWdyb3Vwcy5oYXMoZykpZ3JvdXBzLnNldChnLFtdKTtncm91cHMuZ2V0KGcpLnB1c2goeCl9CiBob3N0LmlubmVySFRNTD0nJzsKIGlmKCFpdGVtcy5sZW5ndGgpe2hvc3QuaW5uZXJIVE1MPSc8ZGl2IHN0eWxlPSJwYWRkaW5nOjI0cHg7dGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMHB4Ij5ObyBtYXRjaGluZyBhZGRpdGlvbmFsIG1ldHJpY3MuPC9kaXY+JztyZXR1cm59CiBjb25zdCBmcmFnPWRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKIGZvcihjb25zdCBbZyxhcnJdIG9mIGdyb3Vwcyl7CiAgY29uc3QgYm94PWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NlY3Rpb24nKTtib3guY2xhc3NOYW1lPSdtZ3JvdXAnOwogIGNvbnN0IGhlYWQ9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7aGVhZC5jbGFzc05hbWU9J21ncm91cEhlYWQnO2hlYWQudGV4dENvbnRlbnQ9Zztib3guYXBwZW5kQ2hpbGQoaGVhZCk7CiAgZm9yKGNvbnN0IHggb2YgYXJyKXsKICAgY29uc3Qgcm93PWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpO3Jvdy5jbGFzc05hbWU9J2V4dHJhUm93JzsKICAgY29uc3QgY29weT1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTtjb3B5LmNsYXNzTmFtZT0nZXh0cmFDb3B5JzsKICAgY29uc3Qgc3Ryb25nPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3N0cm9uZycpO3N0cm9uZy50ZXh0Q29udGVudD14Lk5hbWU7CiAgIGNvbnN0IHNtYWxsPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NtYWxsJyk7c21hbGwudGV4dENvbnRlbnQ9KHguVHlwZXx8J3NlbnNvcicpKyh4LlVuaXQ/JyDCtyAnK3guVW5pdDonJykrKHguTWF0Y2hOb3RlPycgwrcgJyt4Lk1hdGNoTm90ZTonJyk7Y29weS5hcHBlbmQoc3Ryb25nLHNtYWxsKTsKICAgY29uc3QgYmFkZ2U9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3BhbicpO2JhZGdlLmNsYXNzTmFtZT0nYmFkZ2UnKyh4LlJlY29yZGVkPycgb2snOicnKTtiYWRnZS50ZXh0Q29udGVudD14LlJlY29yZGVkPydSZWNvcmRlZCc6J05vIGhpc3RvcnknOwogICBjb25zdCBhZGRlZD1TLmV4dHJhTmFtZXMuaGFzKG5vcm0oeC5OYW1lKSl8fHNlbGVjdGVkS2V5cy5oYXMoeC5LZXkpOwogICBjb25zdCBhZGQ9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7YWRkLmNsYXNzTmFtZT0nYnRuJysoYWRkZWQ/Jyc6JyBwcmltYXJ5Jyk7YWRkLnRleHRDb250ZW50PWFkZGVkPydBZGRlZCc6J0FkZCc7YWRkLmRpc2FibGVkPWFkZGVkOwogICBhZGQub25jbGljaz0oKT0+e1MuZXh0cmFOYW1lcy5hZGQobm9ybSh4Lk5hbWUpKTtpbnZhbGlkYXRlU2VsZWN0aW9uKCk7c2F2ZVByZWZzKCk7cmVuZGVyQWxsKCk7cmVuZGVyRXh0cmFNb2RhbCgpfTsKICAgcm93LmFwcGVuZChjb3B5LGJhZGdlLGFkZCk7Ym94LmFwcGVuZENoaWxkKHJvdyk7CiAgfQogIGZyYWcuYXBwZW5kQ2hpbGQoYm94KTsKIH0KIGhvc3QuYXBwZW5kQ2hpbGQoZnJhZyk7Cn0KCmZ1bmN0aW9uIHJlbmRlckFsbCgpe3JlbmRlclJhbmdlKCk7ZHJhd0ZyYW1lKCk7cmVuZGVyQ29yZSgpO3JlbmRlckhvdmVyKCk7dXBkYXRlQ2FyZHMoKX0KCiQoJ2NhcHR1cmVTZWxlY3QnKS5vbmNoYW5nZT0oKT0+Y2hvb3NlQ2FwdHVyZSgkKCdjYXB0dXJlU2VsZWN0JykudmFsdWUpOwokKCdhcHBseVJhbmdlJykub25jbGljaz1hcHBseVJhbmdlSW5wdXRzOyQoJ2NsZWFyUmFuZ2UnKS5vbmNsaWNrPWNsZWFyU2VsZWN0aW9uOwokKCdyYW5nZVN0YXJ0Jykub25rZXlkb3duPWU9PntpZihlLmtleT09PSdFbnRlcicpYXBwbHlSYW5nZUlucHV0cygpfTskKCdyYW5nZUVuZCcpLm9ua2V5ZG93bj1lPT57aWYoZS5rZXk9PT0nRW50ZXInKWFwcGx5UmFuZ2VJbnB1dHMoKX07CiQoJ2FkZE1vcmUnKS5vbmNsaWNrPSgpPT57Uy5maWx0ZXI9Jyc7JCgnbWV0cmljU2VhcmNoJykudmFsdWU9Jyc7JCgnZXh0cmFNb2RhbCcpLnN0eWxlLmRpc3BsYXk9J2dyaWQnOyQoJ2dyb3VwZWRMaXN0JykuaW5uZXJIVE1MPSc8ZGl2IHN0eWxlPSJwYWRkaW5nOjI0cHg7dGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMHB4Ij5Mb2FkaW5nIG1ldHJpY3PigKY8L2Rpdj4nO3JlcXVlc3RBbmltYXRpb25GcmFtZShyZW5kZXJFeHRyYU1vZGFsKX07CiQoJ2Nsb3NlTW9kYWwnKS5vbmNsaWNrPSgpPT57JCgnZXh0cmFNb2RhbCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnfTskKCdjbG9zZU1vZGFsQm90dG9tJykub25jbGljaz0oKT0+eyQoJ2V4dHJhTW9kYWwnKS5zdHlsZS5kaXNwbGF5PSdub25lJ307CiQoJ2V4dHJhTW9kYWwnKS5vbmNsaWNrPWU9PntpZihlLnRhcmdldD09PSQoJ2V4dHJhTW9kYWwnKSkkKCdleHRyYU1vZGFsJykuc3R5bGUuZGlzcGxheT0nbm9uZSd9OwokKCdtZXRyaWNTZWFyY2gnKS5vbmlucHV0PWU9PntTLmZpbHRlcj1lLnRhcmdldC52YWx1ZXx8Jyc7Y2xlYXJUaW1lb3V0KFMubW9kYWxTZWFyY2hUaW1lcik7Uy5tb2RhbFNlYXJjaFRpbWVyPXNldFRpbWVvdXQocmVuZGVyRXh0cmFNb2RhbCw5MCl9Owp3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywoKT0+e2lmKFMuZGF0YSlyZW5kZXJBbGwoKX0pOwoKYmluZEZyYW1lKCk7bG9hZFJlY29yZHMoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPg=="))
# CAPTURE-DASH-V2-END
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
# -----------------------------
# Optional CapFrameX MCP bridge
# -----------------------------
$script:CapFrameXPort = $null
$script:CapFrameXPortCheckedAt = [DateTime]::MinValue
$script:CapFrameXLatest = $null
$script:CapFrameXLatestRecordId = $null
$script:CapFrameXLatestAt = [DateTime]::MinValue
$script:CapFrameXWasCapturing = $false

function Invoke-CapFrameXRpc {
    param([int]$CapFrameXPort,[string]$Method,[object]$Params = $null)

    $payload = [ordered]@{ jsonrpc = "2.0"; id = 1; method = $Method }
    if ($null -ne $Params) { $payload["params"] = $Params }

    $body = $payload | ConvertTo-Json -Depth 12 -Compress
    $uri = "http://127.0.0.1:{0}/mcp" -f $CapFrameXPort
    return Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 2 -ErrorAction Stop
}

function Invoke-CapFrameXTool {
    param([int]$CapFrameXPort,[string]$Name,[hashtable]$Arguments = @{})

    $response = Invoke-CapFrameXRpc -CapFrameXPort $CapFrameXPort -Method "tools/call" -Params ([ordered]@{
        name = $Name
        arguments = $Arguments
    })

    if ($null -ne $response.error) { throw ("CapFrameX MCP error: " + $response.error.message) }

    $content = @($response.result.content)
    if ($content.Count -eq 0) { return $null }
    $text = [string]$content[0].text
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try { return ($text | ConvertFrom-Json) }
    catch { return $text }
}

function Test-CapFrameXPort {
    param([int]$Candidate)
    if ($Candidate -lt 1 -or $Candidate -gt 65535) { return $false }
    try {
        $response = Invoke-CapFrameXRpc -CapFrameXPort $Candidate -Method "ping"
        return ($null -eq $response.error)
    }
    catch { return $false }
}

function Get-CapFrameXCandidatePorts {
    $ports = New-Object System.Collections.Generic.List[int]

    function Add-PortCandidate([object]$Value) {
        $parsed = 0
        if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
            if (-not $ports.Contains($parsed)) { $ports.Add($parsed) }
        }
    }

    $configFiles = New-Object System.Collections.Generic.List[string]
    $logFiles = New-Object System.Collections.Generic.List[string]

    if ($env:APPDATA) {
        $configFiles.Add((Join-Path $env:APPDATA "CapFrameX\Configuration\AppSettings.json"))
        $logFiles.Add((Join-Path $env:APPDATA "CapFrameX\Logs\CapFrameX.log"))
    }

    try {
        $process = Get-Process -Name "CapFrameX" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process) {
            $exePath = $process.Path
            if (-not $exePath -and $process.MainModule) { $exePath = $process.MainModule.FileName }

            if ($exePath) {
                $exeDir = Split-Path -Parent $exePath
                $portableFile = Join-Path $exeDir "portable.json"

                if (Test-Path -LiteralPath $portableFile) {
                    try {
                        $portable = Get-Content -LiteralPath $portableFile -Raw | ConvertFrom-Json
                        $configPath = [string]$portable.paths.config
                        $logsPath = [string]$portable.paths.logs

                        if ([string]::IsNullOrWhiteSpace($configPath)) { $configPath = ".\Portable\Config" }
                        if ([string]::IsNullOrWhiteSpace($logsPath)) { $logsPath = ".\Portable\Logs" }

                        if (-not [System.IO.Path]::IsPathRooted($configPath)) { $configPath = Join-Path $exeDir $configPath }
                        if (-not [System.IO.Path]::IsPathRooted($logsPath)) { $logsPath = Join-Path $exeDir $logsPath }

                        $configFiles.Add((Join-Path $configPath "AppSettings.json"))
                        $logFiles.Add((Join-Path $logsPath "CapFrameX.log"))
                    } catch {}
                }
            }
        }
    } catch {}

    foreach ($file in $configFiles) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $settings = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            Add-PortCandidate $settings.WebservicePort
        } catch {}
    }

    foreach ($file in $logFiles) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $tail = Get-Content -LiteralPath $file -Tail 300 -ErrorAction Stop
            $matches = @($tail | Select-String -Pattern 'MCP endpoint available at http://localhost:(\d+)/mcp' -AllMatches)
            if ($matches.Count -gt 0) {
                $last = $matches[$matches.Count - 1]
                if ($last.Matches.Count -gt 0) {
                    Add-PortCandidate $last.Matches[$last.Matches.Count - 1].Groups[1].Value
                }
            }
        } catch {}
    }

    Add-PortCandidate 1337
    return @($ports)
}

function Get-CapFrameXPort {
    $age = ([DateTime]::UtcNow - $script:CapFrameXPortCheckedAt).TotalSeconds
    if ($script:CapFrameXPort -and $age -lt 5) { return $script:CapFrameXPort }

    $script:CapFrameXPortCheckedAt = [DateTime]::UtcNow

    foreach ($candidate in (Get-CapFrameXCandidatePorts)) {
        if (Test-CapFrameXPort $candidate) {
            $script:CapFrameXPort = $candidate
            return $candidate
        }
    }

    $script:CapFrameXPort = $null
    return $null
}

function ConvertTo-CapFrameXNumber {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    try {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
        return [Math]::Round($number, 4)
    } catch { return $null }
}

function Get-CapFrameXMetricValue {
    param([object]$Metrics,[string]$Name)
    if ($null -eq $Metrics) { return $null }

    $run = @($Metrics.runs) | Select-Object -First 1
    if ($null -eq $run) { return $null }

    $metric = @($run.metrics) | Where-Object { [string]$_.metric -eq $Name } | Select-Object -First 1
    if ($null -eq $metric) { return $null }

    return ConvertTo-CapFrameXNumber $metric.value
}

function Get-CapFrameXApiObject {
    $port = Get-CapFrameXPort

    if (-not $port) {
        return [ordered]@{
            Available = $false
            Message = "CapFrameX is not running, is too old for its MCP endpoint, or the endpoint could not be detected."
            Status = $null
            Latest = $null
            RefreshedAt = [DateTime]::UtcNow.ToString("o")
        }
    }

    try {
        $status = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_get_capture_status"
    } catch {
        $script:CapFrameXPort = $null
        return [ordered]@{
            Available = $false
            Message = "CapFrameX was detected but its MCP endpoint did not respond."
            Status = $null
            Latest = $null
            RefreshedAt = [DateTime]::UtcNow.ToString("o")
        }
    }

    $isCapturing = [bool]$status.isCapturing
    if ($script:CapFrameXWasCapturing -and -not $isCapturing) {
        $script:CapFrameXLatestAt = [DateTime]::MinValue
    }
    $script:CapFrameXWasCapturing = $isCapturing

    $statusOut = [ordered]@{
        IsCapturing = $isCapturing
        IsLocked = [bool]$status.isLocked
        DelayCountdownRunning = [bool]$status.delayCountdownRunning
        State = [string]$status.state
        LastMessage = [string]$status.lastMessage
    }

    $latestOut = $script:CapFrameXLatest
    $cacheAge = ([DateTime]::UtcNow - $script:CapFrameXLatestAt).TotalSeconds

    if ($null -eq $latestOut -or $cacheAge -ge 5 -or -not $isCapturing) {
        try {
            $records = @(Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_list_records" -Arguments @{ limit = 1 })
            $record = $records | Select-Object -First 1

            if ($record) {
                $recordId = [string]$record.id
                $sameRecord = ($script:CapFrameXLatestRecordId -eq $recordId)
                $needsRefresh = (-not $sameRecord) -or ($cacheAge -ge 5)

                if ($needsRefresh) {
                    $detail = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_get_record" -Arguments @{ id = $recordId }

                    $metrics = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_get_metrics" -Arguments @{
                        id = $recordId
                        runIndex = 0
                        metrics = @(
                            "Average",
                            "P1",
                            "P0dot2",
                            "Min",
                            "Max",
                            "OnePercentLowAverage",
                            "ZerodotTwoPercentLowAverage"
                        )
                    }

                    $useDisplay = ([string]$metrics.metricSource -eq "MsBetweenDisplayChange")

                    $frames = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_get_frametimes" -Arguments @{
                        id = $recordId
                        runIndex = 0
                        downsampleHz = 30
                        useDisplayChangeMetrics = $useDisplay
                    }

                    $stutters = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_find_stutters" -Arguments @{
                        id = $recordId
                        runIndex = 0
                        factorVsMedian = 2.0
                        minMs = 8.0
                        windowFrames = 51
                        maxResults = 200
                        useDisplayChangeMetrics = $useDisplay
                    }

                    $freezes = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_find_freezes" -Arguments @{
                        id = $recordId
                        runIndex = 0
                        minMs = 100.0
                        maxResults = 100
                        useDisplayChangeMetrics = $useDisplay
                    }

                    $points = @()
                    foreach ($point in @($frames.points)) {
                        $t = ConvertTo-CapFrameXNumber $point.tSec
                        $ms = ConvertTo-CapFrameXNumber $point.frametimeMs
                        if ($null -ne $t -and $null -ne $ms) {
                            $points += [ordered]@{ TSec = $t; FrametimeMs = $ms }
                        }
                    }

                    $latestOut = [ordered]@{
                        Game = [string]$detail.game
                        ProcessName = [string]$detail.processName
                        RecordedAt = [string]$detail.recordedAt
                        DurationSec = ConvertTo-CapFrameXNumber $detail.durationSec
                        Runs = [int]$detail.runs
                        MetricSource = [string]$metrics.metricSource
                        MetricSourceWarning = [string]$metrics.metricSourceWarning
                        Metrics = [ordered]@{
                            Average = Get-CapFrameXMetricValue $metrics "Average"
                            P1 = Get-CapFrameXMetricValue $metrics "P1"
                            P0dot2 = Get-CapFrameXMetricValue $metrics "P0dot2"
                            Min = Get-CapFrameXMetricValue $metrics "Min"
                            Max = Get-CapFrameXMetricValue $metrics "Max"
                            OnePercentLowAverage = Get-CapFrameXMetricValue $metrics "OnePercentLowAverage"
                            ZerodotTwoPercentLowAverage = Get-CapFrameXMetricValue $metrics "ZerodotTwoPercentLowAverage"
                        }
                        FrameCount = [int]$frames.frameCount
                        SampleHz = ConvertTo-CapFrameXNumber $frames.sampleHz
                        Frametimes = $points
                        StutterCount = [int]$stutters.totalCount
                        FreezeCount = [int]$freezes.totalCount
                    }

                    $script:CapFrameXLatest = $latestOut
                    $script:CapFrameXLatestRecordId = $recordId
                    $script:CapFrameXLatestAt = [DateTime]::UtcNow
                }
            }
        } catch {
            # Keep the previous completed capture visible if refresh fails.
        }
    }

    return [ordered]@{
        Available = $true
        Message = $null
        Status = $statusOut
        Latest = $latestOut
        RefreshedAt = [DateTime]::UtcNow.ToString("o")
    }
}


function Get-CapFrameXLiveJson {
    $port = Get-CapFrameXPort
    if (-not $port) {
        return ([ordered]@{
            Available = $false
            Message = "CapFrameX MCP/webservice endpoint is not available."
            Metrics = $null
        } | ConvertTo-Json -Depth 5 -Compress)
    }

    try {
        $metricNames = "Average,P95,P1,OnePercentLowAverage,CPUBusy,GPUBusy"
        $encodedNames = [System.Uri]::EscapeDataString($metricNames)
        $uri = "http://127.0.0.1:{0}/api/metrics?metricNames={1}" -f $port, $encodedNames
        $values = @(Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 2 -ErrorAction Stop)

        $names = @("Average","P95","P1","OnePercentLowAverage","CPUBusy","GPUBusy")
        $metrics = [ordered]@{}

        for ($i = 0; $i -lt $names.Count; $i++) {
            $value = $null
            if ($i -lt $values.Count) {
                try {
                    $number = [double]$values[$i]
                    if (-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) {
                        $value = [Math]::Round($number, 4)
                    }
                } catch {}
            }
            $metrics[$names[$i]] = $value
        }

        return ([ordered]@{
            Available = $true
            Message = $null
            Metrics = $metrics
            RefreshedAt = [DateTime]::UtcNow.ToString("o")
        } | ConvertTo-Json -Depth 5 -Compress)
    }
    catch {
        return ([ordered]@{
            Available = $false
            Message = $_.Exception.Message
            Metrics = $null
            RefreshedAt = [DateTime]::UtcNow.ToString("o")
        } | ConvertTo-Json -Depth 5 -Compress)
    }
}

# CAPTURE-DASH-V2-API-BEGIN
$script:CaptureDashRecordMap = @{}

function Get-RequestQueryValue {
    param([string]$RawTarget,[string]$Name)
    if ([string]::IsNullOrWhiteSpace($RawTarget)) { return $null }
    $q = $RawTarget.IndexOf("?")
    if ($q -lt 0 -or $q -ge ($RawTarget.Length - 1)) { return $null }
    foreach ($pair in $RawTarget.Substring($q + 1).Split("&")) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $kv = $pair.Split("=", 2)
        $key = [System.Uri]::UnescapeDataString($kv[0].Replace("+"," "))
        if ($key -ne $Name) { continue }
        if ($kv.Length -lt 2) { return "" }
        return [System.Uri]::UnescapeDataString($kv[1].Replace("+"," "))
    }
    return $null
}

function Get-CaptureDashToken {
    param([string]$Id)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Id)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash).Replace("-","").Substring(0,16).ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

function Refresh-CaptureDashRecordMap {
    $port = Get-CapFrameXPort
    if (-not $port) { throw "CapFrameX MCP endpoint is unavailable." }

    $records = @(Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_list_records" -Arguments @{ limit = 0 })
    $script:CaptureDashRecordMap = @{}
    $safe = @()

    foreach ($record in $records) {
        if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.id)) { continue }
        $token = Get-CaptureDashToken ([string]$record.id)
        $script:CaptureDashRecordMap[$token] = [string]$record.id
        $safe += [ordered]@{
            token = $token
            game = [string]$record.game
            processName = [string]$record.processName
            recordedAt = [string]$record.recordedAt
            durationSec = $record.durationSec
        }
    }

    return $safe
}

function Get-CaptureDashRecordsJson {
    try {
        $records = Refresh-CaptureDashRecordMap
        return ([ordered]@{
            available = $true
            message = $null
            records = $records
        } | ConvertTo-Json -Depth 6 -Compress)
    }
    catch {
        return ([ordered]@{
            available = $false
            message = $_.Exception.Message
            records = @()
        } | ConvertTo-Json -Depth 6 -Compress)
    }
}

function Resolve-CaptureDashRecordId {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    if (-not $script:CaptureDashRecordMap.ContainsKey($Token)) {
        [void](Refresh-CaptureDashRecordMap)
    }
    if ($script:CaptureDashRecordMap.ContainsKey($Token)) {
        return [string]$script:CaptureDashRecordMap[$Token]
    }
    return $null
}

function Get-CaptureDashDataJson {
    param([string]$Token)

    try {
        $id = Resolve-CaptureDashRecordId $Token
        if ([string]::IsNullOrWhiteSpace($id)) { throw "Unknown capture token." }

        $port = Get-CapFrameXPort
        if (-not $port) { throw "CapFrameX MCP endpoint is unavailable." }

        $detail = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_get_record" -Arguments @{ id = $id }

        $metrics = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_get_metrics" -Arguments @{
            id = $id
            runIndex = 0
            metrics = @("Average","P1","P0dot2","OnePercentLowAverage","ZerodotTwoPercentLowAverage")
        }

        $useDisplay = ([string]$metrics.metricSource -eq "MsBetweenDisplayChange")

        # Raw frame times are required because /dash recalculates frame metrics for
        # arbitrary user-selected time ranges in the browser.
        $frames = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_get_frametimes" -Arguments @{
            id = $id
            runIndex = 0
            downsampleHz = 0
            useDisplayChangeMetrics = $useDisplay
        }

        # SensorData2 is stored inside the CapFrameX record. We return every saved
        # channel so the user can choose what to plot/analyse after the capture.
        $sensorSeries = Invoke-CapFrameXTool -CapFrameXPort $port -Name "cfx_get_sensor_time_series" -Arguments @{
            id = $id
            runIndex = 0
            downsampleHz = 0
            maxSensors = 0
        }

        $safeFrames = @()
        foreach ($p in @($frames.points)) {
            if ($null -eq $p) { continue }
            $safeFrames += [ordered]@{
                tSec = $p.tSec
                frametimeMs = $p.frametimeMs
            }
        }

        $safeSensors = @()
        foreach ($s in @($sensorSeries.sensors)) {
            if ($null -eq $s) { continue }
            $points = @()
            foreach ($p in @($s.points)) {
                if ($null -eq $p) { continue }
                $points += [ordered]@{ tSec = $p.tSec; value = $p.value }
            }
            $safeSensors += [ordered]@{
                identifier = [string]$s.identifier
                name = [string]$s.name
                type = [string]$s.type
                points = $points
            }
        }

        return ([ordered]@{
            available = $true
            message = $null
            token = $Token
            game = [string]$detail.game
            processName = [string]$detail.processName
            recordedAt = [string]$detail.recordedAt
            durationSec = $frames.durationSec
            metricSource = [string]$metrics.metricSource
            metricSourceWarning = [string]$metrics.metricSourceWarning
            frametimes = $safeFrames
            sensors = $safeSensors
        } | ConvertTo-Json -Depth 12 -Compress)
    }
    catch {
        return ([ordered]@{
            available = $false
            message = $_.Exception.Message
        } | ConvertTo-Json -Depth 6 -Compress)
    }
}
# CAPTURE-DASH-V2-API-END
# CAPTURE-DASH-V25-BACKEND-BEGIN
function ConvertTo-CaptureDashNumber {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    try {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
        return [Math]::Round($number, 4)
    }
    catch {
        return $null
    }
}

function Invoke-CaptureDashTool {
    param(
        [int]$CapFrameXPort,
        [string]$Name,
        [hashtable]$Arguments = @{}
    )

    $response = Invoke-CapFrameXRpc -CapFrameXPort $CapFrameXPort -Method "tools/call" -Params ([ordered]@{
        name = $Name
        arguments = $Arguments
    })

    if ($null -ne $response.error) {
        throw ("CapFrameX JSON-RPC error: " + $response.error.message)
    }

    if ($response.result.isError -eq $true) {
        $message = "CapFrameX tool failed"
        try {
            if ($response.result.content.Count -gt 0) {
                $message = [string]$response.result.content[0].text
            }
        } catch {}
        throw $message
    }

    $items = @($response.result.content)
    if ($items.Count -eq 0) { return $null }

    $text = [string]$items[0].text
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try { return ($text | ConvertFrom-Json) }
    catch { return $text }
}

function Get-CaptureDashToken {
    param([string]$RecordId)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($RecordId)
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
        return $hex.Substring(0, 20)
    }
    finally {
        $sha.Dispose()
    }
}

function Get-CaptureDashRecordsInternal {
    $port = Get-CapFrameXPort
    if (-not $port) { throw "CapFrameX MCP endpoint is not available." }

    $records = @(Invoke-CaptureDashTool -CapFrameXPort $port -Name "cfx_list_records" -Arguments @{ limit = 0 })
    return [ordered]@{
        Port = $port
        Records = $records
    }
}

function Resolve-CaptureDashRecord {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { throw "Missing capture token." }

    $all = Get-CaptureDashRecordsInternal
    foreach ($record in @($all.Records)) {
        $id = [string]$record.id
        if ((Get-CaptureDashToken $id) -eq $Token) {
            return [ordered]@{ Port = $all.Port; Record = $record; Id = $id }
        }
    }

    throw "Capture token was not found."
}

function Get-CaptureDashRecordsJson {
    try {
        $all = Get-CaptureDashRecordsInternal
        $safe = @()

        foreach ($record in @($all.Records)) {
            $safe += [ordered]@{
                Token = Get-CaptureDashToken ([string]$record.id)
                Game = [string]$record.game
                ProcessName = [string]$record.processName
                RecordedAt = [string]$record.recordedAt
                DurationSec = ConvertTo-CaptureDashNumber $record.durationSec
            }
        }

        return ([ordered]@{
            Available = $true
            Message = $null
            Records = $safe
        } | ConvertTo-Json -Depth 6 -Compress)
    }
    catch {
        return ([ordered]@{
            Available = $false
            Message = $_.Exception.Message
            Records = @()
        } | ConvertTo-Json -Depth 6 -Compress)
    }
}

function Get-CaptureDashMetricValue {
    param([object]$Metrics,[string]$Name)

    $run = @($Metrics.runs) | Select-Object -First 1
    if ($null -eq $run) { return $null }
    $m = @($run.metrics) | Where-Object { [string]$_.metric -eq $Name } | Select-Object -First 1
    if ($null -eq $m) { return $null }
    return ConvertTo-CaptureDashNumber $m.value
}

function Get-CaptureDashRecordJson {
    param([string]$Token)

    try {
        $resolved = Resolve-CaptureDashRecord $Token
        $port = [int]$resolved.Port
        $id = [string]$resolved.Id

        $detail = Invoke-CaptureDashTool -CapFrameXPort $port -Name "cfx_get_record" -Arguments @{ id = $id }

        $metrics = Invoke-CaptureDashTool -CapFrameXPort $port -Name "cfx_get_metrics" -Arguments @{
            id = $id
            runIndex = 0
            metrics = @(
                "Average",
                "P1",
                "P0dot2",
                "OnePercentLowAverage",
                "ZerodotTwoPercentLowAverage"
            )
        }

        $useDisplay = ([string]$metrics.metricSource -eq "MsBetweenDisplayChange")

        # Raw frametimes are kept so arbitrary time selections can be analysed locally.
        $frames = Invoke-CaptureDashTool -CapFrameXPort $port -Name "cfx_get_frametimes" -Arguments @{
            id = $id
            runIndex = 0
            downsampleHz = 0
            useDisplayChangeMetrics = $useDisplay
        }

        # CapFrameX stores sensor samples inside the capture. This persists across browser
        # refreshes and does not depend on the old browser-side HWiNFO history.
        $sensorSeries = Invoke-CaptureDashTool -CapFrameXPort $port -Name "cfx_get_sensor_time_series" -Arguments @{
            id = $id
            runIndex = 0
            sensors = $null
            downsampleHz = 1
            maxSensors = 0
        }

        $safeFrames = @()
        foreach ($point in @($frames.points)) {
            $t = ConvertTo-CaptureDashNumber $point.tSec
            $ms = ConvertTo-CaptureDashNumber $point.frametimeMs
            if ($null -ne $t -and $null -ne $ms) {
                $safeFrames += [ordered]@{ TSec = $t; FrametimeMs = $ms }
            }
        }

        $safeSensors = @()
        foreach ($sensor in @($sensorSeries.sensors)) {
            $pts = @()
            foreach ($point in @($sensor.points)) {
                $t = ConvertTo-CaptureDashNumber $point.tSec
                $v = ConvertTo-CaptureDashNumber $point.value
                if ($null -ne $t -and $null -ne $v) {
                    $pts += [ordered]@{ TSec = $t; Value = $v }
                }
            }

            $identifier = [string]$sensor.identifier
            if ([string]::IsNullOrWhiteSpace($identifier)) {
                $identifier = [string]$sensor.name
            }

            $safeSensors += [ordered]@{
                Identifier = $identifier
                Name = [string]$sensor.name
                Type = [string]$sensor.type
                Points = $pts
            }
        }

        $duration = ConvertTo-CaptureDashNumber $detail.durationSec
        if ($null -eq $duration) { $duration = ConvertTo-CaptureDashNumber $frames.durationSec }

        return ([ordered]@{
            Available = $true
            Message = $null
            Token = $Token
            Game = [string]$detail.game
            ProcessName = [string]$detail.processName
            RecordedAt = [string]$detail.recordedAt
            DurationSec = $duration
            FrameCount = [int]$frames.frameCount
            MetricSource = [string]$metrics.metricSource
            MetricSourceWarning = [string]$metrics.metricSourceWarning
            Metrics = [ordered]@{
                Average = Get-CaptureDashMetricValue $metrics "Average"
                P1 = Get-CaptureDashMetricValue $metrics "P1"
                P0dot2 = Get-CaptureDashMetricValue $metrics "P0dot2"
                OnePercentLowAverage = Get-CaptureDashMetricValue $metrics "OnePercentLowAverage"
                ZerodotTwoPercentLowAverage = Get-CaptureDashMetricValue $metrics "ZerodotTwoPercentLowAverage"
            }
            Frametimes = $safeFrames
            Sensors = $safeSensors
        } | ConvertTo-Json -Depth 10 -Compress)
    }
    catch {
        return ([ordered]@{
            Available = $false
            Message = $_.Exception.Message
        } | ConvertTo-Json -Depth 5 -Compress)
    }
}

function Get-CaptureDashQueryValue {
    param([string]$RequestTarget,[string]$Name)

    if ([string]::IsNullOrWhiteSpace($RequestTarget)) { return $null }
    $q = $RequestTarget.IndexOf("?")
    if ($q -lt 0 -or $q -ge ($RequestTarget.Length - 1)) { return $null }

    $query = $RequestTarget.Substring($q + 1)
    foreach ($part in $query.Split("&")) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $kv = $part.Split("=", 2)
        $key = [System.Uri]::UnescapeDataString($kv[0].Replace("+", " "))
        if ($key -ne $Name) { continue }

        if ($kv.Length -lt 2) { return "" }
        return [System.Uri]::UnescapeDataString($kv[1].Replace("+", " "))
    }

    return $null
}
# CAPTURE-DASH-V25-BACKEND-END

function Get-CapFrameXJson {
    return ((Get-CapFrameXApiObject) | ConvertTo-Json -Depth 10 -Compress)
}


# CAPTURE-DASH-V3-HWINFO-BEGIN
$script:HwHistorySeries = @{}
$script:HwHistoryTokenMap = @{}
$script:HwHistoryLastSample = [DateTime]::MinValue
$script:HwHistoryStartedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$script:HwHistorySampleIntervalMs = 1000
$script:HwHistoryMaxPoints = 2100

function Get-HwHistoryToken {
    param([string]$Key)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash).Replace("-","").Substring(0,16).ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

function Update-HwInfoHistory {
    $elapsed = ([DateTime]::UtcNow - $script:HwHistoryLastSample).TotalMilliseconds
    if ($elapsed -lt $script:HwHistorySampleIntervalMs) { return }

    $script:HwHistoryLastSample = [DateTime]::UtcNow

    try {
        $snap = [HwInfoWeb.Reader]::Read()
        if (-not $snap.Ok) { return }

        $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()

        foreach ($r in @($snap.Readings)) {
            if ($null -eq $r.Value) { continue }

            $value = 0.0
            try { $value = [double]$r.Value }
            catch { continue }

            if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { continue }

            $key = "{0}:{1}" -f $r.SensorIndex, $r.ReadingId

            if (-not $script:HwHistorySeries.ContainsKey($key)) {
                $token = Get-HwHistoryToken $key

                $series = [pscustomobject]@{
                    Key = $key
                    Token = $token
                    Sensor = [string]$r.Sensor
                    Label = [string]$r.Label
                    Unit = [string]$r.Unit
                    Points = New-Object 'System.Collections.Generic.List[object]'
                }

                $script:HwHistorySeries[$key] = $series
                $script:HwHistoryTokenMap[$token] = $key
            }

            $s = $script:HwHistorySeries[$key]
            $s.Sensor = [string]$r.Sensor
            $s.Label = [string]$r.Label
            $s.Unit = [string]$r.Unit
            $s.Points.Add([pscustomobject]@{ T = $nowMs; Value = [Math]::Round($value, 5) })

            if ($s.Points.Count -gt $script:HwHistoryMaxPoints) {
                $removeCount = [Math]::Min(100, $s.Points.Count - $script:HwHistoryMaxPoints)
                if ($removeCount -gt 0) { $s.Points.RemoveRange(0, $removeCount) }
            }
        }
    }
    catch {
        # History capture must never stop the diagnostic server.
    }
}

function Get-HwHistoryCatalogJson {
    Update-HwInfoHistory

    $metrics = @()
    foreach ($key in @($script:HwHistorySeries.Keys)) {
        $s = $script:HwHistorySeries[$key]
        $metrics += [ordered]@{
            token = $s.Token
            sensor = $s.Sensor
            label = $s.Label
            unit = $s.Unit
            sampleCount = $s.Points.Count
        }
    }

    $metrics = @($metrics | Sort-Object sensor, label)

    $historySeconds = [Math]::Round(
        ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $script:HwHistoryStartedAt) / 1000.0,
        0
    )

    return ([ordered]@{
        available = $true
        message = $null
        historySeconds = $historySeconds
        metrics = $metrics
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Get-HwHistorySeriesJson {
    param(
        [string]$Token,
        [long]$FromMs,
        [long]$ToMs
    )

    Update-HwInfoHistory

    if ([string]::IsNullOrWhiteSpace($Token) -or -not $script:HwHistoryTokenMap.ContainsKey($Token)) {
        return ([ordered]@{
            available = $false
            message = "Unknown HWiNFO metric token."
            points = @()
        } | ConvertTo-Json -Depth 5 -Compress)
    }

    $key = $script:HwHistoryTokenMap[$Token]
    $s = $script:HwHistorySeries[$key]
    $points = @()

    foreach ($p in @($s.Points)) {
        if ($FromMs -gt 0 -and $p.T -lt $FromMs) { continue }
        if ($ToMs -gt 0 -and $p.T -gt $ToMs) { continue }

        $points += [ordered]@{
            t = [long]$p.T
            value = $p.Value
        }
    }

    return ([ordered]@{
        available = $true
        message = $null
        token = $Token
        sensor = $s.Sensor
        label = $s.Label
        unit = $s.Unit
        points = $points
    } | ConvertTo-Json -Depth 6 -Compress)
}
# CAPTURE-DASH-V3-HWINFO-END

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
    Write-Host "powershell -ExecutionPolicy Bypass -File .\hwinfo-performance-lab.ps1 -Port 8081"
    exit 1
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor DarkGray
Write-Host " Win Stat Server v8.0" -ForegroundColor Green
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
        Update-HwInfoHistory
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 50
            continue
        }
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
            $stream.ReadTimeout = 5000
            $stream.WriteTimeout = 5000
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
            $requestTarget = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
            $path = $requestTarget.Split('?')[0]

            switch ($path) {
                "/api/capture/records" {
                    Send-Response $stream 200 "application/json" (Get-CaptureDashRecordsJson)
                }
                "/api/capture/record" {
                    $captureToken = Get-CaptureDashQueryValue -RequestTarget $requestTarget -Name "token"
                    Send-Response $stream 200 "application/json" (Get-CaptureDashRecordJson $captureToken)
                }

                "/" {
                    Send-Response $stream 200 "text/html" $html
                }
                "/index.html" {
                    Send-Response $stream 200 "text/html" $html
                }
                "/dash" {
                    Send-Response $stream 200 "text/html" $captureDashHtml
                }
                "/dash/" {
                    Send-Response $stream 200 "text/html" $captureDashHtml
                }
                "/api/capframex/live" {
                    Send-Response $stream 200 "application/json" (Get-CapFrameXLiveJson)
                }
                "/api/capframex/records" {
                    Send-Response $stream 200 "application/json" (Get-CaptureDashRecordsJson)
                }
                "/api/capframex/capture" {
                    $token = Get-RequestQueryValue $requestTarget "token"
                    Send-Response $stream 200 "application/json" (Get-CaptureDashDataJson $token)
                }                "/api/hwinfo/history/catalog" {
                    Send-Response $stream 200 "application/json" (Get-HwHistoryCatalogJson)
                }
                "/api/hwinfo/history" {
                    $hwToken = Get-RequestQueryValue $requestTarget "token"
                    $hwFromText = Get-RequestQueryValue $requestTarget "from"
                    $hwToText = Get-RequestQueryValue $requestTarget "to"

                    $hwFrom = 0L
                    $hwTo = 0L
                    [void][long]::TryParse([string]$hwFromText, [ref]$hwFrom)
                    [void][long]::TryParse([string]$hwToText, [ref]$hwTo)

                    Send-Response $stream 200 "application/json" (Get-HwHistorySeriesJson $hwToken $hwFrom $hwTo)
                }                "/api/sensors" {
                    Send-Response $stream 200 "application/json" (Get-SnapshotJson)
                }
                "/api/capframex" {
                    Send-Response $stream 200 "application/json" (Get-CapFrameXJson)
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
