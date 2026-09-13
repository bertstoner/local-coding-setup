<#
.SYNOPSIS
    Sets up a fully local coding assistant: Ollama + qwen3-coder +
    Aider (CLI) + OpenCode (CLI) + Cline (VS Code + CLI).

.DESCRIPTION
    1. Ensures Ollama is installed (offers to install via winget if missing).
    2. Ensures the Ollama server is reachable.
    3. Ensures a coding-focused model is pulled (default: qwen3-coder);
       tries Ollama registry then HuggingFace, with guided manual GGUF
       import as a final fallback for restricted networks (Zscaler, etc.).
    4. Ensures Python/pip is available and installs Aider (aider-chat).
    5. Ensures Node.js/npm is available and installs OpenCode (opencode-ai).
    6. Writes launchers + PowerShell profile functions for aider-local and
       opencode-local.
    7. Installs the Cline VS Code extension (also usable as 'cline' CLI).

.NOTES
    TOOL-CALLING STATUS (tested September 2026 with qwen3-coder):
      - OpenCode + qwen3-coder:  PASS -- successfully wrote files via tool calls (5.9s)
      - Aider + qwen3-coder:     PASS -- plain-text diff mode, 54s on LRU cache benchmark
      - Cline + qwen3-coder:     PASS -- XML-tagged actions, works in both VS Code and CLI
      - Claude Code + qwen3-coder: FAIL -- still cannot emit structured tool_use blocks

    Older models (qwen2.5-coder, devstral, llama3.1) failed tool-calling in
    both Claude Code and OpenCode. qwen3-coder is the first local model we
    tested that can reliably invoke tools in an agent harness (OpenCode).
    Claude Code's more complex system prompt still breaks it.
#>

[CmdletBinding()]
param(
    [string]$OllamaHost = "http://localhost:11434",
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    ! $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    ERROR: $msg" -ForegroundColor Red }

# Curated coding-focused models to offer for download, good quality choices
# for Aider (Aider doesn't depend on native tool-calling, so pick for coding
# quality, not tool-call template support).
# Ordered by BENCHMARKED result (Aider + real LRU-cache-with-assertions task,
# timed end-to-end, output actually executed to check correctness):
#   qwen3-coder:latest      54s   PASS  <- new best: faster AND larger than 14b
#   qwen2.5-coder:14b       100s  PASS  (previous best, still solid)
#   qwen2.5-coder:32b       238s  PASS  (correct but ~4.4x slower than qwen3-coder)
#   deepseek-coder-v2:16b   128s  FAIL  (could not conform to Aider's edit
#                                        format after 3 retries)
$CodingModels = @(
    [pscustomobject]@{ Name = "qwen3-coder";       Size = "~18 GB";  Desc = "BENCHMARKED best: 54s, correct, 30B model -- fastest despite size" }
    [pscustomobject]@{ Name = "qwen2.5-coder:14b"; Size = "~9 GB";   Desc = "BENCHMARKED: 100s, correct -- previous best, smaller download" }
    [pscustomobject]@{ Name = "qwen2.5-coder:7b";  Size = "~4.7 GB"; Desc = "VERIFIED working with Aider, good for low-VRAM machines" }
    [pscustomobject]@{ Name = "devstral";          Size = "~14 GB";  Desc = "Mistral's agentic coding model, not benchmarked here" }
)
$CodingModelPattern = 'coder|codestral|starcoder|codegemma|codellama|deepseek-coder|granite-code|devstral'
$PreferredCodingModel = 'qwen3-coder:latest'

# ---------------------------------------------------------------------------
# Step 1: Ollama installed?
# ---------------------------------------------------------------------------
Write-Step "Checking for Ollama installation"

$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCmd) {
    Write-Warn "Ollama is not installed."
    if ($NonInteractive) { Write-Err "Non-interactive mode: cannot prompt to install. Aborting."; exit 1 }
    $resp = Read-Host "Install Ollama now via winget? [Y/n]"
    if ($resp -match '^(n|no)$') {
        Write-Err "Ollama is required. Install it from https://ollama.com/download and re-run this script."
        exit 1
    }
    winget install --id Ollama.Ollama -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Write-Err "winget install failed. Install manually from https://ollama.com/download."; exit 1 }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollamaCmd) { Write-Err "Ollama installed but 'ollama' isn't on PATH yet. Open a new terminal and re-run this script."; exit 1 }
}
Write-Ok "Ollama found: $((& ollama --version) -join ' ')"

# ---------------------------------------------------------------------------
# Step 2: Ollama server reachable?
# ---------------------------------------------------------------------------
Write-Step "Checking Ollama server at $OllamaHost"

function Test-OllamaServer {
    try { $null = Invoke-RestMethod -Uri "$OllamaHost/api/version" -TimeoutSec 5; return $true }
    catch { return $false }
}

if (-not (Test-OllamaServer)) {
    Write-Warn "Ollama server not reachable. Attempting to start it..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    $tries = 0
    while (-not (Test-OllamaServer) -and $tries -lt 15) { Start-Sleep -Seconds 1; $tries++ }
    if (-not (Test-OllamaServer)) { Write-Err "Could not reach Ollama server after starting it. Launch the Ollama app manually and re-run."; exit 1 }
}
Write-Ok "Ollama server is up"

# ---------------------------------------------------------------------------
# Step 3: A coding-focused model exists (pull one if not)
# ---------------------------------------------------------------------------
Write-Step "Checking installed models for a coding-focused one"

$installed = @()
try {
    $tagsResp = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 10
    $installed = $tagsResp.models | ForEach-Object { $_.name }
} catch { Write-Err "Failed to list installed models: $_"; exit 1 }

function Get-ModelSizeScore($name) {
    if ($name -match ':(\d+)b') { return [int]$Matches[1] }
    return 7  # unknown size, assume small/default
}

# Rank by benchmark evidence first (qwen2.5-coder:14b won time+correctness on
# this hardware), then fall back to largest-installed for anything unranked.
$existingCodingModels = @($installed | Where-Object { $_ -match $CodingModelPattern } | Sort-Object -Property `
    @{ Expression = { if ($_ -eq $PreferredCodingModel) { 0 } else { 1 } }; Descending = $false }, `
    @{ Expression = { Get-ModelSizeScore $_ }; Descending = $true })

$selectedModel = $null
if ($existingCodingModels.Count -gt 0) {
    Write-Ok "Found existing coding model(s): $($existingCodingModels -join ', ')"
    $selectedModel = $existingCodingModels[0]
    if ($existingCodingModels.Count -gt 1 -and -not $NonInteractive) {
        Write-Host "    Multiple coding models installed (benchmarked winner first):"
        for ($i = 0; $i -lt $existingCodingModels.Count; $i++) { Write-Host "      [$($i+1)] $($existingCodingModels[$i])" }
        $choice = Read-Host "    Pick one to use [1-$($existingCodingModels.Count)] (default 1, i.e. benchmarked best)"
        if (-not [string]::IsNullOrWhiteSpace($choice)) {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $existingCodingModels.Count) { $selectedModel = $existingCodingModels[$idx] }
        }
    }
} else {
    Write-Warn "No coding-focused model found locally."
    if ($NonInteractive) { Write-Err "Non-interactive mode: cannot prompt for a model to download. Aborting."; exit 1 }
    Write-Host "    Available coding models to download:`n"
    for ($i = 0; $i -lt $CodingModels.Count; $i++) {
        $m = $CodingModels[$i]
        Write-Host ("      [{0}] {1,-24} {2,-10} {3}" -f ($i+1), $m.Name, $m.Size, $m.Desc)
    }
    $choice = Read-Host "`n    Which model should we pull? [1-$($CodingModels.Count)] (default 1)"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $CodingModels.Count) { $idx = 0 }
    $selectedModel = $CodingModels[$idx].Name

    Write-Step "Pulling $selectedModel (this can take a while)"

    # Try multiple sources in order: Ollama registry, then HuggingFace
    # Corporate proxies (Zscaler, etc.) may block these; the script falls
    # back to guided manual GGUF import with links to additional mirrors.
    $pullSources = @(
        @{ Label = "Ollama registry";       Name = $selectedModel }
        @{ Label = "HuggingFace (hf.co)";   Name = "hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF" }
    )
    $pulled = $false
    foreach ($src in $pullSources) {
        Write-Host "    Trying: $($src.Label) ($($src.Name))..."
        & ollama pull $src.Name
        if ($LASTEXITCODE -eq 0) {
            $pulled = $true
            if ($src.Name -ne $selectedModel) {
                # Alternative sources land under a different name; remap selectedModel
                $selectedModel = $src.Name
            }
            Write-Ok "$selectedModel pulled from $($src.Label)"
            break
        }
        Write-Warn "Pull from $($src.Label) failed, trying next source..."
    }
    if (-not $pulled) {
        # All network sources failed -- offer guided manual GGUF import
        Write-Warn "All network download sources failed (corporate proxy may be blocking them)."
        Write-Host ""
        Write-Host "    === Manual GGUF import (works offline) ===" -ForegroundColor Yellow
        Write-Host "    If your network blocks model downloads, you can import a GGUF file manually:"
        Write-Host ""
        Write-Host "    1. Download the GGUF file (look for Q4_K_M, ~18 GB):" -ForegroundColor White
        Write-Host "       Try these sources -- different ones may work on different networks:"
        Write-Host "       - HuggingFace:  https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
        Write-Host "       - Kaggle:       https://kaggle.com/models  (search 'qwen3 coder gguf')"
        Write-Host "       - ModelScope:   https://modelscope.cn/models/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
        Write-Host "       - SourceForge:  https://sourceforge.net/projects/qwen3.mirror/"
        Write-Host ""
        Write-Host "    2. Get the .gguf file onto this machine:" -ForegroundColor White
        Write-Host "       - OneDrive/SharePoint: download at home, upload to OneDrive, sync here"
        Write-Host "       - Network share: place on a shared drive accessible from this machine"
        Write-Host "       - USB drive (if allowed by your org's policy)"
        Write-Host ""
        Write-Host "    3. Create a one-line Modelfile pointing at the GGUF:" -ForegroundColor White
        Write-Host '       echo "FROM C:\path\to\model.gguf" > Modelfile'
        Write-Host ""
        Write-Host "    4. Import into Ollama:" -ForegroundColor White
        Write-Host "       ollama create qwen3-coder -f Modelfile"
        Write-Host ""

        if (-not $NonInteractive) {
            $ggufPath = Read-Host "    Enter path to a local .gguf file now (or press Enter to abort)"
            if (-not [string]::IsNullOrWhiteSpace($ggufPath)) {
                $ggufPath = $ggufPath.Trim('"').Trim("'")
                if (-not (Test-Path $ggufPath)) {
                    Write-Err "File not found: $ggufPath"
                    exit 1
                }
                $modelfilePath = Join-Path $env:TEMP "ollama-manual-import-Modelfile"
                Set-Content -Path $modelfilePath -Value "FROM $ggufPath" -Encoding utf8
                Write-Host "    Importing GGUF into Ollama as 'qwen3-coder'..."
                & ollama create qwen3-coder -f $modelfilePath
                if ($LASTEXITCODE -eq 0) {
                    $pulled = $true
                    $selectedModel = "qwen3-coder:latest"
                    Write-Ok "Model imported from local GGUF file"
                    Remove-Item $modelfilePath -ErrorAction SilentlyContinue
                } else {
                    Write-Err "ollama create failed. Check the GGUF file and try again."
                    exit 1
                }
            }
        }
        if (-not $pulled) {
            Write-Err "No model available. Follow the manual import steps above and re-run."
            exit 1
        }
    }
}
Write-Ok "Using model: $selectedModel"

# ---------------------------------------------------------------------------
# Step 4: Install Aider
# ---------------------------------------------------------------------------
Write-Step "Checking for Aider (local-model-native coding assistant)"

$pyCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pyCmd) { $pyCmd = Get-Command py -ErrorAction SilentlyContinue }
if (-not $pyCmd) {
    Write-Warn "Python not found on this machine."
    if ($NonInteractive) { Write-Err "Non-interactive mode: cannot prompt to install. Aborting."; exit 1 }
    $resp = Read-Host "Install Python 3.12 now via winget? [Y/n]"
    if ($resp -match '^(n|no)$') {
        Write-Err "Python 3.9+ is required. Install from https://python.org and re-run."
        exit 1
    }
    winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Write-Err "winget install failed. Install Python manually from https://python.org."; exit 1 }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pyCmd) { $pyCmd = Get-Command py -ErrorAction SilentlyContinue }
    if (-not $pyCmd) { Write-Err "Python installed but not on PATH yet. Open a new terminal and re-run."; exit 1 }
}
$pyExe = $pyCmd.Source
Write-Ok "Python found: $(& $pyExe --version 2>&1)"

# Ensure pip --user Scripts dir is on PATH for this session (needed to find aider)
$userScripts = & $pyExe -c "import sysconfig; print(sysconfig.get_path('scripts', 'nt_user'))"
if ((Test-Path $userScripts) -and ($env:Path -notlike "*$userScripts*")) {
    $env:Path = "$env:Path;$userScripts"
}

$aiderCmd = Get-Command aider -ErrorAction SilentlyContinue
if (-not $aiderCmd) {
    Write-Warn "Aider not installed. Installing via pip (--user)..."
    & $pyExe -m pip install --user --quiet aider-chat
    if ($LASTEXITCODE -ne 0) { Write-Err "pip install aider-chat failed."; exit 1 }

    if (Test-Path $userScripts) { $env:Path = "$env:Path;$userScripts" }
    $aiderCmd = Get-Command aider -ErrorAction SilentlyContinue
    if (-not $aiderCmd) {
        Write-Warn "Aider installed but not found on PATH this session."
        Write-Warn "It's likely in: $userScripts"
        Write-Warn "Will attempt to add to your user PATH permanently."
    } else {
        Write-Ok "Aider installed: $((& aider --version) -join ' ')"
    }
} else {
    Write-Ok "Aider found: $((& aider --version) -join ' ')"
}

# Ensure pip --user Scripts dir is on permanent user PATH (so aider works in new shells)
if ($userScripts -and (Test-Path $userScripts)) {
    $currentUserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentUserPath -notlike "*$userScripts*") {
        Write-Warn "Adding pip user scripts dir to permanent user PATH: $userScripts"
        [System.Environment]::SetEnvironmentVariable("Path", "$currentUserPath;$userScripts", "User")
        Write-Ok "Added to user PATH (takes effect in new shells)"
    }
}

# ---------------------------------------------------------------------------
# Step 4b: Install OpenCode (tool-calling agent that works with qwen3-coder)
# ---------------------------------------------------------------------------
Write-Step "Checking for OpenCode (tool-calling coding agent)"

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Warn "Node.js not found on this machine."
    if ($NonInteractive) { Write-Err "Non-interactive mode: cannot prompt to install. Aborting."; exit 1 }
    $resp = Read-Host "Install Node.js LTS now via winget? [Y/n]"
    if ($resp -match '^(n|no)$') {
        Write-Warn "Skipping OpenCode install (requires Node.js). Aider will still work."
    } else {
        winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Write-Warn "winget install failed. Install Node.js from https://nodejs.org."; }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
        if (-not $nodeCmd) { Write-Warn "Node.js installed but not on PATH yet. Re-run after opening a new terminal." }
    }
}

$opencodeCmd = Get-Command opencode -ErrorAction SilentlyContinue
if ($nodeCmd -and -not $opencodeCmd) {
    Write-Warn "OpenCode not installed. Installing via npm..."
    npm install -g opencode-ai
    if ($LASTEXITCODE -ne 0) { Write-Warn "npm install opencode-ai failed. Aider will still work." }
    $opencodeCmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($opencodeCmd) { Write-Ok "OpenCode installed: $(opencode --version 2>&1)" }
} elseif ($opencodeCmd) {
    Write-Ok "OpenCode found: $(opencode --version 2>&1)"
}

# ---------------------------------------------------------------------------
# Step 5: Write launchers
# ---------------------------------------------------------------------------
Write-Step "Setting up launchers"

$scriptsDir = Join-Path $HOME ".local\bin"
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

# --- aider-local: the recommended, verified-working path for real coding tasks ---
$aiderLauncherPath = Join-Path $scriptsDir "aider-local.ps1"
$expectedLauncherContent = @"
# Auto-generated by setup-local-coding.ps1 on $(Get-Date -Format 'yyyy-MM-dd')
# Runs Aider against the local Ollama model '$selectedModel' in the current directory.
`$env:OLLAMA_API_BASE = "$OllamaHost"
aider --model ollama/$selectedModel @args
"@

$launcherNeedsUpdate = $true
if (Test-Path $aiderLauncherPath) {
    $existing = Get-Content $aiderLauncherPath -Raw
    if ($existing -match "ollama/$([regex]::Escape($selectedModel))") {
        $launcherNeedsUpdate = $false
        Write-Ok "Launcher already configured for $selectedModel"
    } else {
        $oldModel = if ($existing -match 'ollama/(\S+)') { $Matches[1] } else { "unknown" }
        Write-Warn "Launcher points at '$oldModel' but selected model is '$selectedModel' -- updating"
    }
}
if ($launcherNeedsUpdate) {
    Set-Content -Path $aiderLauncherPath -Value $expectedLauncherContent -Encoding utf8
    Write-Ok "Wrote launcher: $aiderLauncherPath"
}

# --- opencode-local: tool-calling agent verified working with qwen3-coder ---
$opencodeLauncherPath = Join-Path $scriptsDir "opencode-local.ps1"
$expectedOpencodeContent = @"
# Auto-generated by setup-local-coding.ps1 on $(Get-Date -Format 'yyyy-MM-dd')
# Runs OpenCode against the local Ollama model '$selectedModel' in the current directory.
`$env:OLLAMA_HOST = "$OllamaHost"
opencode --model ollama/$selectedModel @args
"@

$opencodeLauncherNeedsUpdate = $true
if (Test-Path $opencodeLauncherPath) {
    $existing = Get-Content $opencodeLauncherPath -Raw
    if ($existing -match "ollama/$([regex]::Escape($selectedModel))") {
        $opencodeLauncherNeedsUpdate = $false
        Write-Ok "OpenCode launcher already configured for $selectedModel"
    } else {
        $oldModel = if ($existing -match 'ollama/(\S+)') { $Matches[1] } else { "unknown" }
        Write-Warn "OpenCode launcher points at '$oldModel' but selected model is '$selectedModel' -- updating"
    }
}
if ($opencodeLauncherNeedsUpdate) {
    Set-Content -Path $opencodeLauncherPath -Value $expectedOpencodeContent -Encoding utf8
    Write-Ok "Wrote OpenCode launcher: $opencodeLauncherPath"
}

# --- Cline: VS Code extension, XML-tag-based tool use (no native function-calling needed) ---
$codeCmd = Get-Command code -ErrorAction SilentlyContinue
$clineInstalled = $false
if (-not $codeCmd) {
    Write-Warn "VS Code not found on this machine."
    if (-not $NonInteractive) {
        $resp = Read-Host "Install VS Code now via winget? [Y/n]"
        if (-not ($resp -match '^(n|no)$')) {
            winget install --id Microsoft.VisualStudioCode -e --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -eq 0) {
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                $codeCmd = Get-Command code -ErrorAction SilentlyContinue
                if (-not $codeCmd) {
                    Write-Warn "VS Code installed but 'code' not on PATH yet. Open a new terminal to use it. Cline install skipped for now -- re-run this script afterward."
                }
            } else {
                Write-Warn "winget install failed. Install VS Code manually from https://code.visualstudio.com."
            }
        }
    }
    if (-not $codeCmd) {
        Write-Warn "Skipping Cline extension install (no VS Code). You can re-run this script after installing VS Code."
    }
}
if ($codeCmd) {
    Write-Step "Installing Cline VS Code extension"
    & code --install-extension saoudrizwan.claude-dev 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -eq 0) {
        $clineInstalled = $true
        Write-Ok "Cline extension installed"
    } else {
        Write-Warn "Cline extension install failed. Install manually from the VS Code Marketplace (publisher: saoudrizwan, id: claude-dev)."
    }
}

# Add or repair PowerShell profile function
$profilePath = $PROFILE.CurrentUserAllHosts
$funcMarkerStart = "# >>> local-coding (setup-local-coding.ps1) >>>"
$funcMarkerEnd   = "# <<< local-coding (setup-local-coding.ps1) <<<"
$expectedFuncLines = @(
    "function aider-local { & `"$aiderLauncherPath`" @args }"
    "function opencode-local { & `"$opencodeLauncherPath`" @args }"
)
$expectedFuncBody = $expectedFuncLines -join "`n"
$expectedBlock = @"

$funcMarkerStart
$expectedFuncBody
$funcMarkerEnd
"@

$profileExists = Test-Path $profilePath
$hasMarker = $false
$profileContent = ""
if ($profileExists) {
    $profileContent = Get-Content $profilePath -Raw
    if ($profileContent -match [regex]::Escape($funcMarkerStart)) { $hasMarker = $true }
}

if ($hasMarker) {
    # Check if the existing block points at the current launcher path
    $markerPattern = [regex]::Escape($funcMarkerStart) + '[\s\S]*?' + [regex]::Escape($funcMarkerEnd)
    $existingBlock = [regex]::Match($profileContent, $markerPattern).Value
    if (($existingBlock -match [regex]::Escape($aiderLauncherPath)) -and ($existingBlock -match [regex]::Escape($opencodeLauncherPath))) {
        Write-Ok "Profile functions already configured correctly"
    } else {
        Write-Warn "Profile functions are stale -- repairing"
        $repairedContent = [regex]::Replace($profileContent, $markerPattern, "$funcMarkerStart`n$expectedFuncBody`n$funcMarkerEnd")
        Set-Content -Path $profilePath -Value $repairedContent -Encoding utf8
        Write-Ok "Repaired profile functions in $profilePath"
    }
} else {
    $addToProfile = "y"
    if (-not $NonInteractive) { $addToProfile = Read-Host "Add an 'aider-local' function to your PowerShell profile? [Y/n]" }
    if ([string]::IsNullOrWhiteSpace($addToProfile) -or $addToProfile -match '^(y|yes)$') {
        New-Item -ItemType Directory -Force -Path (Split-Path $profilePath) | Out-Null
        if (-not $profileExists) { New-Item -ItemType File -Path $profilePath | Out-Null }
        Add-Content -Path $profilePath -Value $expectedBlock
        Write-Ok "Added function to $profilePath (open a new shell to use it)"
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Step "Setup complete"
$clineStatusLine = if ($clineInstalled) {
    "  Cline:          installed, needs one-time setup (below)"
} else {
    "  Cline:          NOT installed -- see warning above"
}
$opencodeStatusLine = if ($opencodeCmd) {
    "  OpenCode:       installed"
} else {
    "  OpenCode:       NOT installed -- see warning above"
}
Write-Host @"

  Model:            $selectedModel
  Aider launcher:   $aiderLauncherPath
  OpenCode launcher: $opencodeLauncherPath
$opencodeStatusLine
$clineStatusLine

  --- Aider (CLI, plain-text diffs, 54s on benchmark) ---
      aider-local                      (interactive session in cwd)
      aider-local --message "..."      (one-shot, non-interactive)

  --- OpenCode (CLI, tool-calling agent, 5.9s on file creation) ---
      opencode-local                   (interactive session in cwd)
      opencode-local --prompt "..."    (one-shot, non-interactive)

  --- Cline (VS Code + CLI) ---
      cline                            (CLI mode in terminal)
      Or open the Cline panel in VS Code:
      1. Click the Cline icon in the Activity Bar (far-left icon strip).
      2. At the bottom, click the harness selector -> choose "Auto".
      3. Click "Other Models" -> "Install Model Providers" -> Ollama.
      4. Go to Manage -> Language Models -> select $selectedModel.

  Nothing about your existing tools (Claude Code's Anthropic login, any
  other Ollama/Aider/VS Code usage) was changed -- these are additive.
"@ -ForegroundColor White
