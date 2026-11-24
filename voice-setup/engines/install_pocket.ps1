# Vault-Talk: installs Pocket TTS (the CPU voice engine of Courier's Company and Survivor's Company)
# into -Folder, with nothing for the player to set up: a private Python (python.org's embeddable
# one), pip, PyTorch for the CPU, pocket-tts and faster-whisper (which the mods use to write down
# what a cloned sample says). The models download the first time a character speaks.
# The launcher writes this script into -Folder and runs it hidden. Its step is in installing.txt
# ("error: ..." when it fails); the file goes away when it's ready.
param([Parameter(Mandatory = $true)][string]$Folder, [string]$Language = "en")
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$python = Join-Path $Folder "python"
$exe = Join-Path $python "python.exe"
$flag = Join-Path $Folder "installing.txt"
New-Item -ItemType Directory -Force $Folder | Out-Null
# Python reads redirected files in Windows' own code page unless told otherwise
$env:PYTHONIOENCODING = "utf-8"
# Hugging Face's newer downloader (Xet) breaks halfway for some players: plain HTTP instead
$env:HF_HUB_DISABLE_XET = "1"

# The embeddable Python has no Visual C++ runtime: without the redistributable, numpy's or torch's copy goes next to python.exe
function Msvcp {
    if (Test-Path (Join-Path $env:WINDIR "System32\msvcp140.dll")) { return }
    if (Test-Path (Join-Path $python "msvcp140.dll")) { return }
    foreach ($dir in @("Lib\site-packages\numpy.libs", "Lib\site-packages\torch\lib")) {
        $copy = Get-ChildItem (Join-Path $python $dir) -Filter "msvcp140*.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($copy) { Copy-Item $copy.FullName (Join-Path $python "msvcp140.dll"); return }
    }
}

function L([string]$en, [string]$es) { if ($Language -eq "es") { $es } else { $en } }
function Step([string]$text) { [IO.File]::WriteAllText($flag, $text) }

function Run([string]$what, [string[]]$arguments) {
    $p = Start-Process $exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardError (Join-Path $Folder "error.txt") -RedirectStandardOutput (Join-Path $Folder "output.txt")
    if ($p.ExitCode -ne 0) {
        $tail = (Get-Content (Join-Path $Folder "error.txt") -Tail 3 -ErrorAction SilentlyContinue) -join " "
        if (-not $tail.Trim()) { $tail = (Get-Content (Join-Path $Folder "output.txt") -Tail 3 -ErrorAction SilentlyContinue) -join " " }
        if (-not $tail.Trim()) { $tail = (L "no message, exit code $($p.ExitCode) (an antivirus?)" "sin mensaje, codigo $($p.ExitCode) (un antivirus?)") }
        throw (L "$what failed: $tail" "$what fallo: $tail")
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
    # pip, unpacked straight from its wheel (pure Python): a fixed version, so a new pip can't break the install
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
    Step (L "downloading PyTorch for CPU (about 200 MB)" "descargando PyTorch para CPU (unos 200 MB)")
    # the versions it was tested with: a new release can't break it
    Run "PyTorch" @("-m", "pip", "install", "-q", "--no-warn-script-location", "torch==2.15.0", "--index-url", "https://download.pytorch.org/whl/cpu")
    Step (L "downloading Pocket TTS and faster-whisper" "descargando Pocket TTS y faster-whisper")
    # soundfile (libsndfile with Vorbis inside its wheel): Courier's Company turns each line into Ogg Vorbis with it
    Run "Pocket TTS" @("-m", "pip", "install", "-q", "--no-warn-script-location", "pocket-tts==4.0.1", "faster-whisper==1.2.1", "soundfile==0.14.0")
    Msvcp
    # Start-Process splits arguments at spaces: the code goes in as one quoted piece
    Run "Pocket TTS" @("-c", '"import pocket_tts,faster_whisper,av,soundfile,numpy"')
    Remove-Item $flag -ErrorAction SilentlyContinue
} catch {
    Step "error: $($_.Exception.Message)"
    exit 1
}
