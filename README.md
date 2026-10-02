HWiNFO WEB BRIDGE

1) Start HWiNFO64 in Sensors-only mode.

2) In the Sensors window:
   Configure (gear) -> HWiNFO Gadget

3) Enable "Report value in Gadget" for the values you want remotely.
   Recommended:
   - PresentMon -> Framerate Presented (avg)
   - PresentMon -> Frame Time
   - PresentMon -> GPU Busy (if available)
   - Total CPU Usage
   - CPU (Tctl/Tdie) or CPU Package temperature
   - CPU Package Power
   - Core Clocks / Effective Clock
   - GPU Core Load
   - GPU Temperature
   - GPU Power
   - GPU Clock
   - GPU Memory Allocated / Used
   - Physical Memory Load / Used

4) Double-click START-HWINFO-WEB.bat

5) Open locally:
   http://127.0.0.1:8080/

6) In another terminal run:
   tmole.exe 8080

7) Send/open the HTTPS tunnel URL.

Troubleshooting:
- If the page says VSB registry key not found, HWiNFO is not publishing any Gadget values.
- Verify with:
  reg query HKCU\Software\HWiNFO64\VSB
- If FPS is missing, make sure the GAME IS RUNNING and select the PresentMon
  "Framerate Presented (avg)" sensor, not the GPU driver's "Full Screen FPS".
