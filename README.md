HWiNFO ALL-SENSORS WEB BRIDGE v2
=================================

WHAT CHANGED
------------
This version does NOT use the HWiNFO Gadget / VSB registry interface.

It reads HWiNFO Shared Memory directly, which means it can display every
live reading HWiNFO publishes without manually checking "Report value in Gadget".

You get:
- Every HWiNFO sensor group
- Every live reading
- Current value
- Minimum
- Maximum
- Average
- PresentMon readings such as FPS / frame time when HWiNFO exposes them
- Search/filter in the browser
- JSON endpoint at /api/sensors

SETUP
-----
1. Start HWiNFO64.

2. Make sure the Sensors window is open.
   Sensors-only mode is perfect.

3. Enable:
   HWiNFO Settings -> Shared Memory Support

   You do NOT need to configure "HWiNFO Gadget".
   You do NOT need Remote Sensor Monitor.
   You do NOT need OpenHardwareMonitorLib.dll.

4. Double-click:
   START-HWINFO-ALL.bat

5. Test locally:
   http://127.0.0.1:8080/

6. To expose it temporarily to the Internet:
   tmole.exe 8080

   Open the HTTPS Tunnelmole URL from the remote computer.

FPS
---
If PresentMon/FPS exists in the HWiNFO Sensors window while the game is running,
this dashboard receives it automatically because it reads all HWiNFO shared-memory
readings.

Do not rely on the GPU driver's "Full Screen FPS = -1" value.

TROUBLESHOOTING
---------------
If the dashboard says the shared memory mapping does not exist:

- Open the HWiNFO Sensors window.
- Enable "Shared Memory Support".
- If HWiNFO is running as Administrator, try running this bridge as Administrator too.
  Matching privilege level can matter for access to the Global shared-memory object.

If port 8080 is already occupied:
  powershell -ExecutionPolicy Bypass -File .\hwinfo-all-web.ps1 -Port 8081

Then:
  tmole.exe 8081

SECURITY
--------
The bridge itself listens only on 127.0.0.1.
Tunnelmole makes it reachable through its temporary public URL while tmole is running.
Stop tmole when the troubleshooting session is over.
