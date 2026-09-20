<#
.SYNOPSIS
    Camera Internet - a small GUI utility that toggles Windows Internet
    Connection Sharing (ICS) between a Wi-Fi (phone hotspot) adapter and an
    Ethernet adapter that feeds a camera switch.

.DESCRIPTION
    Typical field setup:

        Phone mobile data -> phone Wi-Fi hotspot -> PC Wi-Fi adapter
        -> [ Windows ICS / NAT ] -> PC Ethernet adapter -> switch -> IP cameras

    The utility uses the Windows ICS COM interface (HNetCfg.HNetShare). It does
    NOT create a network bridge: Windows ICS gives the private side its own
    DHCP server, DNS proxy and NAT, which is what the cameras need.

    Requires administrator rights; the script re-launches itself elevated when
    started as a normal user.

.PARAMETER KeepConsole
    Keep the PowerShell console window visible (useful for troubleshooting).

.PARAMETER NoElevate
    Do not attempt to re-launch elevated. The GUI still starts, but any attempt
    to change the ICS configuration will fail with an explanatory message.

.NOTES
    Tested against Windows PowerShell 5.1 on Windows 10 / Windows 11.
    Log file: %LOCALAPPDATA%\CameraInternet\CameraInternet.log
#>
[CmdletBinding()]
param(
    [switch]$KeepConsole,
    [switch]$NoElevate,
    [string]$ExportIcon
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

$script:AppName    = 'Camera Internet'
# Captured here at script scope: inside a function $MyInvocation would describe
# the function call instead of how this script itself was started.
$script:ScriptPath     = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Definition }
$script:InvocationLine = [string]$MyInvocation.Line
$script:AppDir     = Join-Path $env:LOCALAPPDATA 'CameraInternet'
$script:LogFile    = Join-Path $script:AppDir 'CameraInternet.log'
$script:ConfigFile = Join-Path $script:AppDir 'config.json'
$script:MaxLogBytes = 512KB

# ICS sharing types as defined by SHARINGCONNECTIONTYPE (netcon.h).
#   ICSSHARINGTYPE_PUBLIC  = 0 -> the connection that reaches the Internet
#   ICSSHARINGTYPE_PRIVATE = 1 -> the connection that is being shared to
$script:IcsPublic  = 0
$script:IcsPrivate = 1

# Interfaces that must never be picked automatically: VPN, hypervisor, WSL,
# tunnelling and other virtual adapters. (A manual selection is still honoured.)
$script:VirtualAdapterPattern = 'Hyper-V|Virtual|VMware|VMnet|VirtualBox|VBox|TAP-|TUN|Loopback|WSL|Npcap|Bluetooth|VPN|WAN Miniport|Wintun|ZeroTier|Tailscale|Docker|Parallels|OpenVPN|Fortinet|AnyConnect|Juniper|SoftEther|Hamachi|Teredo|ISATAP|6to4|Kernel Debug|RAS Async|Packet Scheduler|Wi-Fi Direct'

$script:UiColorOff    = [System.Drawing.Color]::FromArgb(192, 44, 44)    # RED
$script:UiColorOn     = [System.Drawing.Color]::FromArgb(33, 145, 60)    # GREEN
$script:UiColorWarn   = [System.Drawing.Color]::FromArgb(224, 142, 12)   # ORANGE

# Runtime state
$script:Busy              = $false
$script:PendingAction     = 'Enable'
$script:IsElevated        = $false
$script:LastProbeTime     = [DateTime]::MinValue
$script:LastProbeResult   = $null

# --------------------------------------------------------------------------
# Logging / small helpers
# --------------------------------------------------------------------------

function Initialize-AppFolder {
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) {
            New-Item -Path $script:AppDir -ItemType Directory -Force | Out-Null
        }
    } catch {
        # Nothing we can do - logging simply becomes a no-op.
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    try {
        Initialize-AppFolder
        if (Test-Path -LiteralPath $script:LogFile) {
            $item = Get-Item -LiteralPath $script:LogFile
            if ($item.Length -gt $script:MaxLogBytes) {
                $old = "$($script:LogFile).1"
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $script:LogFile -Destination $old -Force -ErrorAction SilentlyContinue
            }
        }
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Logging must never break the application.
    }
}

function Write-LogException {
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [string]$Context = ''
    )
    $text = "$Context :: $($ErrorRecord.Exception.GetType().FullName): $($ErrorRecord.Exception.Message)"
    Write-Log -Level ERROR -Message $text
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Log -Level ERROR -Message ("  stack: " + ($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' | '))
    }
}

function Show-Info {
    param([string]$Message, [string]$Title = $script:AppName)
    [void][System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Show-Warning {
    param([string]$Message, [string]$Title = $script:AppName)
    [void][System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
}

function Show-ErrorMessage {
    param([string]$Message, [string]$Title = $script:AppName)
    $full = $Message + "`r`n`r`nTechnical details are written to:`r`n" + $script:LogFile
    [void][System.Windows.Forms.MessageBox]::Show($full, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
}

function Confirm-Question {
    param([string]$Message, [string]$Title = $script:AppName)
    $answer = [System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Remove-ComObjectRef {
    # Releases a single COM reference; safe to call with $null.
    param($ComObject)
    if ($null -eq $ComObject) { return }
    try {
        if ([System.Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ComObject)
        }
    } catch {
        # Ignore - the GC finalizer will deal with it.
    }
}

# --------------------------------------------------------------------------
# Elevation (the ICS COM API requires administrator rights)
# --------------------------------------------------------------------------

function Test-Administrator {
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-HostExecutable {
    try {
        $path = (Get-Process -Id $PID).Path
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    } catch {
        # fall through
    }
    $fallback = Join-Path $PSHOME 'powershell.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return 'powershell.exe'
}

function Invoke-SelfElevation {
    <#
        Restarts this script through ShellExecute "RunAs" so that Windows shows
        the UAC prompt. Returns $true when a new elevated process was started.
    #>
    $scriptPath = $script:ScriptPath
    if (-not $scriptPath) {
        Write-Log -Level ERROR -Message 'Cannot determine own script path; elevation not possible.'
        return $false
    }

    $argList = @(
        '-NoLogo', '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $scriptPath)
    )
    if ($KeepConsole) { $argList += '-KeepConsole' }

    Write-Log -Message 'Not running as administrator - requesting elevation via RunAs.'
    try {
        Start-Process -FilePath (Get-HostExecutable) -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
        return $true
    } catch {
        # ERROR_CANCELLED (1223) = the user dismissed the UAC prompt.
        Write-LogException -ErrorRecord $_ -Context 'Elevation'
        Show-Warning -Message ("$script:AppName needs administrator rights to change Internet Connection Sharing." + "`r`n`r`n" +
            'The elevation prompt was cancelled or blocked, so the program will now close.' + "`r`n`r`n" +
            'Right-click the shortcut and choose "Run as administrator" to try again.')
        return $false
    }
}

# --------------------------------------------------------------------------
# Configuration persistence
# --------------------------------------------------------------------------

function Get-AppConfig {
    $config = [pscustomobject]@{
        PublicAdapter  = $null
        PrivateAdapter = $null
    }
    try {
        if (Test-Path -LiteralPath $script:ConfigFile) {
            $raw = Get-Content -LiteralPath $script:ConfigFile -Raw -ErrorAction Stop
            if ($raw -and $raw.Trim()) {
                $data = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($data.PSObject.Properties.Name -contains 'PublicAdapter')  { $config.PublicAdapter  = [string]$data.PublicAdapter }
                if ($data.PSObject.Properties.Name -contains 'PrivateAdapter') { $config.PrivateAdapter = [string]$data.PrivateAdapter }
                if ([string]::IsNullOrWhiteSpace($config.PublicAdapter))  { $config.PublicAdapter  = $null }
                if ([string]::IsNullOrWhiteSpace($config.PrivateAdapter)) { $config.PrivateAdapter = $null }
            }
        }
    } catch {
        Write-LogException -ErrorRecord $_ -Context 'Get-AppConfig'
    }
    return $config
}

function Save-AppConfig {
    param(
        [string]$PublicAdapter,
        [string]$PrivateAdapter
    )
    try {
        Initialize-AppFolder
        $data = [pscustomobject]@{
            PublicAdapter  = $PublicAdapter
            PrivateAdapter = $PrivateAdapter
            SavedAt        = (Get-Date).ToString('s')
        }
        ($data | ConvertTo-Json) | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8 -ErrorAction Stop
        Write-Log -Message ("Saved adapter selection: public='{0}' private='{1}'" -f $PublicAdapter, $PrivateAdapter)
        return $true
    } catch {
        Write-LogException -ErrorRecord $_ -Context 'Save-AppConfig'
        Show-ErrorMessage -Message "The adapter selection could not be saved to:`r`n$script:ConfigFile"
        return $false
    }
}

# --------------------------------------------------------------------------
# Adapter inventory and automatic detection
# --------------------------------------------------------------------------

function Test-VirtualAdapter {
    param([string]$Name, [string]$Description, $HardwareInterface)
    if ($HardwareInterface -is [bool] -and -not $HardwareInterface) { return $true }
    $text = "$Name $Description"
    return ($text -match $script:VirtualAdapterPattern)
}

function Get-AdapterInventory {
    <#
        Returns one object per network adapter with the properties the rest of
        the application needs. Falls back to the ICS COM enumeration when the
        NetAdapter cmdlets are unavailable.
    #>
    $list = New-Object System.Collections.ArrayList

    $haveCmdlet = $null -ne (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)
    if ($haveCmdlet) {
        try {
            foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop)) {
                $desc  = [string]$adapter.InterfaceDescription
                $media = [string]$adapter.PhysicalMediaType
                $isVirtual  = Test-VirtualAdapter -Name $adapter.Name -Description $desc -HardwareInterface $adapter.HardwareInterface
                $isWireless = ($media -match '802\.11|Wireless') -or
                              ($adapter.NdisPhysicalMedium -eq 9) -or
                              ($desc -match 'Wi-?Fi|Wireless|WLAN')
                $isEthernet = (-not $isWireless) -and (-not $isVirtual) -and
                              (($media -match '802\.3') -or ($adapter.InterfaceType -eq 6) -or ($desc -match 'Ethernet|GBE|LAN'))

                [void]$list.Add([pscustomobject]@{
                    Name           = [string]$adapter.Name
                    Description    = $desc
                    Status         = [string]$adapter.Status
                    InterfaceIndex = [int]$adapter.ifIndex
                    IsWireless     = [bool]$isWireless
                    IsEthernet     = [bool]$isEthernet
                    IsVirtual      = [bool]$isVirtual
                    Source         = 'NetAdapter'
                })
            }
        } catch {
            Write-LogException -ErrorRecord $_ -Context 'Get-AdapterInventory (Get-NetAdapter)'
        }
    }

    if ($list.Count -eq 0) {
        # Fallback: the ICS COM enumeration always knows the connection names.
        $snapshot = Get-IcsSnapshot
        foreach ($connection in $snapshot.Connections) {
            [void]$list.Add([pscustomobject]@{
                Name           = $connection.Name
                Description    = $connection.DeviceName
                Status         = $(if ($connection.Connected) { 'Up' } else { 'Disconnected' })
                InterfaceIndex = 0
                IsWireless     = ($connection.DeviceName -match 'Wi-?Fi|Wireless|WLAN') -or ($connection.Name -match 'Wi-?Fi|WLAN')
                IsEthernet     = ($connection.DeviceName -match 'Ethernet|GBE|LAN') -or ($connection.Name -match 'Ethernet|LAN')
                IsVirtual      = (Test-VirtualAdapter -Name $connection.Name -Description $connection.DeviceName -HardwareInterface $null)
                Source         = 'ICS'
            })
        }
    }

    return @($list)
}

function Get-AdapterByName {
    param($Inventory, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    foreach ($adapter in $Inventory) {
        if ($adapter.Name -eq $Name) { return $adapter }
    }
    return $null
}

function Test-AdapterHasDefaultGateway {
    param($Adapter)
    if ($null -eq $Adapter -or $Adapter.InterfaceIndex -le 0) { return $false }
    try {
        if ($null -eq (Get-Command -Name Get-NetRoute -ErrorAction SilentlyContinue)) { return $false }
        $routes = @(Get-NetRoute -InterfaceIndex $Adapter.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
        return ($routes.Count -gt 0)
    } catch {
        return $false
    }
}

function Find-PublicAdapter {
    <#
        Preferred public (Internet facing) interface: an active Wi-Fi adapter
        that actually has Internet connectivity / a default gateway.
    #>
    param($Inventory, [string]$ExcludeName)

    $candidates = @($Inventory | Where-Object {
        -not $_.IsVirtual -and $_.Name -ne $ExcludeName -and $_.Status -ne 'Not Present'
    })
    if ($candidates.Count -eq 0) { return $null }

    $wireless = @($candidates | Where-Object { $_.IsWireless })
    $ordered  = @()
    $ordered += @($wireless | Where-Object { $_.Status -eq 'Up' -and (Get-InternetStatus -Adapter $_).HasInternet })
    $ordered += @($wireless | Where-Object { $_.Status -eq 'Up' -and (Test-AdapterHasDefaultGateway -Adapter $_) })
    $ordered += @($wireless | Where-Object { $_.Status -eq 'Up' })
    $ordered += @($wireless)
    # No usable Wi-Fi at all: accept any other physical adapter with a gateway.
    $ordered += @($candidates | Where-Object { $_.Status -eq 'Up' -and (Test-AdapterHasDefaultGateway -Adapter $_) })

    foreach ($candidate in $ordered) {
        if ($candidate) { return $candidate }
    }
    return $null
}

function Find-PrivateAdapter {
    <#
        Preferred private (camera LAN) interface: a physical Ethernet adapter
        that is not the public interface.
    #>
    param($Inventory, [string]$ExcludeName)

    $candidates = @($Inventory | Where-Object {
        -not $_.IsVirtual -and -not $_.IsWireless -and $_.Name -ne $ExcludeName -and $_.Status -ne 'Not Present'
    })
    if ($candidates.Count -eq 0) { return $null }

    $ethernet = @($candidates | Where-Object { $_.IsEthernet })
    $ordered  = @()
    $ordered += @($ethernet | Where-Object { $_.Status -eq 'Up' })
    $ordered += @($ethernet | Where-Object { $_.Status -eq 'Disconnected' })
    $ordered += @($ethernet)
    $ordered += @($candidates | Where-Object { $_.Status -eq 'Up' })

    foreach ($candidate in $ordered) {
        if ($candidate) { return $candidate }
    }
    return $null
}

# --------------------------------------------------------------------------
# IP address / Internet connectivity of an interface
# --------------------------------------------------------------------------

function Get-AdapterIPv4 {
    <#
        Returns the IPv4 address currently assigned to an adapter. ICS usually
        gives the private interface 192.168.137.1, but that is never assumed -
        whatever Windows assigned is read back and displayed.
    #>
    param($Adapter)
    $result = [pscustomobject]@{ Address = $null; IsApipa = $false }
    if ($null -eq $Adapter) { return $result }

    $addresses = @()
    try {
        if ($null -ne (Get-Command -Name Get-NetIPAddress -ErrorAction SilentlyContinue)) {
            $query = $null
            if ($Adapter.InterfaceIndex -gt 0) {
                $query = Get-NetIPAddress -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            } else {
                $query = Get-NetIPAddress -InterfaceAlias $Adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
            }
            $addresses = @($query | Select-Object -ExpandProperty IPAddress -ErrorAction SilentlyContinue)
        }
    } catch {
        Write-LogException -ErrorRecord $_ -Context 'Get-AdapterIPv4 (Get-NetIPAddress)'
    }

    if ($addresses.Count -eq 0) {
        # Fallback for hosts without the NetTCPIP module.
        try {
            foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                if ($nic.Name -ne $Adapter.Name) { continue }
                foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) {
                    if ($unicast.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                        $addresses += $unicast.Address.IPAddressToString
                    }
                }
            }
        } catch {
            Write-LogException -ErrorRecord $_ -Context 'Get-AdapterIPv4 (NetworkInterface)'
        }
    }

    $routable = @($addresses | Where-Object { $_ -and $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
    if ($routable.Count -gt 0) {
        $result.Address = $routable[0]
        return $result
    }
    $apipa = @($addresses | Where-Object { $_ -like '169.254.*' })
    if ($apipa.Count -gt 0) {
        $result.Address = $apipa[0]
        $result.IsApipa = $true
    }
    return $result
}

function Test-InternetProbe {
    <#
        Cheap outbound reachability probe, used only when Windows' own network
        awareness (NLA) is not sure. Throttled to once every 15 seconds so the
        monitoring timer never floods the hotspot connection.
    #>
    $age = (Get-Date) - $script:LastProbeTime
    if ($null -ne $script:LastProbeResult -and $age.TotalSeconds -lt 15) {
        return $script:LastProbeResult
    }
    $success = $false
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $ping.Send('1.1.1.1', 800)
            $success = ($null -ne $reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
        } finally {
            $ping.Dispose()
        }
    } catch {
        $success = $false
    }
    $script:LastProbeTime   = Get-Date
    $script:LastProbeResult = $success
    return $success
}

function Get-InternetStatus {
    <#
        Determines the Internet state of the *public* interface itself, rather
        than only checking whether the adapter is administratively enabled.
    #>
    param($Adapter, [switch]$AllowProbe)

    $result = [pscustomobject]@{ State = 'Unknown'; HasInternet = $false }
    if ($null -eq $Adapter) {
        $result.State = 'Adapter missing'
        return $result
    }
    if ($Adapter.Status -eq 'Disabled' -or $Adapter.Status -eq 'Not Present') {
        $result.State = 'Adapter disabled'
        return $result
    }
    if ($Adapter.Status -ne 'Up') {
        $result.State = 'Disconnected'
        return $result
    }

    $profileItem = $null
    try {
        if ($null -ne (Get-Command -Name Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
            if ($Adapter.InterfaceIndex -gt 0) {
                $profileItem = Get-NetConnectionProfile -InterfaceIndex $Adapter.InterfaceIndex -ErrorAction SilentlyContinue
            } else {
                $profileItem = Get-NetConnectionProfile -InterfaceAlias $Adapter.Name -ErrorAction SilentlyContinue
            }
            $profileItem = @($profileItem) | Select-Object -First 1
        }
    } catch {
        $profileItem = $null
    }

    if ($null -ne $profileItem) {
        if ($profileItem.IPv4Connectivity -eq 'Internet' -or $profileItem.IPv6Connectivity -eq 'Internet') {
            $result.State = 'Connected'
            $result.HasInternet = $true
            return $result
        }
    }

    $hasGateway = Test-AdapterHasDefaultGateway -Adapter $Adapter
    if ($AllowProbe -and $hasGateway -and (Test-InternetProbe)) {
        $result.State = 'Connected'
        $result.HasInternet = $true
        return $result
    }

    if ($hasGateway) {
        $result.State = 'No Internet (local only)'
    } else {
        $result.State = 'No Internet'
    }
    return $result
}

# --------------------------------------------------------------------------
# Windows ICS (HNetCfg.HNetShare) - read side
# --------------------------------------------------------------------------

function Get-IcsServiceState {
    # ICS is implemented by the "SharedAccess" service; without it the COM
    # calls fail with unhelpful HRESULTs.
    $state = [pscustomobject]@{ Present = $false; Status = 'Unknown'; StartType = 'Unknown' }
    try {
        $service = Get-Service -Name 'SharedAccess' -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            $state.Present = $true
            $state.Status  = [string]$service.Status
            try { $state.StartType = [string]$service.StartType } catch { $state.StartType = 'Unknown' }
        }
    } catch {
        Write-LogException -ErrorRecord $_ -Context 'Get-IcsServiceState'
    }
    return $state
}

function Get-IcsSnapshot {
    <#
        Reads the *actual* ICS configuration from Windows. The button state is
        always derived from this snapshot, never from a remembered value.

        Returns:
          Available   - the ICS COM API answered
          Error       - friendly error text when it did not
          Connections - one entry per network connection, including whether it
                        is shared and as which side (public/private)
          PublicName / PrivateName - the currently shared pair, if any
    #>
    $snapshot = [pscustomobject]@{
        Available   = $false
        Error       = $null
        Connections = @()
        PublicName  = $null
        PrivateName = $null
        AnyShared   = $false
    }

    $share = $null
    try {
        $share = New-Object -ComObject HNetCfg.HNetShare -ErrorAction Stop
    } catch {
        Write-LogException -ErrorRecord $_ -Context 'Get-IcsSnapshot (create HNetCfg.HNetShare)'
        $snapshot.Error = 'The Windows Internet Connection Sharing interface is not available on this computer.'
        return $snapshot
    }

    $connections = New-Object System.Collections.ArrayList
    try {
        foreach ($connection in @($share.EnumEveryConnection)) {
            $props  = $null
            $config = $null
            try {
                $props = $share.NetConnectionProps($connection)
                $sharingEnabled = $false
                $sharingType    = -1
                try {
                    $config = $share.INetSharingConfigurationForINetConnection($connection)
                    $sharingEnabled = [bool]$config.SharingEnabled
                    if ($sharingEnabled) { $sharingType = [int]$config.SharingConnectionType }
                } catch {
                    # Some pseudo-connections do not expose a sharing configuration.
                    $sharingEnabled = $false
                }

                $entry = [pscustomobject]@{
                    Name           = [string]$props.Name
                    DeviceName     = [string]$props.DeviceName
                    Guid           = [string]$props.Guid
                    Status         = [int]$props.Status
                    Connected      = ([int]$props.Status -eq 2)   # NCS_CONNECTED
                    MediaType      = [int]$props.MediaType
                    SharingEnabled = $sharingEnabled
                    SharingType    = $sharingType
                }
                [void]$connections.Add($entry)

                if ($sharingEnabled) {
                    $snapshot.AnyShared = $true
                    if ($sharingType -eq $script:IcsPublic)  { $snapshot.PublicName  = $entry.Name }
                    if ($sharingType -eq $script:IcsPrivate) { $snapshot.PrivateName = $entry.Name }
                }
            } catch {
                Write-LogException -ErrorRecord $_ -Context 'Get-IcsSnapshot (connection)'
            } finally {
                Remove-ComObjectRef $config
                Remove-ComObjectRef $props
                Remove-ComObjectRef $connection
            }
        }
        $snapshot.Available   = $true
        $snapshot.Connections = @($connections)
    } catch {
        Write-LogException -ErrorRecord $_ -Context 'Get-IcsSnapshot (enumerate)'
        $snapshot.Error = 'The list of network connections could not be read from Windows.'
    } finally {
        Remove-ComObjectRef $share
    }

    return $snapshot
}

function Get-IcsConnectionEntry {
    param($Snapshot, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    foreach ($connection in $Snapshot.Connections) {
        if ($connection.Name -eq $Name) { return $connection }
    }
    return $null
}

# --------------------------------------------------------------------------
# Windows ICS (HNetCfg.HNetShare) - write side
# --------------------------------------------------------------------------

function Confirm-IcsService {
    <#
        ICS needs the "SharedAccess" service. If an image has it disabled the
        COM calls fail, so ask the user once before touching the service - this
        is the only service change the application ever makes.
    #>
    $state = Get-IcsServiceState
    if (-not $state.Present) {
        throw 'The Windows "Internet Connection Sharing (ICS)" service is not present on this computer, so ICS cannot be used.'
    }
    if ($state.StartType -eq 'Disabled') {
        Write-Log -Level WARN -Message 'SharedAccess service is disabled.'
        $message = 'The Windows service "Internet Connection Sharing (ICS)" is currently disabled, so sharing cannot be switched on.' + "`r`n`r`n" +
                   'Set the service to "Manual" now? Windows will then be able to start it when sharing is enabled.'
        if (Confirm-Question -Message $message) {
            try {
                Set-Service -Name 'SharedAccess' -StartupType Manual -ErrorAction Stop
                Write-Log -Message 'SharedAccess service start type changed to Manual (user confirmed).'
            } catch {
                Write-LogException -ErrorRecord $_ -Context 'Confirm-IcsService'
                throw 'The Internet Connection Sharing service could not be enabled. Please enable the "Internet Connection Sharing (ICS)" service in services.msc and try again.'
            }
        } else {
            throw 'Internet Connection Sharing stays switched off because the ICS service is disabled.'
        }
    }
    return $true
}

function Set-IcsConfiguration {
    <#
        Enables ICS between two adapters.

        Steps (in this order, as required by Windows):
          1. verify both connections exist
          2. verify they are different
          3. read the existing sharing configuration
          4. switch off any conflicting sharing
          5. mark the Internet adapter as PUBLIC  (sharing type 0)
          6. mark the camera adapter as PRIVATE   (sharing type 1)
    #>
    param(
        [string]$PublicName,
        [string]$PrivateName
    )

    if ([string]::IsNullOrWhiteSpace($PublicName))  { throw 'No Internet (public) adapter has been selected. Open Settings and choose one.' }
    if ([string]::IsNullOrWhiteSpace($PrivateName)) { throw 'No camera LAN (private) adapter has been selected. Open Settings and choose one.' }
    if ($PublicName -eq $PrivateName) { throw 'The Internet adapter and the camera LAN adapter must be two different adapters.' }

    Confirm-IcsService | Out-Null

    $share       = $null
    $connections = @{}
    try {
        try {
            $share = New-Object -ComObject HNetCfg.HNetShare -ErrorAction Stop
        } catch {
            Write-LogException -ErrorRecord $_ -Context 'Set-IcsConfiguration (create COM)'
            throw 'The Windows Internet Connection Sharing interface could not be opened. Restart the computer and try again.'
        }

        # SharingInstalled is missing on a few builds, so a read failure is not fatal.
        $sharingInstalled = $true
        try { $sharingInstalled = [bool]$share.SharingInstalled } catch { $sharingInstalled = $true }
        if (-not $sharingInstalled) {
            throw 'Internet Connection Sharing is not installed or not available on this Windows installation.'
        }

        # ---- step 1: collect every connection and keep the COM references ----
        foreach ($connection in @($share.EnumEveryConnection)) {
            $props = $null
            try {
                $props = $share.NetConnectionProps($connection)
                $name  = [string]$props.Name
                if (-not $connections.ContainsKey($name)) {
                    $connections[$name] = $connection
                    $connection = $null          # ownership moved to the hashtable
                }
            } catch {
                Write-LogException -ErrorRecord $_ -Context 'Set-IcsConfiguration (props)'
            } finally {
                Remove-ComObjectRef $props
                if ($null -ne $connection) { Remove-ComObjectRef $connection }
            }
        }

        if (-not $connections.ContainsKey($PublicName)) {
            throw ("The Internet adapter `"$PublicName`" was not found. It may have been renamed, disabled or removed - open Settings and select the correct adapter.")
        }
        if (-not $connections.ContainsKey($PrivateName)) {
            throw ("The camera LAN adapter `"$PrivateName`" was not found. It may have been renamed, disabled or removed - open Settings and select the correct adapter.")
        }

        # ---- steps 3 and 4: clear conflicting sharing -------------------------
        foreach ($name in @($connections.Keys)) {
            $config = $null
            try {
                $config = $share.INetSharingConfigurationForINetConnection($connections[$name])
                if ([bool]$config.SharingEnabled) {
                    $type = [int]$config.SharingConnectionType
                    $keep = (($name -eq $PublicName)  -and ($type -eq $script:IcsPublic)) -or
                            (($name -eq $PrivateName) -and ($type -eq $script:IcsPrivate))
                    if (-not $keep) {
                        Write-Log -Message ("Disabling conflicting ICS sharing on '{0}' (type {1})." -f $name, $type)
                        $config.DisableSharing()
                    }
                }
            } catch {
                Write-LogException -ErrorRecord $_ -Context ("Set-IcsConfiguration (clear '$name')")
            } finally {
                Remove-ComObjectRef $config
            }
        }

        # ---- step 5: public interface (0) ------------------------------------
        $publicConfig = $null
        try {
            $publicConfig = $share.INetSharingConfigurationForINetConnection($connections[$PublicName])
            $alreadyPublic = ([bool]$publicConfig.SharingEnabled) -and ([int]$publicConfig.SharingConnectionType -eq $script:IcsPublic)
            if (-not $alreadyPublic) {
                Write-Log -Message ("Enabling ICS PUBLIC (0) on '{0}'." -f $PublicName)
                $publicConfig.EnableSharing($script:IcsPublic)
            }
        } catch {
            Write-LogException -ErrorRecord $_ -Context 'Set-IcsConfiguration (enable public)'
            throw ("Windows refused to share the Internet connection `"$PublicName`". Check that the adapter is connected and try again.")
        } finally {
            Remove-ComObjectRef $publicConfig
        }

        # ---- step 6: private interface (1) -----------------------------------
        $privateConfig = $null
        try {
            $privateConfig = $share.INetSharingConfigurationForINetConnection($connections[$PrivateName])
            $alreadyPrivate = ([bool]$privateConfig.SharingEnabled) -and ([int]$privateConfig.SharingConnectionType -eq $script:IcsPrivate)
            if (-not $alreadyPrivate) {
                Write-Log -Message ("Enabling ICS PRIVATE (1) on '{0}'." -f $PrivateName)
                $privateConfig.EnableSharing($script:IcsPrivate)
            }
        } catch {
            Write-LogException -ErrorRecord $_ -Context 'Set-IcsConfiguration (enable private)'
            throw ("Windows refused to use `"$PrivateName`" as the camera network. Check that the adapter is enabled and try again.")
        } finally {
            Remove-ComObjectRef $privateConfig
        }

        return $true
    } finally {
        foreach ($name in @($connections.Keys)) { Remove-ComObjectRef $connections[$name] }
        $connections.Clear()
        Remove-ComObjectRef $share
    }
}

function Clear-IcsConfiguration {
    <#
        Switches sharing off. Only the two selected adapters are touched; any
        other sharing configuration is reported by the caller instead of being
        changed behind the user's back.
    #>
    param(
        [string]$PublicName,
        [string]$PrivateName
    )

    $share       = $null
    $connections = @{}
    $disabled    = New-Object System.Collections.ArrayList
    try {
        try {
            $share = New-Object -ComObject HNetCfg.HNetShare -ErrorAction Stop
        } catch {
            Write-LogException -ErrorRecord $_ -Context 'Clear-IcsConfiguration (create COM)'
            throw 'The Windows Internet Connection Sharing interface could not be opened. Restart the computer and try again.'
        }

        foreach ($connection in @($share.EnumEveryConnection)) {
            $props = $null
            try {
                $props = $share.NetConnectionProps($connection)
                $name  = [string]$props.Name
                if (-not $connections.ContainsKey($name)) {
                    $connections[$name] = $connection
                    $connection = $null
                }
            } catch {
                Write-LogException -ErrorRecord $_ -Context 'Clear-IcsConfiguration (props)'
            } finally {
                Remove-ComObjectRef $props
                if ($null -ne $connection) { Remove-ComObjectRef $connection }
            }
        }

        foreach ($name in @($PublicName, $PrivateName)) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (-not $connections.ContainsKey($name)) {
                Write-Log -Level WARN -Message ("Cannot switch sharing off on '{0}': connection not found." -f $name)
                continue
            }
            $config = $null
            try {
                $config = $share.INetSharingConfigurationForINetConnection($connections[$name])
                if ([bool]$config.SharingEnabled) {
                    Write-Log -Message ("Disabling ICS sharing on '{0}'." -f $name)
                    $config.DisableSharing()
                    [void]$disabled.Add($name)
                }
            } catch {
                Write-LogException -ErrorRecord $_ -Context ("Clear-IcsConfiguration ('$name')")
                throw ("Windows could not switch Internet sharing off on `"$name`".")
            } finally {
                Remove-ComObjectRef $config
            }
        }

        return @($disabled)
    } finally {
        foreach ($name in @($connections.Keys)) { Remove-ComObjectRef $connections[$name] }
        $connections.Clear()
        Remove-ComObjectRef $share
    }
}

# --------------------------------------------------------------------------
# Adapter selection (saved configuration first, automatic detection second)
# --------------------------------------------------------------------------

$script:AutoDetect   = $null
$script:AutoDetectAt = [DateTime]::MinValue

function Get-AutoSelection {
    param($Inventory, [switch]$Force)

    if (-not $Force -and $null -ne $script:AutoDetect -and ((Get-Date) - $script:AutoDetectAt).TotalSeconds -lt 10) {
        $publicStillThere  = $null -ne (Get-AdapterByName -Inventory $Inventory -Name $script:AutoDetect.Public)
        $privateStillThere = $null -ne (Get-AdapterByName -Inventory $Inventory -Name $script:AutoDetect.Private)
        if ($publicStillThere -and $privateStillThere) { return $script:AutoDetect }
    }

    $publicAdapter  = Find-PublicAdapter  -Inventory $Inventory
    $publicName     = $(if ($null -ne $publicAdapter) { $publicAdapter.Name } else { $null })
    $privateAdapter = Find-PrivateAdapter -Inventory $Inventory -ExcludeName $publicName
    $privateName    = $(if ($null -ne $privateAdapter) { $privateAdapter.Name } else { $null })

    $script:AutoDetect   = [pscustomobject]@{ Public = $publicName; Private = $privateName }
    $script:AutoDetectAt = Get-Date
    Write-Log -Message ("Auto-detected adapters: public='{0}' private='{1}'" -f $publicName, $privateName)
    return $script:AutoDetect
}

function Resolve-Selection {
    <#
        Order of preference:
          1. the adapters the user saved in Settings
          2. the adapters Windows is currently sharing between (reality wins)
          3. automatic detection
    #>
    param($Snapshot, $Inventory)

    $config = $script:Config
    $publicName  = $config.PublicAdapter
    $privateName = $config.PrivateAdapter
    $source      = 'saved'

    if ([string]::IsNullOrWhiteSpace($publicName) -and [string]::IsNullOrWhiteSpace($privateName)) {
        if ($Snapshot.PublicName -and $Snapshot.PrivateName) {
            $publicName  = $Snapshot.PublicName
            $privateName = $Snapshot.PrivateName
            $source      = 'active'
        } else {
            $auto = Get-AutoSelection -Inventory $Inventory
            $publicName  = $auto.Public
            $privateName = $auto.Private
            $source      = 'auto'
        }
    } else {
        # Fill in a missing half automatically.
        if ([string]::IsNullOrWhiteSpace($publicName) -or [string]::IsNullOrWhiteSpace($privateName)) {
            $auto = Get-AutoSelection -Inventory $Inventory
            if ([string]::IsNullOrWhiteSpace($publicName))  { $publicName  = $auto.Public }
            if ([string]::IsNullOrWhiteSpace($privateName)) { $privateName = $auto.Private }
            $source = 'mixed'
        }
    }

    return [pscustomobject]@{ Public = $publicName; Private = $privateName; Source = $source }
}

# --------------------------------------------------------------------------
# Current application state (drives the colours and the labels)
# --------------------------------------------------------------------------

function Get-AppState {
    $state = [pscustomobject]@{
        Mode         = 'Off'          # Off | On | Warn
        ButtonText   = 'INTERNET OFF'
        HintText     = 'Click to enable'
        MappingText  = '-'
        PublicText   = '-'
        PrivateText  = '-'
        LanText      = '-'
        InternetText = '-'
        Action       = 'Enable'       # what a click will do
        PublicName   = $null
        PrivateName  = $null
    }

    $snapshot = Get-IcsSnapshot
    if (-not $snapshot.Available) {
        $state.Mode         = 'Warn'
        $state.ButtonText   = 'CHECK CONNECTION'
        $state.HintText     = 'Internet Connection Sharing unavailable'
        $state.InternetText = 'Unknown'
        return $state
    }

    $inventory = Get-AdapterInventory
    $selection = Resolve-Selection -Snapshot $snapshot -Inventory $inventory
    $state.PublicName  = $selection.Public
    $state.PrivateName = $selection.Private

    $publicAdapter  = Get-AdapterByName -Inventory $inventory -Name $selection.Public
    $privateAdapter = Get-AdapterByName -Inventory $inventory -Name $selection.Private
    $publicEntry    = Get-IcsConnectionEntry -Snapshot $snapshot -Name $selection.Public
    $privateEntry   = Get-IcsConnectionEntry -Snapshot $snapshot -Name $selection.Private

    $publicShared  = ($null -ne $publicEntry)  -and $publicEntry.SharingEnabled  -and ($publicEntry.SharingType  -eq $script:IcsPublic)
    $privateShared = ($null -ne $privateEntry) -and $privateEntry.SharingEnabled -and ($privateEntry.SharingType -eq $script:IcsPrivate)

    # Labels -----------------------------------------------------------------
    if ($selection.Public) {
        $state.PublicText = $selection.Public
        if ($null -eq $publicAdapter -and $null -eq $publicEntry) { $state.PublicText += '  (missing)' }
    } else {
        $state.PublicText = 'not detected'
    }
    if ($selection.Private) {
        $state.PrivateText = $selection.Private
        if ($null -eq $privateAdapter -and $null -eq $privateEntry) { $state.PrivateText += '  (missing)' }
    } else {
        $state.PrivateText = 'not detected'
    }
    $state.MappingText = '{0}  →  {1}' -f $(if ($selection.Public) { $selection.Public } else { '?' }),
                                           $(if ($selection.Private) { $selection.Private } else { '?' })

    $internet = Get-InternetStatus -Adapter $publicAdapter -AllowProbe
    $state.InternetText = $internet.State

    $lan = Get-AdapterIPv4 -Adapter $privateAdapter
    if ($lan.Address -and -not $lan.IsApipa) {
        $state.LanText = $lan.Address
    } elseif ($lan.Address) {
        $state.LanText = '{0}  (no address yet)' -f $lan.Address
    } else {
        $state.LanText = '-'
    }

    # Mode -------------------------------------------------------------------
    if ($publicShared -and $privateShared) {
        $state.Action = 'Disable'
        $problems = New-Object System.Collections.ArrayList
        if ($null -eq $publicAdapter)              { [void]$problems.Add('Internet adapter is missing') }
        elseif (-not $internet.HasInternet)        { [void]$problems.Add('No Internet on ' + $selection.Public) }
        if ($null -eq $privateAdapter)             { [void]$problems.Add('Camera LAN adapter is missing') }
        elseif ($privateAdapter.Status -eq 'Disabled') { [void]$problems.Add($selection.Private + ' is disabled') }
        elseif ($privateAdapter.Status -ne 'Up')   { [void]$problems.Add('Ethernet cable disconnected') }
        elseif (-not $lan.Address -or $lan.IsApipa){ [void]$problems.Add('Waiting for the LAN address') }

        if ($problems.Count -eq 0) {
            $state.Mode       = 'On'
            $state.ButtonText = 'INTERNET ON'
            $state.HintText   = 'Click to disable'
        } else {
            $state.Mode       = 'Warn'
            $state.ButtonText = 'CHECK CONNECTION'
            $state.HintText   = [string]$problems[0]
        }
    } elseif ($publicShared -or $privateShared -or $snapshot.AnyShared) {
        # Partially configured, or Windows is sharing a different pair.
        $state.Mode       = 'Warn'
        $state.ButtonText = 'CHECK CONNECTION'
        $state.Action     = 'Enable'
        if ($publicShared -or $privateShared) {
            $state.HintText = 'Sharing is only half configured - click to fix'
        } else {
            $other = @()
            if ($snapshot.PublicName)  { $other += $snapshot.PublicName }
            if ($snapshot.PrivateName) { $other += $snapshot.PrivateName }
            $state.HintText = 'Sharing active on: ' + ($other -join ' → ')
        }
    } else {
        $state.Mode       = 'Off'
        $state.ButtonText = 'INTERNET OFF'
        $state.HintText   = 'Click to enable'
        $state.Action     = 'Enable'
    }

    if (-not $script:IsElevated) {
        $state.HintText = 'Administrator rights required'
    }

    return $state
}

# --------------------------------------------------------------------------
# User interface
# --------------------------------------------------------------------------

function Set-ToggleButtonColor {
    param($Button, $Color)
    $Button.BackColor = $Color
    $Button.FlatAppearance.BorderColor         = $Color
    $Button.FlatAppearance.MouseOverBackColor  = [System.Drawing.Color]::FromArgb(
        [Math]::Min(255, $Color.R + 25), [Math]::Min(255, $Color.G + 25), [Math]::Min(255, $Color.B + 25))
    $Button.FlatAppearance.MouseDownBackColor  = [System.Drawing.Color]::FromArgb(
        [Math]::Max(0, $Color.R - 25), [Math]::Max(0, $Color.G - 25), [Math]::Max(0, $Color.B - 25))
}

function Update-Ui {
    <#
        Reads the real ICS state and repaints the window. Called by the click
        handler and by the monitoring timer - it never changes anything.
    #>
    param([switch]$Force)

    if ($script:Busy -and -not $Force) { return }

    try {
        $state = Get-AppState
    } catch {
        Write-LogException -ErrorRecord $_ -Context 'Update-Ui'
        $state = [pscustomobject]@{
            Mode = 'Warn'; ButtonText = 'CHECK CONNECTION'; HintText = 'Could not read the network state'
            MappingText = '-'; PublicText = '-'; PrivateText = '-'; LanText = '-'; InternetText = 'Unknown'
            Action = 'Enable'; PublicName = $null; PrivateName = $null
        }
    }

    $script:PendingAction = $state.Action
    $script:CurrentState  = $state

    $script:BtnToggle.Text = $state.ButtonText
    switch ($state.Mode) {
        'On'   { Set-ToggleButtonColor -Button $script:BtnToggle -Color $script:UiColorOn }
        'Warn' { Set-ToggleButtonColor -Button $script:BtnToggle -Color $script:UiColorWarn }
        default { Set-ToggleButtonColor -Button $script:BtnToggle -Color $script:UiColorOff }
    }

    $script:LblHint.Text     = $state.HintText
    $script:LblMapping.Text  = $state.MappingText
    $script:LblPublic.Text   = 'Public:      ' + $state.PublicText
    $script:LblPrivate.Text  = 'Private:     ' + $state.PrivateText
    $script:LblLan.Text      = 'LAN:         ' + $state.LanText
    $script:LblInternet.Text = 'Internet:    ' + $state.InternetText
}

function Wait-ForIcsSettle {
    <#
        Windows needs a moment after EnableSharing before the private adapter
        gets its static address (normally 192.168.137.1) and the DHCP server
        starts. Keep the UI responsive while waiting.
    #>
    param([string]$PrivateName, [int]$TimeoutSeconds = 12)

    $start    = Get-Date
    $deadline = $start.AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 500
        $inventory = Get-AdapterInventory
        $adapter   = Get-AdapterByName -Inventory $inventory -Name $PrivateName
        if ($null -eq $adapter) { continue }
        if ($adapter.Status -ne 'Up') {
            # The adapter briefly drops while ICS reconfigures it; if it is
            # still down after a few seconds the cable is simply unplugged.
            if (((Get-Date) - $start).TotalSeconds -gt 4) { return $false }
            continue
        }
        $ip = Get-AdapterIPv4 -Adapter $adapter
        if ($ip.Address -and -not $ip.IsApipa) { return $true }
    }
    return $false
}

function Invoke-Toggle {
    if ($script:Busy) { return }
    if (-not $script:IsElevated) {
        Show-Warning -Message ("$script:AppName is not running as administrator, so the sharing configuration cannot be changed." + "`r`n`r`n" +
            'Close the program and start it again with "Run as administrator".')
        return
    }

    $script:Busy = $true
    $script:Timer.Stop()
    $script:BtnToggle.Enabled = $false
    $script:BtnSettings.Enabled = $false
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $action = $script:PendingAction

    try {
        $state = $script:CurrentState
        $publicName  = $state.PublicName
        $privateName = $state.PrivateName

        if ([string]::IsNullOrWhiteSpace($publicName) -or [string]::IsNullOrWhiteSpace($privateName)) {
            throw ('The network adapters could not be determined automatically.' + "`r`n`r`n" +
                   'Open Settings and select the Internet adapter (Wi-Fi) and the camera LAN adapter (Ethernet).')
        }

        if ($action -eq 'Disable') {
            $script:BtnToggle.Text = 'SWITCHING OFF...'
            $script:LblHint.Text   = 'Please wait'
            [System.Windows.Forms.Application]::DoEvents()

            Write-Log -Message ("User requested ICS OFF ('{0}' -> '{1}')." -f $publicName, $privateName)
            Clear-IcsConfiguration -PublicName $publicName -PrivateName $privateName | Out-Null
            Start-Sleep -Milliseconds 800

            $after = Get-IcsSnapshot
            if ($after.Available -and $after.AnyShared) {
                $remaining = @()
                if ($after.PublicName)  { $remaining += $after.PublicName }
                if ($after.PrivateName) { $remaining += $after.PrivateName }
                Write-Log -Level WARN -Message ('Sharing still enabled after disable: ' + ($remaining -join ', '))
                Show-Warning -Message ('Internet sharing is still switched on for other adapters:' + "`r`n`r`n" +
                    ($remaining -join "`r`n") + "`r`n`r`n" +
                    'They were left untouched because they are not the adapters selected in Settings.')
            }
        } else {
            $script:BtnToggle.Text = 'SWITCHING ON...'
            $script:LblHint.Text   = 'Please wait'
            [System.Windows.Forms.Application]::DoEvents()

            Write-Log -Message ("User requested ICS ON ('{0}' -> '{1}')." -f $publicName, $privateName)
            Set-IcsConfiguration -PublicName $publicName -PrivateName $privateName | Out-Null
            [void](Wait-ForIcsSettle -PrivateName $privateName)

            # Re-read the real configuration before judging the result.
            $after = Get-IcsSnapshot
            $publicEntry  = Get-IcsConnectionEntry -Snapshot $after -Name $publicName
            $privateEntry = Get-IcsConnectionEntry -Snapshot $after -Name $privateName
            $ok = ($null -ne $publicEntry)  -and $publicEntry.SharingEnabled  -and ($publicEntry.SharingType  -eq $script:IcsPublic) -and
                  ($null -ne $privateEntry) -and $privateEntry.SharingEnabled -and ($privateEntry.SharingType -eq $script:IcsPrivate)
            if (-not $ok) {
                Write-Log -Level ERROR -Message 'ICS did not report both adapters as shared after enabling.'
                Show-ErrorMessage -Message ('Windows did not switch Internet sharing on.' + "`r`n`r`n" +
                    'Things worth checking:' + "`r`n" +
                    ' - the Wi-Fi adapter is connected to the phone hotspot' + "`r`n" +
                    ' - the Ethernet adapter is enabled' + "`r`n" +
                    ' - the "Internet Connection Sharing (ICS)" service is not disabled' + "`r`n" +
                    ' - no other program (VPN client, hotspot tool) is holding the sharing configuration')
            }
        }
    } catch {
        Write-LogException -ErrorRecord $_ -Context ("Invoke-Toggle ($action)")
        Show-ErrorMessage -Message $_.Exception.Message
    } finally {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $script:BtnToggle.Enabled = $true
        $script:BtnSettings.Enabled = $true
        $script:Busy = $false
        Update-Ui -Force
        $script:Timer.Start()
    }
}

function Show-SettingsDialog {
    <#
        Manual adapter selection. The two drop-downs are filled from the live
        adapter list; the choice is stored in %LOCALAPPDATA%.
    #>
    $inventory = @(Get-AdapterInventory | Sort-Object -Property Name)
    if ($inventory.Count -eq 0) {
        Show-Warning -Message 'No network adapters could be read from Windows.'
        return
    }

    $names    = @()
    $captions = @()
    foreach ($adapter in $inventory) {
        $names    += $adapter.Name
        $kind     = if ($adapter.IsWireless) { 'Wi-Fi' } elseif ($adapter.IsEthernet) { 'Ethernet' } elseif ($adapter.IsVirtual) { 'virtual' } else { 'other' }
        $captions += ('{0}  [{1}, {2}]' -f $adapter.Name, $kind, $adapter.Status)
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text            = 'Camera Internet - Settings'
    $dialog.ClientSize      = New-Object System.Drawing.Size(384, 196)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.MaximizeBox     = $false
    $dialog.MinimizeBox     = $false
    $dialog.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    $lblPublic = New-Object System.Windows.Forms.Label
    $lblPublic.Text     = 'Internet adapter (Wi-Fi / phone hotspot):'
    $lblPublic.Location = New-Object System.Drawing.Point(12, 14)
    $lblPublic.Size     = New-Object System.Drawing.Size(360, 18)

    $cmbPublic = New-Object System.Windows.Forms.ComboBox
    $cmbPublic.Location      = New-Object System.Drawing.Point(12, 34)
    $cmbPublic.Size          = New-Object System.Drawing.Size(360, 24)
    $cmbPublic.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

    $lblPrivate = New-Object System.Windows.Forms.Label
    $lblPrivate.Text     = 'Camera LAN adapter (Ethernet to the switch):'
    $lblPrivate.Location  = New-Object System.Drawing.Point(12, 68)
    $lblPrivate.Size      = New-Object System.Drawing.Size(360, 18)

    $cmbPrivate = New-Object System.Windows.Forms.ComboBox
    $cmbPrivate.Location      = New-Object System.Drawing.Point(12, 88)
    $cmbPrivate.Size          = New-Object System.Drawing.Size(360, 24)
    $cmbPrivate.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

    foreach ($caption in $captions) {
        [void]$cmbPublic.Items.Add($caption)
        [void]$cmbPrivate.Items.Add($caption)
    }

    $selectByName = {
        param($combo, $name)
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        for ($i = 0; $i -lt $names.Count; $i++) {
            if ($names[$i] -eq $name) { $combo.SelectedIndex = $i; return }
        }
    }
    & $selectByName $cmbPublic  $script:CurrentState.PublicName
    & $selectByName $cmbPrivate $script:CurrentState.PrivateName

    $btnAuto = New-Object System.Windows.Forms.Button
    $btnAuto.Text     = 'Auto-detect'
    $btnAuto.Location = New-Object System.Drawing.Point(12, 126)
    $btnAuto.Size     = New-Object System.Drawing.Size(96, 28)
    $btnAuto.Add_Click({
        $auto = Get-AutoSelection -Inventory $inventory -Force
        & $selectByName $cmbPublic  $auto.Public
        & $selectByName $cmbPrivate $auto.Private
    }.GetNewClosure())

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Save'
    $btnOk.Location = New-Object System.Drawing.Point(196, 126)
    $btnOk.Size     = New-Object System.Drawing.Size(84, 28)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Location     = New-Object System.Drawing.Point(288, 126)
    $btnCancel.Size         = New-Object System.Drawing.Size(84, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text      = 'Leave both empty to let the program detect the adapters itself.'
    $lblNote.Location  = New-Object System.Drawing.Point(12, 162)
    $lblNote.Size      = New-Object System.Drawing.Size(360, 18)
    $lblNote.ForeColor = [System.Drawing.Color]::DimGray

    $btnOk.Add_Click({
        if ($cmbPublic.SelectedIndex -lt 0 -or $cmbPrivate.SelectedIndex -lt 0) {
            Show-Warning -Message 'Please choose both an Internet adapter and a camera LAN adapter.'
            return
        }
        $publicName  = $names[$cmbPublic.SelectedIndex]
        $privateName = $names[$cmbPrivate.SelectedIndex]
        if ($publicName -eq $privateName) {
            Show-Warning -Message 'The Internet adapter and the camera LAN adapter must be two different adapters.'
            return
        }
        if (Save-AppConfig -PublicAdapter $publicName -PrivateAdapter $privateName) {
            $script:Config.PublicAdapter  = $publicName
            $script:Config.PrivateAdapter = $privateName
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    }.GetNewClosure())

    $dialog.Controls.AddRange(@($lblPublic, $cmbPublic, $lblPrivate, $cmbPrivate, $btnAuto, $btnOk, $btnCancel, $lblNote))
    $dialog.AcceptButton = $btnOk
    $dialog.CancelButton = $btnCancel

    try {
        [void]$dialog.ShowDialog($script:Form)
    } finally {
        $dialog.Dispose()
    }
    Update-Ui -Force
}

function New-AppIcon {
    <#
        Builds a small camera/network icon at runtime so that no external .ico
        file is needed. Returns $null when drawing is not possible.
    #>
    try {
        $bitmap = New-Object System.Drawing.Bitmap(32, 32)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.Clear([System.Drawing.Color]::Transparent)

            $background = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(21, 101, 173))
            $graphics.FillEllipse($background, 0, 0, 31, 31)
            $background.Dispose()

            $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
            # camera body + lens barrel + wall bracket
            $graphics.FillRectangle($white, 6, 13, 13, 8)
            $points = @(
                (New-Object System.Drawing.Point(19, 15)),
                (New-Object System.Drawing.Point(25, 12)),
                (New-Object System.Drawing.Point(25, 22)),
                (New-Object System.Drawing.Point(19, 19))
            )
            $graphics.FillPolygon($white, [System.Drawing.Point[]]$points)
            $graphics.FillRectangle($white, 10, 21, 4, 5)
            $graphics.FillRectangle($white, 7, 25, 10, 3)

            # signal arcs
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
            $graphics.DrawArc($pen, 4, 3, 10, 10, 200, 110)
            $graphics.DrawArc($pen, 1, 1, 16, 16, 205, 100)
            $pen.Dispose()
            $white.Dispose()
        } finally {
            $graphics.Dispose()
        }

        # GetHicon hands out an unmanaged HICON: clone it into a managed icon
        # and release the handle again so nothing leaks.
        $handle = $bitmap.GetHicon()
        $icon   = [System.Drawing.Icon]::FromHandle($handle)
        $clone  = [System.Drawing.Icon]$icon.Clone()
        $icon.Dispose()
        $bitmap.Dispose()
        if (Initialize-NativeMethods) { [void][CameraInternet.NativeMethods]::DestroyIcon($handle) }
        return $clone
    } catch {
        Write-LogException -ErrorRecord $_ -Context 'New-AppIcon'
        return $null
    }
}

function Export-AppIcon {
    param([Parameter(Mandatory = $true)][string]$Path)
    $icon = New-AppIcon
    if ($null -eq $icon) { throw 'The application icon could not be created.' }
    $stream = [System.IO.File]::Create($Path)
    try {
        $icon.Save($stream)
    } finally {
        $stream.Close()
        $icon.Dispose()
    }
    return $Path
}

function Initialize-NativeMethods {
    if ('CameraInternet.NativeMethods' -as [type]) { return $true }
    try {
        Add-Type -Namespace 'CameraInternet' -Name 'NativeMethods' -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);

[DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr hIcon);
'@
        return $true
    } catch {
        return $false
    }
}

function Hide-ConsoleWindow {
    try {
        if (-not (Initialize-NativeMethods)) { return }
        $handle = [CameraInternet.NativeMethods]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) {
            [void][CameraInternet.NativeMethods]::ShowWindow($handle, 0)   # SW_HIDE
        }
    } catch {
        # A hidden console is cosmetic - never fail because of it.
    }
}

function New-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $script:AppName
    $form.ClientSize      = New-Object System.Drawing.Size(284, 184)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox     = $false
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor       = [System.Drawing.Color]::White

    $icon = New-AppIcon
    if ($null -ne $icon) { $form.Icon = $icon }

    $button = New-Object System.Windows.Forms.Button
    $button.Location  = New-Object System.Drawing.Point(12, 8)
    $button.Size      = New-Object System.Drawing.Size(260, 70)
    $button.Font      = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $button.ForeColor = [System.Drawing.Color]::White
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.Text      = 'CHECKING...'
    $button.UseVisualStyleBackColor = $false
    Set-ToggleButtonColor -Button $button -Color $script:UiColorOff
    $button.Add_Click({
        try { Invoke-Toggle } catch {
            Write-LogException -ErrorRecord $_ -Context 'Toggle handler'
            Show-ErrorMessage -Message $_.Exception.Message
        }
    })

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Location  = New-Object System.Drawing.Point(12, 81)
    $lblHint.Size      = New-Object System.Drawing.Size(260, 15)
    $lblHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblHint.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $lblHint.Text      = 'Reading the current state...'

    $lblMapping = New-Object System.Windows.Forms.Label
    $lblMapping.Location  = New-Object System.Drawing.Point(12, 97)
    $lblMapping.Size      = New-Object System.Drawing.Size(260, 16)
    $lblMapping.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblMapping.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblMapping.Text      = '-'

    $statusFont = New-Object System.Drawing.Font('Segoe UI', 8.25)
    $lblPublic   = New-Object System.Windows.Forms.Label
    $lblPrivate  = New-Object System.Windows.Forms.Label
    $lblLan      = New-Object System.Windows.Forms.Label
    $lblInternet = New-Object System.Windows.Forms.Label
    $y = 118
    foreach ($label in @($lblPublic, $lblPrivate, $lblLan, $lblInternet)) {
        $label.Location  = New-Object System.Drawing.Point(14, $y)
        $label.Size      = New-Object System.Drawing.Size(186, 14)
        $label.Font      = $statusFont
        $label.ForeColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
        $label.AutoEllipsis = $true
        $y += 14
    }

    $btnSettings = New-Object System.Windows.Forms.Button
    $btnSettings.Location = New-Object System.Drawing.Point(204, 146)
    $btnSettings.Size     = New-Object System.Drawing.Size(68, 26)
    $btnSettings.Text     = 'Settings'
    $btnSettings.Font     = New-Object System.Drawing.Font('Segoe UI', 8.25)
    $btnSettings.Add_Click({
        try { Show-SettingsDialog } catch {
            Write-LogException -ErrorRecord $_ -Context 'Settings handler'
            Show-ErrorMessage -Message $_.Exception.Message
        }
    })

    $form.Controls.AddRange(@($button, $lblHint, $lblMapping, $lblPublic, $lblPrivate, $lblLan, $lblInternet, $btnSettings))

    $script:Form        = $form
    $script:BtnToggle   = $button
    $script:BtnSettings = $btnSettings
    $script:LblHint     = $lblHint
    $script:LblMapping  = $lblMapping
    $script:LblPublic   = $lblPublic
    $script:LblPrivate  = $lblPrivate
    $script:LblLan      = $lblLan
    $script:LblInternet = $lblInternet

    # Monitoring timer: it only refreshes the display, it never toggles ICS.
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2500
    $timer.Add_Tick({
        try { Update-Ui } catch { Write-LogException -ErrorRecord $_ -Context 'Timer tick' }
    })
    $script:Timer = $timer

    $form.Add_Shown({
        Update-Ui -Force
        $script:Timer.Start()
    })
    $form.Add_FormClosing({
        try { $script:Timer.Stop() } catch { }
    })
    $form.Add_FormClosed({
        try {
            $script:Timer.Dispose()
            $script:Timer = $null
        } catch { }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    })

    return $form
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

function Start-CameraInternet {
    Initialize-AppFolder
    Write-Log -Message ('--- {0} starting (PowerShell {1}, {2}) ---' -f $script:AppName,
        $PSVersionTable.PSVersion.ToString(), [System.Environment]::OSVersion.VersionString)

    # Icon export runs from the installer and shares that console window, so it
    # must be handled before the console is hidden.
    if ($ExportIcon) {
        $path = Export-AppIcon -Path $ExportIcon
        Write-Log -Message "Icon exported to $path"
        return
    }

    # The console window must not sit behind the GUI. It is only hidden when
    # the script was started with -File (never when typed into a console).
    if (-not $KeepConsole -and [string]::IsNullOrEmpty($script:InvocationLine)) {
        Hide-ConsoleWindow
    }

    $script:IsElevated = Test-Administrator
    if (-not $script:IsElevated -and -not $NoElevate) {
        if (Invoke-SelfElevation) { return }
        return
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Global\CameraInternetIcsUtility')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) {
            Write-Log -Level WARN -Message 'Another instance is already running.'
            Show-Info -Message 'Camera Internet is already running.'
            return
        }

        $script:Config = Get-AppConfig
        Write-Log -Message ("Configured adapters: public='{0}' private='{1}'" -f $script:Config.PublicAdapter, $script:Config.PrivateAdapter)

        $form = New-MainForm
        [void][System.Windows.Forms.Application]::Run($form)
        $form.Dispose()
        Write-Log -Message '--- Camera Internet closed ---'
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
} catch {
    Write-Log -Level ERROR -Message ('Windows Forms could not be loaded: ' + $_.Exception.Message)
    Write-Host 'Camera Internet needs the Windows Forms components of the .NET Framework, which are not available on this system.' -ForegroundColor Red
    exit 1
}

try {
    Start-CameraInternet
} catch {
    Write-LogException -ErrorRecord $_ -Context 'Fatal'
    try {
        Show-ErrorMessage -Message ('Camera Internet stopped because of an unexpected problem:' + "`r`n`r`n" + $_.Exception.Message)
    } catch {
        Write-Host ('Camera Internet stopped: ' + $_.Exception.Message) -ForegroundColor Red
    }
    exit 1
}
