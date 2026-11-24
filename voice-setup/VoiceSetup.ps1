# Vault-Talk voice setup: the voices of Courier's Company (Fallout: New Vegas) and Survivor's Company
# (Fallout 4) without the launcher. It does what the launcher's Voice page does, step by step, in this
# console:
#   1. finds your games and the mod in them (plain Data, Vortex or Mod Organizer 2)
#   2. optionally connects Player2 (the AI) in your browser
#   3. installs a voice engine: Pocket TTS (any PC) or OmniVoice (NVIDIA card, 6 GB or more)
#   4. gets the tools that turn a line into a game voice file: FaceFXWrapper + FonixData.cdf
#      (mouth movement) and, for Fallout 4, xWMAEncode
#   5. adds those settings to each game's config.json (what's already there stays)
#   6. speaks one line, so you hear it works
# Everything goes where the launcher puts it (%LOCALAPPDATA%\VaultTalk), so both find each other's work.
# The engine installers (engines\install_*.ps1) are the launcher's own, copied here unchanged.
# Nothing is sent anywhere except the downloads listed and, if you choose it, Player2's login.
# Your Player2 key is written only into the games' config.json; it is never shown or logged.
#
# Usage: double-click VoiceSetup.bat, or
#   powershell -ExecutionPolicy Bypass -File VoiceSetup.ps1 [-Language en|es] [-Engine pocket|omnivoice] [-Game "<folder>;<folder>"] [-SkipAi] [-SkipTest]
param(
    [string]$Language = "",
    [ValidateSet("", "pocket", "omnivoice")][string]$Engine = "",
    [string[]]$Game = @(),
    [switch]$SkipAi,
    [switch]$SkipTest,
    [switch]$Quiet          # the test line is made but not played
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Repo = "https://raw.githubusercontent.com/CarlosNahuelcoy/Vault-Talk/main"
$Player2Api = "https://api.player2.game/v1"
$Player2App = "http://127.0.0.1:4315/v1"
$Player2ClientId = "01a1d526-1cd9-7717-beea-c62756252713"   # the launcher's game client id on Player2
$Here = $PSScriptRoot

# ---- language: the player's own (Windows' display language), English or Spanish
if (-not $Language) { $Language = if ((Get-UICulture).TwoLetterISOLanguageName -eq "es") { "es" } else { "en" } }
function T([string]$en, [string]$es) { if ($Language -eq "es") { $es } else { $en } }

# ---- where things go: the same folders as the launcher
$LocalAppData = [Environment]::GetFolderPath("LocalApplicationData")
$HomeDir = if ($env:VAULTTALK_HOME) { $env:VAULTTALK_HOME } else { Join-Path $LocalAppData "VaultTalk" }
# Python and pip break on long paths and on letters outside English (C:\Users\José): then C:\VaultTalk
function EnginesRoot {
    $own = Join-Path $HomeDir "engines"
    $plain = $own.Length -le 60 -and -not ($own.ToCharArray() | Where-Object { [int]$_ -gt 127 })
    if ($plain -or (Test-Path $own) -or $env:VAULTTALK_HOME) { return $own }
    return Join-Path ([IO.Path]::GetPathRoot([Environment]::SystemDirectory)) "VaultTalk\engines"
}
$Engines = EnginesRoot
$PocketDir = Join-Path $Engines "pocket"
$OmniDir = Join-Path $Engines "omnivoice"
$ToolsDir = Join-Path $HomeDir "tools"
$LipDir = Join-Path $ToolsDir "FaceFXWrapper"
$XwmaFile = Join-Path $ToolsDir "xWMAEncode.exe"
$LogFile = Join-Path $HomeDir "voice-setup.log"
New-Item -ItemType Directory -Force $HomeDir | Out-Null

# ---- console helpers
function Log([string]$text) { try { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $text) -Encoding UTF8 } catch { } }
function Title([string]$text) { Write-Host ""; Write-Host ("== " + $text) -ForegroundColor Cyan; Log ("== " + $text) }
function Say([string]$text) { Write-Host ("   " + $text); Log $text }
function Good([string]$text) { Write-Host ("   OK  " + $text) -ForegroundColor Green; Log ("OK " + $text) }
function Warn([string]$text) { Write-Host ("   !   " + $text) -ForegroundColor Yellow; Log ("WARN " + $text) }
function Bad([string]$text) { Write-Host ("   X   " + $text) -ForegroundColor Red; Log ("FAIL " + $text) }
function Ask([string]$question, [string]$default) {
    $answer = Read-Host ("   " + $question)
    if (-not $answer) { return $default }
    return $answer.Trim()
}
function Yes([string]$question, [bool]$default) {
    $hint = if ($default) { T "[Y/n]" "[S/n]" } else { T "[y/N]" "[s/N]" }
    $a = Ask "$question $hint" ""
    if (-not $a) { return $default }
    return $a -match '^(y|yes|s|si|sí)$'
}
function Stop-Setup([string]$why) {
    Bad $why
    Write-Host ""
    Say (T "The log is in $LogFile (no keys in it)." "El registro está en $LogFile (sin claves).")
    exit 1
}
function Gb([double]$mb) { return ($mb / 1000).ToString("0.#") }
function FreeMb([string]$path) {
    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($path))
        return [math]::Floor((New-Object IO.DriveInfo($root)).AvailableFreeSpace / 1MB)
    } catch { return -1 }
}
function Sha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
# a download, checked against its size and SHA-256 when the list gives them
function Fetch([string]$url, [string]$path, [string]$sha256) {
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $part = "$path.part"
    Invoke-WebRequest $url -OutFile $part -UseBasicParsing
    if ($sha256 -and (Sha $part) -ne $sha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $part -Force
        throw (T "the download of $([IO.Path]::GetFileName($path)) came out different from the published one (SHA-256)" "la descarga de $([IO.Path]::GetFileName($path)) salió distinta a la publicada (SHA-256)")
    }
    Move-Item -LiteralPath $part $path -Force
}
# why a step failed, and what to do about it (the launcher's own hints)
function Hint([string]$e) {
    $e = "$e".ToLowerInvariant()
    if ($e -match 'no space|espacio|errno 28') { return T "The disk is full: free some space and run this again." "El disco está lleno: libera espacio y vuelve a ejecutar esto." }
    if ($e -match 'cuda|out of memory|nvidia|driver') { return T "The graphics card couldn't run it: update NVIDIA's driver, close programs that use the card, and run this again." "La tarjeta de video no pudo correrlo: actualiza el driver de NVIDIA, cierra programas que usen la tarjeta y vuelve a ejecutar esto." }
    if ($e -match 'antivirus|access is denied|acceso denegado|permission') { return T "An antivirus may have blocked Python: allow the folder $Engines and run this again." "Puede que un antivirus haya bloqueado Python: permite la carpeta $Engines y vuelve a ejecutar esto." }
    if ($e -match 'could not resolve|timed out|connection|conexi|remote name|unable to connect') { return T "The internet connection dropped. Run this again: it picks up where it left off." "Se cortó la conexión a internet. Vuelve a ejecutar esto: sigue desde donde quedó." }
    return T "Run this again. If it fails the same way, send the log ($LogFile)." "Vuelve a ejecutar esto. Si falla igual, envía el registro ($LogFile)."
}

# ---- the games and their mod
$Defs = @(
    @{ Id = "fnv"; Name = "Fallout: New Vegas"; Exe = "FalloutNV.exe"; Process = "FalloutNV"; SteamAppId = 22380
       Folders = @("Fallout New Vegas", "Fallout New Vegas enplczru", "Fallout New Vegas Ultimate Edition")
       Mod = "Courier's Company"; ModId = "CouriersCompany"; PluginDir = "NVSE\Plugins"; Xwma = $false },
    @{ Id = "fo4"; Name = "Fallout 4"; Exe = "Fallout4.exe"; Process = "Fallout4"; SteamAppId = 377160
       Folders = @("Fallout 4", "Fallout 4 GOTY", "Fallout 4 Game of the Year Edition")
       Mod = "Survivor's Company"; ModId = "SurvivorsCompany"; PluginDir = "F4SE\Plugins"; Xwma = $true }
)

function RegValue([string]$key, [string]$name) {
    try { return (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop).$name } catch { return $null }
}

function SteamLibraries {
    $roots = @()
    $s = RegValue "HKCU:\Software\Valve\Steam" "SteamPath"; if ($s) { $roots += $s.Replace('/', '\') }
    $s = RegValue "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" "InstallPath"; if ($s) { $roots += $s }
    $libs = @($roots)
    foreach ($r in $roots) {
        $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value.Replace('\\', '\') }
        }
    }
    return $libs | Select-Object -Unique
}

function FindGames($def) {
    $found = New-Object System.Collections.Generic.List[string]
    function Add([string]$path) {
        try {
            if (-not $path -or -not (Test-Path -LiteralPath (Join-Path $path $def.Exe))) { return }
            $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
            if (-not ($found | Where-Object { $_ -ieq $full })) { $found.Add($full) }
        } catch { }
    }
    # folders given with -Game: only those
    $given = @($Game | ForEach-Object { $_ -split ';' } | Where-Object { $_.Trim() })
    if ($given.Count -gt 0) { foreach ($g in $given) { Add $g.Trim().Trim('"') }; return $found }
    # the launcher's own list, when it ran on this PC
    $launcherJson = Join-Path $HomeDir "launcher.json"
    if (Test-Path -LiteralPath $launcherJson) {
        try { Add ((Get-Content -LiteralPath $launcherJson -Raw -Encoding UTF8 | ConvertFrom-Json).games.($def.Id).path) } catch { }
    }
    foreach ($lib in SteamLibraries) {
        $acf = Join-Path $lib ("steamapps\appmanifest_" + $def.SteamAppId + ".acf")
        if (Test-Path -LiteralPath $acf) {
            $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw), '"installdir"\s+"([^"]+)"')
            if ($m.Success) { Add (Join-Path $lib ("steamapps\common\" + $m.Groups[1].Value)) }
        }
        foreach ($n in $def.Folders) { Add (Join-Path $lib "steamapps\common\$n") }
    }
    foreach ($root in @("HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games", "HKLM:\SOFTWARE\GOG.com\Games")) {
        if (Test-Path $root) { foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) { Add (RegValue $k.PSPath "path") } }
    }
    $epic = Join-Path $env:ProgramData "Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path $epic) {
        foreach ($item in Get-ChildItem $epic -Filter *.item -ErrorAction SilentlyContinue) {
            try { Add ((Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json).InstallLocation) } catch { }
        }
    }
    foreach ($drive in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "Fixed" } | ForEach-Object { $_.Name }) {
        foreach ($n in $def.Folders) {
            foreach ($p in @("Program Files (x86)\Steam\steamapps\common\$n", "SteamLibrary\steamapps\common\$n", "Steam\steamapps\common\$n",
                    "GOG Games\$n", "Program Files (x86)\GOG Galaxy\Games\$n", "Games\$n", "Juegos\$n",
                    ("Program Files\Epic Games\" + $n.Replace(" ", "")), "Program Files\Epic Games\$n", "XboxGames\$n- PC\Content", "XboxGames\$n\Content", $n)) {
                Add (Join-Path $drive $p)
            }
        }
    }
    return $found
}

# Mod Organizer 2: an instance whose game is this folder, and the folders the game sees as Data
# (overwrite first, then the enabled mods by priority), like the launcher reads them.
function QtIni([string]$file) {
    $values = @{}; $section = ""
    foreach ($raw in [IO.File]::ReadAllLines($file)) {
        $line = $raw.Trim()
        if ($line -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $v = $line.Substring($eq + 1).Trim().Trim('"')
        if ($v -match '^@ByteArray\((.*)\)$') { $v = $Matches[1] }
        $values["$section/" + $line.Substring(0, $eq).Trim()] = $v.Replace('\\', '\')
    }
    return $values
}

function Mo2Inis {
    $dirs = @()
    $known = Join-Path $HomeDir "mo2-instances.txt"
    if (Test-Path -LiteralPath $known) { $dirs += Get-Content -LiteralPath $known }
    if ($env:VAULTTALK_MO2) { $dirs += $env:VAULTTALK_MO2.Split(';') }
    $own = Join-Path $LocalAppData "ModOrganizer"
    if (Test-Path -LiteralPath $own) {
        $dirs += Get-ChildItem -LiteralPath $own -Directory | ForEach-Object { $_.FullName }
        $handlers = Join-Path $own "nxmhandler.ini"
        if (Test-Path -LiteralPath $handlers) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $handlers -Raw), 'executable=(.+)')) { $dirs += Split-Path $m.Groups[1].Value.Trim().Trim('"') }
        }
    }
    $cmd = RegValue "HKCU:\Software\Classes\nxm\shell\open\command" "(default)"
    if ($cmd -and $cmd -match '^\s*"([^"]+)"|^\s*(\S+)') { $dirs += Split-Path ($(if ($Matches[1]) { $Matches[1] } else { $Matches[2] })) }
    foreach ($p in Get-Process ModOrganizer -ErrorAction SilentlyContinue) { try { $dirs += Split-Path $p.Path } catch { } }
    $dirs | Where-Object { $_ } | ForEach-Object { if ($_ -like "*.ini") { $_ } else { Join-Path $_ "ModOrganizer.ini" } } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
}

function Mo2Layers([string]$gameDir) {
    foreach ($ini in Mo2Inis) {
        try {
            $v = QtIni $ini
            $gp = $v["General/gamePath"]
            if (-not $gp -or [IO.Path]::GetFullPath($gp.Replace('/', '\')).TrimEnd('\') -ine $gameDir) { continue }
            $base = if ($v["Settings/base_directory"]) { $v["Settings/base_directory"] } else { Split-Path $ini }
            function Folder([string]$key, [string]$fallback) { $x = $v[$key]; if (-not $x) { return $fallback }; return [IO.Path]::GetFullPath($x.Replace("%BASE_DIR%", $base).Replace('/', '\')) }
            $mods = Folder "Settings/mod_directory" (Join-Path $base "mods")
            $overwrite = Folder "Settings/overwrite_directory" (Join-Path $base "overwrite")
            $profiles = Folder "Settings/profiles_directory" (Join-Path $base "profiles")
            $profile = if ($v["General/selected_profile"]) { $v["General/selected_profile"] } else { "Default" }
            $layers = @($overwrite)
            $modlist = Join-Path $profiles "$profile\modlist.txt"
            if (Test-Path -LiteralPath $modlist) {
                foreach ($l in [IO.File]::ReadAllLines($modlist)) { if ($l.StartsWith("+") -and $l.Length -gt 1) { $layers += Join-Path $mods $l.Substring(1).Trim() } }
            }
            return @{ Ini = $ini; Layers = $layers }
        } catch { }
    }
    return $null
}

# where the mod is for this game: the folder of its config.json, as the game sees it
function ModPlace($def, [string]$gameDir) {
    $rel = Join-Path $def.PluginDir $def.ModId                     # NVSE\Plugins\CouriersCompany
    $dll = Join-Path $def.PluginDir ($def.ModId + ".dll")
    $mo2 = Mo2Layers $gameDir
    $layers = if ($mo2) { $mo2.Layers } else { @(Join-Path $gameDir "Data") }
    $manager = if ($mo2) { "Mod Organizer 2" } elseif (Get-ChildItem -LiteralPath $gameDir, (Join-Path $gameDir "Data") -Filter "vortex.deployment*.json" -ErrorAction SilentlyContinue) { "Vortex" } else { "" }
    # an existing config.json wins (MO2: overwrite, where the game writes, comes first)
    foreach ($l in $layers) { if (Test-Path -LiteralPath (Join-Path $l "$rel\config.json")) { return @{ Dir = (Join-Path $l $rel); Manager = $manager; Mo2 = $mo2 } } }
    # else next to the mod's DLL (its own MO2 mod, not overwrite)
    foreach ($l in $layers) { if (Test-Path -LiteralPath (Join-Path $l $dll)) { return @{ Dir = (Join-Path $l $rel); Manager = $manager; Mo2 = $mo2 } } }
    foreach ($l in $layers) { if (Test-Path -LiteralPath (Join-Path $l "$rel\engine.py")) { return @{ Dir = (Join-Path $l $rel); Manager = $manager; Mo2 = $mo2 } } }
    return @{ Dir = $null; Manager = $manager; Mo2 = $mo2 }
}

# ---- the list the launcher reads (tool downloads, engine sizes): the published one, else the copy here
function LoadManifest {
    try { return Invoke-RestMethod "$Repo/manifest.json" -UseBasicParsing -TimeoutSec 20 } catch { }
    $local = Join-Path $Here "manifest.json"
    if (Test-Path -LiteralPath $local) { return Get-Content -LiteralPath $local -Raw -Encoding UTF8 | ConvertFrom-Json }
    return $null
}

function EngineScript([string]$name) {
    $local = Join-Path $Here "engines\$name"
    if (Test-Path -LiteralPath $local) { return $local }
    $tmp = Join-Path $env:TEMP "vaulttalk-$name"
    Invoke-WebRequest "$Repo/voice-setup/engines/$name" -OutFile $tmp -UseBasicParsing
    return $tmp
}

# ---- engines (what the launcher's VoiceEngines.Pocket / Omni check)
function PocketReady([string]$python) {
    if (-not $python -or -not (Test-Path -LiteralPath $python)) { return $false }
    $dir = Split-Path $python
    return (Test-Path -LiteralPath (Join-Path $dir "Lib\site-packages\pocket_tts")) -or (Test-Path -LiteralPath (Join-Path $dir "..\Lib\site-packages\pocket_tts"))
}
function OmniReady([string]$folder) {
    return $folder -and (Test-Path -LiteralPath (Join-Path $folder "python\python.exe")) -and
        (Test-Path -LiteralPath (Join-Path $folder "python\Lib\site-packages\omnivoice_server")) -and -not (Test-Path -LiteralPath (Join-Path $folder "installing.txt"))
}

function Gpu {
    try {
        $line = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($line -match '^(.+),\s*(\d+)\s*$') { return @{ Name = $Matches[1].Trim(); Mb = [int]$Matches[2]; Nvidia = $true } }
    } catch { }
    try {
        $v = Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -First 1
        return @{ Name = $v.Name; Mb = 0; Nvidia = ($v.Name -match "NVIDIA") }
    } catch { }
    return @{ Name = ""; Mb = 0; Nvidia = $false }
}

# The launcher's installer script, run the same way: copied into the folder, hidden, its step in installing.txt
function InstallEngine([string]$kind, [string]$folder) {
    $name = if ($kind -eq "pocket") { "install_pocket.ps1" } else { "install_omnivoice.ps1" }
    New-Item -ItemType Directory -Force $folder | Out-Null
    $script = Join-Path $folder $name
    Copy-Item -LiteralPath (EngineScript $name) $script -Force
    $flag = Join-Path $folder "installing.txt"
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -WorkingDirectory $folder -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`"", "-Folder", "`"$folder`"", "-Language", $Language)
    $last = ""; $since = Get-Date
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 800
        $now = ""
        try { if (Test-Path -LiteralPath $flag) { $now = (Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim() } } catch { }
        if ($now -and $now -ne $last) { $last = $now; $since = Get-Date; Say ("... " + $now) }
        elseif (((Get-Date) - $since).TotalSeconds -ge 60) { $since = Get-Date; Say (T "... still working ($last)" "... sigue trabajando ($last)") }
    }
    $left = ""
    try { if (Test-Path -LiteralPath $flag) { $left = (Get-Content -LiteralPath $flag -Raw -Encoding UTF8).Trim() } } catch { }
    if ($left.StartsWith("error")) { return $left.Substring(5).TrimStart(':', ' ') }
    $ok = if ($kind -eq "pocket") { PocketReady (Join-Path $folder "python\python.exe") } else { OmniReady $folder }
    if (-not $ok) { return T "the installer stopped without finishing" "el instalador se detuvo sin terminar" }
    return ""
}

# ---- config.json: merged by Python (keeps every other setting, its order and its letters)
$MergePy = @'
import io, json, os, sys
path, patch_path = sys.argv[1], sys.argv[2]
patch = json.load(io.open(patch_path, encoding="utf-8-sig"))
config = {}
if os.path.exists(path):
    try:
        config = json.load(io.open(path, encoding="utf-8-sig"))
    except ValueError as e:
        print("config.json is not valid JSON, left as it is: %s" % e); sys.exit(3)
    if not isinstance(config, dict):
        print("config.json is not an object, left as it is"); sys.exit(3)

def merge(dst, src, force):
    for k, v in src.items():
        if isinstance(v, dict):
            if not isinstance(dst.get(k), dict):
                if k in dst and not force: continue
                dst[k] = {}
            merge(dst[k], v, force)
        elif force or k not in dst or dst[k] in ("", None):
            dst[k] = v

before = json.dumps(config, sort_keys=True)
merge(config, patch.get("set", {}), True)
merge(config, patch.get("default", {}), False)
if json.dumps(config, sort_keys=True) == before:
    print("unchanged"); sys.exit(0)
if os.path.exists(path):
    bak = path + ".bak"
    if not os.path.exists(bak):
        io.open(bak, "wb").write(io.open(path, "rb").read())
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("written")
'@

function MergeConfig([string]$python, [string]$config, $set, $default) {
    $py = Join-Path $env:TEMP "vaulttalk-merge.py"
    $patchFile = Join-Path $env:TEMP "vaulttalk-patch.json"
    [IO.File]::WriteAllText($py, $MergePy, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($patchFile, (@{ set = $set; default = $default } | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    try {
        $out = & $python -I $py $config $patchFile 2>&1
        return @{ Code = $LASTEXITCODE; Text = ($out -join " ") }
    } finally {
        Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue   # it may hold the key
    }
}

# ---- Player2: the app's one-step login when it's open, else the browser (device code)
function Player2Key {
    try {
        $r = Invoke-RestMethod -Method Post "$Player2App/login/web/$Player2ClientId" -Body "{}" -ContentType "application/json" -TimeoutSec 4
        if ($r.p2Key) { Good (T "Player2's app is open: linked." "La app de Player2 está abierta: enlazado."); return $r.p2Key }
    } catch { }
    $d = Invoke-RestMethod -Method Post "$Player2Api/login/device/new" -Body (@{ client_id = $Player2ClientId } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
    $device = if ($d.deviceCode) { $d.deviceCode } else { $d.device_code }
    $code = if ($d.userCode) { $d.userCode } else { $d.user_code }
    $page = if ($d.verificationUriComplete) { $d.verificationUriComplete } elseif ($d.verificationUri) { $d.verificationUri } else { "https://player2.game" }
    $interval = [math]::Max(1, [int]$(if ($d.interval) { $d.interval } else { 5 }))
    $expires = [math]::Max(30, [int]$(if ($d.expiresIn) { $d.expiresIn } else { 600 }))
    if (-not $device) { throw (T "Player2 didn't give a code." "Player2 no entregó un código.") }
    Say (T "Your browser opens Player2: sign in and approve Vault-Talk. Code: $code" "Tu navegador abre Player2: inicia sesión y aprueba a Vault-Talk. Código: $code")
    Say (T "(If it doesn't open: $page)" "(Si no se abre: $page)")
    try { Start-Process $page } catch { }
    $deadline = (Get-Date).AddSeconds($expires)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        $body = @{ client_id = $Player2ClientId; device_code = $device; grant_type = "urn:ietf:params:oauth:grant-type:device_code" } | ConvertTo-Json
        try {
            $t = Invoke-RestMethod -Method Post "$Player2Api/login/device/token" -Body $body -ContentType "application/json" -TimeoutSec 20
            if ($t.p2Key) { return $t.p2Key }
        } catch {
            $err = ""
            try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { }
            if ($err -eq "access_denied") { throw (T "Access denied on Player2." "Acceso denegado en Player2.") }
            if ($err -eq "expired_token") { break }
            if ($err -eq "slow_down") { $interval += 2 }
        }
    }
    throw (T "The code expired. Run this again." "El código expiró. Vuelve a ejecutar esto.")
}

# ---- one spoken line through the mod's own engine.py, as the launcher's voice test does
function SpeakTest([string]$python, [string]$modDir) {
    $script = Join-Path $modDir "engine.py"
    if (-not (Test-Path -LiteralPath $script)) { return T "the mod's engine.py isn't there" "no está el engine.py del mod" }
    $wav = Join-Path $HomeDir "test\voice-setup.wav"
    New-Item -ItemType Directory -Force (Split-Path $wav) | Out-Null
    Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
    $psi = New-Object Diagnostics.ProcessStartInfo($python, "`"$script`" 4")
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $modDir
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
    $psi.EnvironmentVariables["HF_HUB_DISABLE_XET"] = "1"
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    function Send($obj, [int]$seconds) {
        if ($obj) {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 5) + "`n")
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush()
        }
        $read = $p.StandardOutput.ReadLineAsync()
        if (-not $read.Wait($seconds * 1000)) { throw (T "the voice engine didn't answer in time" "el motor de voz no respondió a tiempo") }
        if ($null -eq $read.Result) { throw (T "the voice engine closed" "el motor de voz se cerró") }
        return $read.Result | ConvertFrom-Json
    }
    try {
        Say (T "Starting Pocket TTS (the first time it downloads its model, a few minutes)..." "Abriendo Pocket TTS (la primera vez descarga su modelo, unos minutos)...")
        Send $null 600 | Out-Null
        Send @{ op = "setup"; quality = "high"; steps = 1 } 120 | Out-Null
        $line = T "Vault-Talk here. If you can hear me, my voice is ready for the wasteland." "Aquí Vault-Talk. Si me escuchas, mi voz está lista para el yermo."
        $reply = Send @{ op = "say"; text = $line; language = $Language; out = $wav; voice = "marius"; fallback = "marius" } 900
        if (-not $reply.ok -or -not (Test-Path -LiteralPath $wav)) { $e = "$($reply.error)"; if (-not $e) { $e = T "no voice file" "sin archivo de voz" }; return $e }
        if (-not $Quiet) { try { (New-Object Media.SoundPlayer $wav).PlaySync() } catch { } }
        return ""
    } catch {
        $tail = ""
        try { if ($errTask.Wait(2000)) { $tail = ($errTask.Result -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) } } catch { }
        return ($_.Exception.Message + $(if ($tail) { ": $tail" } else { "" }))
    } finally {
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
    }
}

# =====================================================================================================
Write-Host ""
Write-Host (T "  Vault-Talk - voices for Courier's Company and Survivor's Company" "  Vault-Talk - voces para Courier's Company y Survivor's Company") -ForegroundColor White
Write-Host (T "  It installs a voice engine and its tools, and sets them in the mods' config.json." "  Instala un motor de voz y sus herramientas, y los configura en el config.json de los mods.")
Log "---- voice setup, language $Language"

# ---- 1. games
Title (T "1. Your games" "1. Tus juegos")
$targets = @()
foreach ($def in $Defs) {
    foreach ($g in FindGames $def) {
        $place = ModPlace $def $g
        $how = if ($place.Manager) { " ($($place.Manager))" } else { "" }
        if ($place.Dir) { Good "$($def.Name)$how - $($def.Mod): $g"; $targets += @{ Def = $def; Game = $g; Dir = $place.Dir } }
        else { Warn ((T "$($def.Name)$how at $g - $($def.Mod) isn't installed there yet" "$($def.Name)$how en $g - $($def.Mod) todavía no está instalado ahí")) }
    }
}
if ($targets.Count -eq 0) {
    Warn (T "No game with the mod installed was found." "No encontré ningún juego con el mod instalado.")
    $manual = Ask (T "Paste the game's folder (or press Enter to only install the voices):" "Pega la carpeta del juego (o pulsa Enter para solo instalar las voces):") ""
    if ($manual) {
        $manual = $manual.Trim('"')
        foreach ($def in $Defs) {
            if (Test-Path -LiteralPath (Join-Path $manual $def.Exe)) {
                $place = ModPlace $def $manual
                if ($place.Dir) { Good "$($def.Name): $manual"; $targets += @{ Def = $def; Game = $manual; Dir = $place.Dir } }
                else { Warn (T "$($def.Mod) isn't in that game. Install the mod first, then run this again." "$($def.Mod) no está en ese juego. Instala el mod primero y vuelve a ejecutar esto.") }
            }
        }
    }
    if ($targets.Count -eq 0) { Say (T "The voices install anyway; run this again after installing the mod to set them up." "Las voces se instalan igual; vuelve a ejecutar esto después de instalar el mod para configurarlas.") }
}

$manifest = LoadManifest
if (-not $manifest) { Stop-Setup (T "Couldn't read the list of downloads (no internet?)." "No pude leer la lista de descargas (¿sin internet?).") }

# what the games' config.json already say
function ReadConfig($t) {
    $f = Join-Path $t.Dir "config.json"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

# ---- 2. the AI (optional, before the long download so you can leave it running)
$p2Key = ""
if (-not $SkipAi -and $targets.Count -gt 0) {
    Title (T "2. The AI (Player2)" "2. La IA (Player2)")
    $hasAi = $targets | Where-Object { $c = ReadConfig $_; $c -and $c.llm -and $c.llm.key }
    Say (T "Player2 is free to start and needs nothing to copy: you approve it in your browser." "Player2 es gratis para empezar y no hay nada que copiar: lo apruebas en tu navegador.")
    $question = if ($hasAi) { T "Your mod already has an AI set. Replace it with Player2?" "Tu mod ya tiene una IA configurada. ¿Reemplazarla por Player2?" } else { T "Connect Player2 now?" "¿Conectar Player2 ahora?" }
    if (Yes $question (-not $hasAi)) {
        try { $p2Key = Player2Key; Good (T "Player2 connected (the key goes only into config.json)." "Player2 conectado (la clave va solo al config.json).") }
        catch { Warn ($_.Exception.Message + " " + (T "You can connect it later on the guide's page or in the launcher." "Puedes conectarlo después en la página de la guía o en el launcher.")) }
    }
}

# ---- 3. the voice engine
Title (T "3. Voice engine" "3. Motor de voz")
$gpu = Gpu
$pocketPython = Join-Path $PocketDir "python\python.exe"
$haveOmni = OmniReady $OmniDir
foreach ($t in $targets) {
    $c = ReadConfig $t
    if ($c -and $c.voice) {
        if (-not (PocketReady $pocketPython) -and (PocketReady "$($c.voice.python)")) { $pocketPython = "$($c.voice.python)" }
        if (-not $haveOmni -and $c.voice.omnivoice -and (OmniReady "$($c.voice.omnivoice.dir)")) { $OmniDir = "$($c.voice.omnivoice.dir)"; $haveOmni = $true }
    }
}
$havePocket = PocketReady $pocketPython
$pm = $manifest.engines.pocket; $om = $manifest.engines.omnivoice
$gpuText = if ($gpu.Name) { $gpu.Name + $(if ($gpu.Mb) { ", " + (Gb $gpu.Mb) + " GB" } else { "" }) } else { T "not detected" "no detectada" }
Say ((T "Graphics card: " "Tarjeta de video: ") + $gpuText)
$canOmni = $gpu.Nvidia -and ($gpu.Mb -eq 0 -or $gpu.Mb -ge 6000)
$roomy = $gpu.Nvidia -and $gpu.Mb -ge 10000
if (-not $Engine) {
    Say ""
    Say ((T "[1] Pocket TTS - runs on the processor, any PC. Download about " "[1] Pocket TTS - corre en el procesador, cualquier PC. Descarga unos ") + (Gb $pm.sizeMb) + " GB, " + (T "uses " "ocupa ") + (Gb $pm.diskMb) + " GB." + $(if ($havePocket) { T " (already installed)" " (ya instalado)" } else { "" }))
    Say ((T "[2] OmniVoice - better cloned voices, needs an NVIDIA card with 6 GB or more (10 GB is comfortable next to the game). Download about " "[2] OmniVoice - voces clonadas mejores, necesita una tarjeta NVIDIA con 6 GB o más (10 GB va holgado junto al juego). Descarga unos ") + (Gb ($om.sizeMb + $(if ($havePocket) { 0 } else { $pm.sizeMb }))) + " GB, " + (T "uses " "ocupa ") + (Gb ($om.diskMb + $(if ($havePocket) { 0 } else { $pm.diskMb }))) + " GB" + (T " (Pocket included: it prepares each voice)." " (incluye Pocket: prepara cada voz).") + $(if ($haveOmni) { T " (already installed)" " (ya instalado)" } else { "" }))
    if ($canOmni -and -not $roomy) { Warn (T "With 6 to 10 GB, sharing the card with the game a line can take half a minute or more: Pocket is the safe choice." "Con 6 a 10 GB, al compartir la tarjeta con el juego una frase puede tardar medio minuto o más: Pocket es lo seguro.") }
    if (-not $canOmni) { Say (T "This PC doesn't seem to have a suitable NVIDIA card: Pocket TTS is the one for it." "Esta PC no parece tener una tarjeta NVIDIA adecuada: Pocket TTS es el indicado.") }
    $suggest = if ($roomy) { "2" } else { "1" }
    $pick = Ask ((T "Which one? [1/2] (Enter = " "¿Cuál? [1/2] (Enter = ") + $suggest + ")") $suggest
    $Engine = if ($pick -eq "2") { "omnivoice" } else { "pocket" }
}
if ($Engine -eq "omnivoice" -and -not $canOmni -and -not (Yes (T "OmniVoice needs an NVIDIA card with 6 GB or more. Install it anyway?" "OmniVoice necesita una tarjeta NVIDIA con 6 GB o más. ¿Instalarlo igual?") $false)) { $Engine = "pocket" }

$needMb = 0
if (-not $havePocket) { $needMb += $pm.diskMb }
if ($Engine -eq "omnivoice" -and -not $haveOmni) { $needMb += $om.diskMb }
if ($needMb -gt 0) {
    $free = FreeMb $Engines
    Say ((T "It goes into " "Se instala en ") + $Engines)
    if ($free -ge 0 -and $free -lt $needMb) { Stop-Setup ((T "It needs about " "Necesita unos ") + (Gb $needMb) + (T " GB free on that disk; there are " " GB libres en ese disco; hay ") + (Gb $free) + " GB.") }
    Say ((T "Downloads come from " "Las descargas vienen de ") + $pm.sources + (T ". It can take a while: leave this window open." ". Puede tardar un rato: deja esta ventana abierta."))
}
if (-not $havePocket) {
    Say "Pocket TTS:"
    $why = InstallEngine "pocket" $PocketDir
    if ($why) { Stop-Setup ("Pocket TTS: $why  " + (Hint $why)) }
    $pocketPython = Join-Path $PocketDir "python\python.exe"
    Good (T "Pocket TTS installed." "Pocket TTS instalado.")
} else { Good ((T "Pocket TTS already installed: " "Pocket TTS ya instalado: ") + $pocketPython) }
if ($Engine -eq "omnivoice") {
    if (-not $haveOmni) {
        Say (T "OmniVoice (the model is about 3 GB; it's downloaded now, not in the game):" "OmniVoice (el modelo pesa unos 3 GB; se descarga ahora, no en el juego):")
        $why = InstallEngine "omnivoice" $OmniDir
        if ($why) { Stop-Setup ("OmniVoice: $why  " + (Hint $why)) }
        Good (T "OmniVoice installed and answered." "OmniVoice instalado y respondió.")
    } else { Good ((T "OmniVoice already installed: " "OmniVoice ya instalado: ") + $OmniDir) }
}

# ---- 4. the tools for game voice files
Title (T "4. Tools for the game's voice files" "4. Herramientas para los archivos de voz del juego")
$lipOk = $false; $xwmaOk = Test-Path -LiteralPath $XwmaFile
try {
    $wrapper = Join-Path $LipDir "FaceFXWrapper.exe"; $fonix = Join-Path $LipDir "FonixData.cdf"
    if (-not (Test-Path -LiteralPath $wrapper)) {
        $src = $manifest.tools.facefx
        Say ("FaceFXWrapper (" + [math]::Round($src.size / 1MB) + " MB, github.com/Nukem9)")
        $zip = Join-Path $HomeDir "downloads\FaceFXWrapper.zip"
        Fetch $src.url $zip $src.sha256
        New-Item -ItemType Directory -Force $LipDir | Out-Null
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($e in $archive.Entries) {
                if ($e.Name -ieq "FaceFXWrapper.exe" -or $e.Name -ieq "FonixData.cdf") { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $LipDir $e.Name), $true) }
            }
        } finally { $archive.Dispose() }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $fonix)) {
        $src = $manifest.tools.fonix
        $own = $targets | ForEach-Object { Join-Path $_.Game "Data\Sound\Voice\Processing\FonixData.cdf" } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($src.url) { Say "FonixData.cdf"; Fetch $src.url $fonix $src.sha256 }
        elseif ($own) { Copy-Item -LiteralPath $own $fonix }
    }
    $lipOk = (Test-Path -LiteralPath $wrapper) -and (Test-Path -LiteralPath $fonix)
    if ($lipOk) { Good (T "FaceFXWrapper + FonixData.cdf (mouth movement)" "FaceFXWrapper + FonixData.cdf (movimiento de la boca)") }
    else { Warn (T "FonixData.cdf is missing: the voices play without mouth movement." "Falta FonixData.cdf: las voces suenan sin movimiento de boca.") }
} catch { Warn ("FaceFXWrapper: " + $_.Exception.Message + "  " + (T "The voices play without mouth movement." "Las voces suenan sin movimiento de boca.")) }
if ($targets | Where-Object { $_.Def.Xwma }) {
    try {
        if (-not $xwmaOk -and $manifest.tools.xwma.url) { Say "xWMAEncode (Microsoft, DirectX SDK)"; Fetch $manifest.tools.xwma.url $XwmaFile $manifest.tools.xwma.sha256 }
        $xwmaOk = Test-Path -LiteralPath $XwmaFile
        if ($xwmaOk) { Good (T "xWMAEncode (Fallout 4's voice files)" "xWMAEncode (archivos de voz de Fallout 4)") }
        else { Warn ((T "xWMAEncode is missing: install the DirectX SDK from " "Falta xWMAEncode: instala el DirectX SDK desde ") + $manifest.tools.xwma.page) }
    } catch { Warn ("xWMAEncode: " + $_.Exception.Message) }
}

# ---- 5. the games' config.json
Title (T "5. Settings in each game" "5. Ajustes en cada juego")
foreach ($t in $targets) {
    $def = $t.Def
    while (Get-Process $def.Process -ErrorAction SilentlyContinue) {
        Warn (T "$($def.Name) is running: close it (it rewrites its settings on exit)." "$($def.Name) está abierto: ciérralo (reescribe sus ajustes al salir).")
        Read-Host ("   " + (T "Press Enter when it's closed" "Pulsa Enter cuando esté cerrado")) | Out-Null
    }
    $voice = @{ enabled = $true; engine = $Engine; python = $pocketPython }
    $voiceDefault = @{}
    if ($Engine -eq "omnivoice") { $voice.omnivoice = @{ dir = $OmniDir }; $voiceDefault.omnivoice = @{ url = "http://127.0.0.1:8880" } }
    if ($lipOk) { $voice.lipTool = $LipDir }
    if ($def.Xwma -and $xwmaOk) { $voice.xwmaEncode = $XwmaFile }
    $set = @{ voice = $voice }
    if ($p2Key) { $set.llm = @{ url = $Player2Api; model = "player2"; key = $p2Key } }
    $file = Join-Path $t.Dir "config.json"
    $r = MergeConfig $pocketPython $file $set @{ voice = $voiceDefault }
    if ($r.Code -eq 0) { Good ("$($def.Mod): $file" + $(if ($r.Text -match "unchanged") { T " (already set)" " (ya estaba)" } else { "" })) }
    else { Bad ("$($def.Mod): $($r.Text)") }
}
$p2Key = $null

# ---- 6. one spoken line
if (-not $SkipTest) {
    Title (T "6. Test" "6. Prueba")
    $withMod = $targets | Where-Object { Test-Path -LiteralPath (Join-Path $_.Dir "engine.py") } | Select-Object -First 1
    if ($withMod) {
        $why = SpeakTest $pocketPython $withMod.Dir
        if ($why) { Warn ("Pocket TTS: $why  " + (Hint $why)) } else { Good (T "You should have heard a line. The voices are ready." "Deberías haber escuchado una frase. Las voces están listas.") }
    } else { Say (T "No mod installed yet to speak through: the voices are checked when you install it and play." "Todavía no hay un mod instalado para hablar a través de él: las voces se prueban cuando lo instales y juegues.") }
}

Title (T "Done" "Listo")
Say (T "Start the game as usual. The mod tells you in the game when the voices are ready, or what failed." "Abre el juego como siempre. El mod te avisa en el juego cuando las voces están listas, o qué falló.")
Say (T "If something fails: the mod's log.txt is next to its config.json; this setup's log is $LogFile." "Si algo falla: el log.txt del mod está junto a su config.json; el registro de esta instalación es $LogFile.")
Say (T "To change engines later, run this again or use the launcher." "Para cambiar de motor más adelante, vuelve a ejecutar esto o usa el launcher.")
exit 0
