# Camera Internet

A small Windows utility that switches **Internet Connection Sharing (ICS)** on and off
with one button, so that IP cameras at a site without Internet can be reached through a
phone hotspot.

```
phone mobile data
   -> phone Wi-Fi hotspot
      -> Windows PC Wi-Fi adapter            (ICS public interface)
         -> [ Windows ICS / NAT + DHCP ]
            -> Windows PC Ethernet adapter   (ICS private interface)
               -> network switch
                  -> IP cameras
```

The utility uses the Windows ICS COM interface (`HNetCfg.HNetShare`). It does **not**
bridge Wi-Fi and Ethernet: bridging puts the cameras on the hotspot's own subnet, while
ICS gives the camera side its own NAT, DHCP server and DNS proxy, which is what the
cameras need.

## Files

| File | Purpose |
| --- | --- |
| `CameraInternet.ps1` | The application (Windows PowerShell + WinForms). |
| `Start-CameraInternet.cmd` | Launcher that starts the GUI with a hidden console. |
| `Install-CameraInternet.ps1` | Optional: creates a "Camera Internet" desktop shortcut. |
| `README.md` | This file. |

Nothing has to be installed: Windows 10 and Windows 11 already contain everything
(Windows PowerShell 5.1, .NET Framework, Windows Forms, ICS).

## Installation

1. Copy the whole folder anywhere on the PC, for example `C:\Tools\CameraInternet`.
2. Optional, but recommended - create the desktop shortcut:

   ```
   powershell -ExecutionPolicy Bypass -File .\Install-CameraInternet.ps1
   ```

   This creates a shortcut called **Camera Internet** on the desktop, with a generated
   camera/network icon and the "run as administrator" flag set. Add `-StartMenu` to also
   put it in the Start menu, or run the installer with `-Uninstall` to remove the
   shortcuts again.

3. Without the installer, start the program with `Start-CameraInternet.cmd`.

## Operation

The window is about 300 x 220 pixels and contains one large button:

| Colour | Button text | Meaning |
| --- | --- | --- |
| **RED** | `INTERNET OFF` | Sharing is switched off. Click to switch it on. |
| **GREEN** | `INTERNET ON` | Sharing is active, the Wi-Fi side has Internet and the camera side has an address. Click to switch it off. |
| **ORANGE** | `CHECK CONNECTION` | Sharing is on but something is wrong (no Internet on Wi-Fi, Ethernet cable unplugged, adapter gone, only half configured, ICS unavailable). The line under the button says what. |

Below the button:

```
Wi-Fi  ->  Ethernet          the detected / selected adapter pair

Public:      Wi-Fi           the Internet-facing adapter (ICS type 0)
Private:     Ethernet        the camera LAN adapter      (ICS type 1)
LAN:         192.168.137.1   the address Windows actually gave the camera adapter
Internet:    Connected       the Internet state of the public adapter itself
```

The `LAN:` line shows what Windows really assigned. ICS normally uses
`192.168.137.1/24`, but the value is read from the adapter, never assumed.

While the window is open the real ICS configuration is re-read every 2.5 seconds, so the
button follows reality: if someone switches sharing off in the network connections
dialog, the button turns red by itself. The timer only *reads* - it never switches
sharing on or off because connectivity changed.

### Settings (adapter selection)

`Settings` opens two drop-down lists with all Windows network adapters:

* **Internet adapter** - the Wi-Fi adapter connected to the phone hotspot (public side).
* **Camera LAN adapter** - the Ethernet adapter that goes to the camera switch (private side).

The choice is stored in `%LOCALAPPDATA%\CameraInternet\config.json` and is used again on
the next start. The same adapter cannot be chosen for both sides. `Auto-detect` fills the
lists with the automatic choice again.

Without a saved configuration the program detects the adapters itself:

* public: an active Wi-Fi adapter, preferring one that actually has Internet / a default
  gateway;
* private: an active physical Ethernet adapter (a disconnected one is accepted if there
  is no better candidate).

VPN, Hyper-V, VMware, VirtualBox, WSL, Bluetooth, TAP/tunnel and other virtual adapters
are never picked automatically. They can still be selected by hand in Settings.

## What happens when you switch sharing on

1. Both selected adapters are looked up in the ICS connection list.
2. They are checked for being two different adapters.
3. The existing sharing configuration is read.
4. A conflicting configuration (sharing on other adapters, or the wrong side) is switched off.
5. The Wi-Fi adapter is configured as the ICS **public** interface (sharing type `0`).
6. The Ethernet adapter is configured as the ICS **private** interface (sharing type `1`).
7. The program waits a few seconds for Windows to give the Ethernet adapter its address.
8. The ICS and network configuration is read back.
9. The button and the status lines are updated from that real result.

Switching off disables sharing on the two selected adapters and then verifies the result.
Sharing that belongs to other adapters is reported but left alone.

Nothing else is touched: no routes, DNS settings, firewall rules, VPN configuration or
adapter properties are changed. The only exception is the Windows service *Internet
Connection Sharing (ICS)* - if it is set to `Disabled`, the program asks first before
setting it to `Manual`, because ICS cannot work otherwise.

## Administrator rights

Changing the ICS configuration requires administrator rights. When the script is started
as a normal user it restarts itself through `RunAs`, which triggers the normal UAC
prompt. If the prompt is cancelled, the program explains this and closes instead of
failing later with a COM error.

The desktop shortcut created by the installer already carries the "run as administrator"
flag, so the prompt appears immediately at start.

## Logging

Technical errors, ICS operations and adapter detection results are written to:

```
%LOCALAPPDATA%\CameraInternet\CameraInternet.log
```

The file is rotated at 512 KB (the previous file becomes `CameraInternet.log.1`). The GUI
only shows plain-language messages; stack traces stay in the log.

## Testing it safely before the cameras are connected

Do this once on the workbench, with the cameras and the switch disconnected:

1. Connect the PC's Wi-Fi to the phone hotspot and check that normal browsing works.
2. Plug a **short Ethernet cable into any switch or into a spare laptop** - the Ethernet
   adapter must not be connected to the customer network during the test.
3. Start `Start-CameraInternet.cmd` and confirm the UAC prompt.
4. The button should be **red** with `INTERNET OFF`, and the line under it should show
   `Wi-Fi -> Ethernet`. If the wrong adapters are shown, fix them in `Settings`.
5. Click the button. After a few seconds it should turn **green** with `INTERNET ON` and
   the `LAN:` line should show an address, normally `192.168.137.1`.
6. Verify from Windows itself:

   ```
   ipconfig /all                 (the Ethernet adapter should have 192.168.137.1)
   Get-NetIPAddress -InterfaceAlias Ethernet -AddressFamily IPv4
   ```

   In *Network Connections* (`ncpa.cpl`) the Wi-Fi adapter should say "Shared".
7. Connect a laptop or a single camera to the Ethernet port. It should get an address in
   the `192.168.137.x` range automatically and be able to reach the Internet.
8. Click the button again - it must turn **red**, and the Ethernet adapter loses the
   `192.168.137.1` address.
9. To check the monitoring: with the button green, open `ncpa.cpl`, switch sharing off in
   the Wi-Fi adapter properties, and watch the button turn red by itself within about
   three seconds.

Only after that, connect the camera switch.

> **Note about fixed camera addresses.** ICS always uses `192.168.137.1/24` for the
> private side and this cannot be changed in the ICS user interface. Cameras with a fixed
> address outside that subnet will not be reachable until they are set to DHCP or to an
> address in `192.168.137.x` with gateway `192.168.137.1`.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Button stays **orange** with "No Internet on Wi-Fi" | The phone hotspot is down or has no mobile data. Reconnect the Wi-Fi; the button turns green on its own. |
| Button orange with "Ethernet cable disconnected" | Check the cable and the switch. ICS stays configured; the button turns green once the link is up. |
| Button orange with "Sharing is only half configured" | Another program (VPN client, mobile hotspot tool) changed the sharing. Click the button to let the utility reconfigure both sides. |
| Button orange with "Sharing active on: ..." | ICS is enabled for a different adapter pair. Click the button to move sharing to the selected adapters, or choose those adapters in Settings. |
| "ICS service disabled" message | Answer *Yes* when asked to set the service to Manual, or enable *Internet Connection Sharing (ICS)* in `services.msc`. |
| "Windows did not switch Internet sharing on" | Look at the log file. The usual causes are a disconnected hotspot, a disabled Ethernet adapter, or a third-party hotspot/VPN driver holding the ICS configuration. |
| "Adapter not found / renamed" | Adapters are remembered by name. If Windows renamed one (`Ethernet` -> `Ethernet 2`), select it again in Settings. |
| Nothing happens when starting | The UAC prompt was cancelled, or PowerShell script execution is blocked by policy. Use `Start-CameraInternet.cmd`, which sets `-ExecutionPolicy Bypass` for that one process only. |
| Cameras get no address | Check that the cameras use DHCP, and that no second DHCP server (a router on the same switch) is connected to the camera network. |
| Sharing survives a reboot | This is normal Windows behaviour: ICS is persistent. Start the utility and click the green button to switch it off. |

## Notes

* Windows allows only **one** ICS public connection at a time. Enabling sharing therefore
  switches off any other sharing configuration first.
* ICS keeps its settings over reboots, and the private adapter keeps `192.168.137.1`
  until sharing is switched off.
* Tested against Windows PowerShell 5.1 on Windows 10 and Windows 11.
