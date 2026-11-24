# Vault-Talk: installs OmniVoice (https://github.com/k2-fsa/OmniVoice) with omnivoice-server, the
# voice engine for NVIDIA cards of Courier's Company and Survivor's Company, into -Folder: a private
# Python, PyTorch for NVIDIA cards, the server and its model. The mods start the server themselves
# (python -m omnivoice_server) and clone each character's voice into perfiles\ from the player's
# own game files; nothing else is needed here.
# The launcher writes this script into -Folder and runs it hidden. Its step is in installing.txt
# ("error: ..." when it fails); the file goes away when it's ready.
# -SkipModel: the launcher downloads the model itself afterwards (OmniModel.cs, with progress); the
# standalone voice setup leaves it to this script
param([Parameter(Mandatory = $true)][string]$Folder, [string]$Language = "en", [switch]$SkipModel)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function L([string]$en, [string]$es) { if ($Language -eq "es") { $es } else { $en } }

$python = Join-Path $Folder "python"
$exe = Join-Path $python "python.exe"
$models = Join-Path $Folder "modelos"
$profiles = Join-Path $Folder "perfiles"
$flag = Join-Path $Folder "installing.txt"
New-Item -ItemType Directory -Force $Folder, $models, $profiles | Out-Null
# The embeddable Python has no Visual C++ runtime: without the redistributable, numpy's or torch's copy goes next to python.exe
function Msvcp {
    if (Test-Path (Join-Path $env:WINDIR "System32\msvcp140.dll")) { return }
    if (Test-Path (Join-Path $python "msvcp140.dll")) { return }
    foreach ($dir in @("Lib\site-packages\numpy.libs", "Lib\site-packages\torch\lib")) {
        $copy = Get-ChildItem (Join-Path $python $dir) -Filter "msvcp140*.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($copy) { Copy-Item $copy.FullName (Join-Path $python "msvcp140.dll"); return }
    }
}

function Step([string]$text) { [IO.File]::WriteAllText($flag, $text) }

function Run([string]$what, [string[]]$arguments) {
    $p = Start-Process $exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardError (Join-Path $Folder "error.txt") -RedirectStandardOutput (Join-Path $Folder "output.txt")
    if ($p.ExitCode -ne 0) {
        $tail = (Get-Content (Join-Path $Folder "error.txt") -Tail 3 -ErrorAction SilentlyContinue) -join " "
        if (-not $tail.Trim()) { $tail = (Get-Content (Join-Path $Folder "output.txt") -Tail 3 -ErrorAction SilentlyContinue) -join " " }
        throw "$what ($($p.ExitCode)): $tail"
    }
}

try {
    if (-not (Test-Path $exe)) {
        Step (L "downloading Python (11 MB)" "descargando Python (11 MB)")
        $zip = Join-Path $Folder "python.zip"
        Invoke-WebRequest "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip $python -Force
        Remove-Item $zip
        # the embeddable Python ignores site-packages until "import site" is on
        $pth = Get-ChildItem $python -Filter "python*._pth" | Select-Object -First 1
        $lines = (Get-Content $pth.FullName) -replace '^#\s*import site', 'import site'
        Set-Content $pth.FullName $lines -Encoding ASCII
    }
    if (-not (Test-Path (Join-Path $python "Lib\site-packages\pip\__init__.py"))) {
        Step (L "installing pip" "instalando pip")
        $release = Invoke-RestMethod "https://pypi.org/pypi/pip/26.2.2/json" -UseBasicParsing
        $wheel = $release.urls | Where-Object { $_.packagetype -eq "bdist_wheel" } | Select-Object -First 1
        $zip = Join-Path $Folder "pip.zip"
        Invoke-WebRequest $wheel.url -OutFile $zip -UseBasicParsing
        Expand-Archive $zip (Join-Path $python "Lib\site-packages") -Force
        Remove-Item $zip
        Run "pip" @("-m", "pip", "--version")
    }
    # the versions it was tested with: a new release can't break it
    Step (L "downloading PyTorch for NVIDIA cards (about 3 GB)" "descargando PyTorch para tarjetas NVIDIA (unos 3 GB)")
    Run "PyTorch" @("-m", "pip", "install", "-q", "--no-warn-script-location", "torch==2.8.0", "torchaudio==2.8.0", "--index-url", "https://download.pytorch.org/whl/cu128")
    Step (L "downloading OmniVoice (about 500 MB)" "descargando OmniVoice (unos 500 MB)")
    Run "OmniVoice" @("-m", "pip", "install", "-q", "--no-warn-script-location", "omnivoice==0.1.5", "omnivoice-server==0.2.5")
    Msvcp
    if (-not (Test-Path (Join-Path $python "Lib\site-packages\omnivoice_server"))) { throw (L "omnivoice-server didn't install." "omnivoice-server no se instalo.") }

    # the model, now, so the first line in the game doesn't wait for 3 GB (the mods only download it
    # when there's none, and never update it). Straight from Hugging Face's cache tools (they resume a
    # cut download); the server isn't started for it.
    if (-not $SkipModel) {
        Step (L "downloading OmniVoice's model (about 3 GB)" "descargando el modelo de OmniVoice (unos 3 GB)")
        $env:HF_HOME = $models
        # Hugging Face's newer downloader (Xet) breaks halfway for some players: the plain HTTP download
        $env:HF_HUB_DISABLE_XET = "1"
        $env:PYTHONIOENCODING = "utf-8"
        $starts = 0
        while ($true) {
            $starts++
            try { Run "OmniVoice's model" @("-c", "`"from huggingface_hub import snapshot_download; snapshot_download('k2-fsa/OmniVoice')`""); break }
            catch { if ($starts -ge 3) { throw }; Step (L "downloading OmniVoice's model (about 3 GB), try $($starts + 1) of 3" "descargando el modelo de OmniVoice (unos 3 GB), intento $($starts + 1) de 3"); Start-Sleep -Seconds 5 }
        }
    }
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
} catch {
    Step ("error: " + $_.Exception.Message)
    exit 1
}
