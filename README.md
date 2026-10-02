HWiNFO ALL-SENSORS WEB BRIDGE v2.1
===================================

FIX IN v2.1
-----------
The web listener is now dual-stack so both forms of Windows localhost work:
- 127.0.0.1 (IPv4)
- ::1       (IPv6)

This matters because Tunnelmole forwards to localhost:<port>, and Windows/Node
may resolve localhost to IPv6.

For safety, even though the socket is dual-stack, the bridge rejects requests
whose source address is not loopback. It is therefore not intended to be
directly exposed to your LAN. Tunnelmole remains the public-facing layer.

QUICK TEST
----------
1. Start HWiNFO Sensors and enable Shared Memory Support.
2. Run START-HWINFO-ALL.bat
3. In PowerShell test all three:

   Invoke-WebRequest http://127.0.0.1:8080/ -UseBasicParsing
   Invoke-WebRequest http://localhost:8080/ -UseBasicParsing
   Invoke-WebRequest http://[::1]:8080/ -UseBasicParsing

All should return StatusCode 200.

4. Run:
   tmole.exe 8080

5. Open the generated HTTPS URL.

If the first local URLs work but the Tunnelmole URL does not, copy the exact
tmole.exe console output and HTTP error shown in the browser.
