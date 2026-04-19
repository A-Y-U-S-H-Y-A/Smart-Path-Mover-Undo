<# :
@echo off
setlocal
:: ==============================================================================
:: SECURE POLYGLOT WRAPPER
:: Includes randomized temp file names to prevent TOCTOU/Hijacking attacks.
:: ==============================================================================
set "TEMP_PS1=%TEMP%\~SmartMover_%RANDOM%_%RANDOM%.ps1"
copy /y "%~f0" "%TEMP_PS1%" >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP_PS1%" %*
set "EXIT_CODE=%errorlevel%"

del /q "%TEMP_PS1%"
exit /b %EXIT_CODE%
#>

# ===============================================================================
# POWERSHELL EXECUTION BLOCK
# ===============================================================================
param (
    [string]$Mode = "GUI",
    [string]$InputFile = "",
    [string]$TargetDir = "",
    [string]$ManifestPath = "",
    [switch]$Force,
    [switch]$h,
    [switch]$help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------------------
# CLI HELP MENU & UX VALIDATION
# -------------------------------------------------------------------------------

function Show-Help {
    Write-Host "`n======================================================" -ForegroundColor Cyan
    Write-Host "  SMART PATH MOVER & UNDO - Command Line Help" -ForegroundColor Cyan
    Write-Host "======================================================`n" -ForegroundColor Cyan
    Write-Host "USAGE:" -ForegroundColor Yellow
    Write-Host "  Interactive GUI Mode:"
    Write-Host "    main.bat`n"
    Write-Host "  CLI Move Mode:"
    Write-Host "    main.bat -Mode Move -InputFile `"C:\paths.txt`" -TargetDir `"C:\Dest`" [-Force]`n"
    Write-Host "  CLI Undo Mode:"
    Write-Host "    main.bat -Mode Undo -ManifestPath `"C:\Dest\undo_manifest.json`" [-Force]`n"
    Write-Host "OPTIONS:" -ForegroundColor Yellow
    Write-Host "  -h, --help      Show this help menu."
    Write-Host "  -Mode           Operation mode: GUI (default), Move, or Undo."
    Write-Host "  -InputFile      Path to the text file containing the list of paths to move."
    Write-Host "  -TargetDir      Destination folder where files will be moved."
    Write-Host "  -ManifestPath   Path to the undo_manifest.json file for restorations."
    Write-Host "  -Force          Skip security/rename prompts and execute automatically.`n"
    exit 0
}

if ($h -or $help -or (@($args) -contains "/?")) { Show-Help }

# @($args) ensures it is always an array (never $null) under Set-StrictMode
# when a param() block is present, $args is $null if no extra arguments are passed.
if (@($args).Count -gt 0) {
    Write-Host "`n[-] Invalid Syntax or Unknown Parameter: $($args -join ' ')" -ForegroundColor Red
    Write-Host "    Run 'main.bat --help' to see valid commands.`n" -ForegroundColor DarkGray
    exit 1
}

if ($Mode -notin @("GUI", "Move", "Undo")) {
    Write-Host "`n[-] Invalid -Mode specified: '$Mode'" -ForegroundColor Red
    Write-Host "    Must be exactly one of: GUI, Move, or Undo." -ForegroundColor DarkGray
    Write-Host "    Run 'main.bat --help' for usage examples.`n" -ForegroundColor DarkGray
    exit 1
}

if ($Mode -eq "GUI") {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

# -------------------------------------------------------------------------------
# CORE LOGIC ENGINES
# -------------------------------------------------------------------------------

function Get-ValidPaths {
    param([string]$TextContent)
    
    $foundPaths = @()
    $lines = $TextContent -split '\r?\n'
    
    foreach ($line in $lines) {
        # The regex stops at [, ], ', " so log-style lines like:
        #   "Failed to move [D:\sih\app.py] - Cannot move..."
        # correctly extract just "D:\sih\app.py" instead of the entire remainder.
        if ($line -match '([a-zA-Z]:\\[^<>|?*\[\]'+"'"+'"\t\r\n]+)') {
            $rawPath = $matches[1]
            $cleanPath = ($rawPath -split ' {2,}')[0]
            
            # Trim includes ], [, ' so delimiters from log formats are stripped cleanly.
            $trimChars = " .,;`"'[]`t`r`n".ToCharArray()
            $cleanPath = $cleanPath.Trim($trimChars)
            
            if ($cleanPath -notin $foundPaths) {
                $foundPaths += $cleanPath
            }
        }
    }

    $validItems = @()
    foreach ($path in $foundPaths) {
        try {
            if (Test-Path -LiteralPath $path -ErrorAction Stop) {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                $validItems += [PSCustomObject]@{
                    Name = $item.Name
                    Type = if ($item -is [System.IO.FileInfo]) { "File" } else { "Folder" }
                    FullPath = $item.FullName
                }
            }
        } catch {
            continue
        }
    }
    
    return [array]$validItems 
}

function Execute-MoveOperation {
    param($SelectedItems, [string]$Destination, [string]$CollisionAction)
    
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-Host "`n[+] Created target directory: $Destination" -ForegroundColor Green
    }

    $SelectedItems = @($SelectedItems | Sort-Object -Property @{Expression={$_.FullPath.Length}; Ascending=$true})
    
    $manifest = @{
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TargetDirectory = $Destination
        Operations = @()
    }

    [System.Collections.Generic.List[string]]$movedParents = New-Object System.Collections.Generic.List[string]
    $successCount = 0
    $reviewLog = @()

    foreach ($item in $SelectedItems) {
        if (-not (Test-Path -LiteralPath $item.FullPath)) { continue }

        $isChild = $false
        foreach ($parent in $movedParents) {
            $cleanParent = $parent.TrimEnd('\', '/')
            if ($item.FullPath.StartsWith($cleanParent + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $isChild = $true; break
            }
        }

        if ($isChild) { continue }

        $destPath = Join-Path -Path $Destination -ChildPath $item.Name
        $newName = $item.Name
        $currentAction = $CollisionAction
        
        if (Test-Path -LiteralPath $destPath) {
            if ($currentAction -eq "Prompt") {
                Write-Host "`n[!] WARNING: [$($item.Name)] already exists in the target folder!" -ForegroundColor Magenta
                Write-Host "    1. Auto-rename and move (Default)"
                Write-Host "    2. Skip this file and log it"
                Write-Host "    3. Auto-rename, move, AND log it"
                $currentAction = Read-Host "    Choose action (1-3)"
            }

            if ($currentAction -eq "2" -or $currentAction -eq "Skip") {
                $reviewLog += "[$(Get-Date)] SKIPPED MOVE: [$($item.FullPath)] (Name Collision)"
                continue
            }

            $counter = 1
            while (Test-Path -LiteralPath $destPath) {
                $newName = if ($item.Type -eq "File") {
                    $base = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                    $ext = [System.IO.Path]::GetExtension($item.Name)
                    "${base}_${counter}${ext}"
                } else {
                    "$($item.Name)_${counter}"
                }
                $destPath = Join-Path -Path $Destination -ChildPath $newName
                $counter++
            }

            if ($currentAction -eq "3" -or $currentAction -eq "AutoRenameLog") {
                $reviewLog += "[$(Get-Date)] RENAMED: [$($item.FullPath)] was renamed to [$newName]"
            }
        }

        try {
            Move-Item -LiteralPath $item.FullPath -Destination $destPath -Force
            $movedParents.Add($item.FullPath) | Out-Null
            $successCount++
            $manifest.Operations += @{ OriginalPath = $item.FullPath; CurrentPath = $destPath; Type = $item.Type }
            Write-Host "  -> Moved: $($item.FullPath)" -ForegroundColor DarkGreen
        } catch {
            Write-Host "  -> Failed: $($item.FullPath)" -ForegroundColor Red
            $reviewLog += "[$(Get-Date)] ERROR: Failed to move [$($item.FullPath)] - $($_.Exception.Message)"
        }
    }

    if ($successCount -gt 0) {
        $jsonPath = Join-Path -Path $Destination -ChildPath "undo_manifest.json"
        $manifest | ConvertTo-Json -Depth 3 | Set-Content -Path $jsonPath -Encoding UTF8
    }
    
    if ($reviewLog.Count -gt 0) {
        $logPath = Join-Path -Path $Destination -ChildPath "Review_Log.txt"
        $reviewLog | Set-Content -Path $logPath
        Write-Host "`n[*] Notices logged to: $logPath" -ForegroundColor Magenta
    }
    Write-Host "`n[OK] Complete. Successfully moved $successCount items." -ForegroundColor Cyan
}

function Execute-UndoOperation {
    param([string]$ManifestLocation, [string]$MissingFolderAction, [switch]$SkipConfirm)
    
    $ManifestLocation = $ManifestLocation.Trim("`"")
    if (Test-Path -LiteralPath $ManifestLocation -PathType Container) {
        $ManifestLocation = Join-Path -Path $ManifestLocation -ChildPath "undo_manifest.json"
    }

    if (-not (Test-Path -LiteralPath $ManifestLocation -PathType Leaf)) {
        throw "Manifest not found at: $ManifestLocation"
    }

    $manifestDir = Split-Path -Path $ManifestLocation -Parent
    $manifest = Get-Content -Raw -Path $ManifestLocation | ConvertFrom-Json
    
    # FORCE the operations list to be an array, even if there's only 1 item
    $operationsArray = @($manifest.Operations)

    # --- SECURITY PATCH: Verify Intent ---
    if (-not $SkipConfirm) {
        Write-Host "`n[!] Security Check: This manifest will restore $($operationsArray.Count) items." -ForegroundColor Yellow
        if ($operationsArray.Count -gt 0) {
            Write-Host "    Example: [$($operationsArray[0].CurrentPath)]" -ForegroundColor DarkGray
            Write-Host "          -> [$($operationsArray[0].OriginalPath)]" -ForegroundColor DarkGray
        }
        
        $confirm = Read-Host "`n    Do you want to proceed with these operations? (Y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "`n[-] Undo operation aborted by user." -ForegroundColor Yellow
            return
        }
    }
    # -------------------------------------

    $restoreCount = 0
    $reviewLog = @()

    foreach ($op in $operationsArray) {
        if (-not (Test-Path -LiteralPath $op.CurrentPath)) {
            Write-Host "  -> Source missing: $($op.CurrentPath)" -ForegroundColor Red
            $reviewLog += "[$(Get-Date)] MISSING SOURCE: [$($op.CurrentPath)]"
            continue
        }

        $originalParent = Split-Path -Path $op.OriginalPath -Parent
        $currentAction = $MissingFolderAction
        
        if (-not (Test-Path -LiteralPath $originalParent)) {
            if ($currentAction -eq "Prompt") {
                Write-Host "`n[!] WARNING: Original folder structure is missing: [$originalParent]" -ForegroundColor Magenta
                Write-Host "    1. Recreate the missing folder and restore (Default)"
                Write-Host "    2. Skip this restore and log it"
                Write-Host "    3. Recreate, restore, AND log it"
                $currentAction = Read-Host "    Choose action (1-3)"
            }

            if ($currentAction -eq "2" -or $currentAction -eq "Skip") {
                $reviewLog += "[$(Get-Date)] SKIPPED UNDO: Directory missing for [$($op.OriginalPath)]"
                continue
            }

            New-Item -ItemType Directory -Path $originalParent -Force | Out-Null
            if ($currentAction -eq "3" -or $currentAction -eq "AutoRecreateLog") {
                $reviewLog += "[$(Get-Date)] RECREATED FOLDER: [$originalParent]"
            }
        }

        try {
            Move-Item -LiteralPath $op.CurrentPath -Destination $op.OriginalPath -Force
            $restoreCount++
            Write-Host "  -> Restored: $($op.OriginalPath)" -ForegroundColor DarkGreen
        } catch {
            Write-Host "  -> Failed: $($op.OriginalPath)" -ForegroundColor Red
            $reviewLog += "[$(Get-Date)] ERROR: Restore failed [$($op.OriginalPath)]"
        }
    }

    if ($reviewLog.Count -gt 0) {
        $logPath = Join-Path -Path $manifestDir -ChildPath "Undo_Review_Log.txt"
        $reviewLog | Set-Content -Path $logPath
    }

    if ($restoreCount -eq $operationsArray.Count -and $operationsArray.Count -gt 0) {
        Remove-Item -LiteralPath $ManifestLocation -Force
        Write-Host "`n[OK] Perfect restore. Manifest deleted." -ForegroundColor Cyan
    } else {
        Write-Host "`n[!] Partial restore. Manifest kept for review." -ForegroundColor Yellow
    }
}

# -------------------------------------------------------------------------------
# GUI & INTERACTIVE MODE
# -------------------------------------------------------------------------------

function Get-PastedTextGUI {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Smart Path Mover - Input Data"
    $form.Size = New-Object System.Drawing.Size(700, 500)
    $form.StartPosition = "CenterScreen"
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.BackColor = [System.Drawing.Color]::White

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Paste your multi-line text containing paths below:"
    $label.Location = New-Object System.Drawing.Point(15, 15)
    $label.AutoSize = $true
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ScrollBars = "Vertical"
    $textBox.Size = New-Object System.Drawing.Size(650, 360)
    $textBox.Location = New-Object System.Drawing.Point(15, 45)
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $form.Controls.Add($textBox)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Scan Text"
    $btnOK.Size = New-Object System.Drawing.Size(120, 35)
    $btnOK.Location = New-Object System.Drawing.Point(545, 415)
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOK.BackColor = [System.Drawing.Color]::LightBlue
    $btnOK.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $form.Controls.Add($btnOK)

    $form.AcceptButton = $btnOK
    $result = $form.ShowDialog()
    $text = $textBox.Text
    $form.Dispose()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $text } else { return "" }
}

function Get-CheckedItemsGUI {
    param([array]$ValidItems)
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Smart Path Mover - Select Files to Move"
    $form.Size = New-Object System.Drawing.Size(800, 600)
    $form.StartPosition = "CenterScreen"
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.BackColor = [System.Drawing.Color]::White

    $panelBottom = New-Object System.Windows.Forms.Panel
    $panelBottom.Dock = "Bottom"
    $panelBottom.Height = 60

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Move Selected Items"
    $btnOK.Size = New-Object System.Drawing.Size(150, 35)
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOK.Location = New-Object System.Drawing.Point(610, 10)
    $btnOK.BackColor = [System.Drawing.Color]::LightGreen
    $btnOK.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = "Select All"
    $btnAll.Size = New-Object System.Drawing.Size(100, 35)
    $btnAll.Location = New-Object System.Drawing.Point(15, 10)
    $btnAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = "Clear All"
    $btnNone.Size = New-Object System.Drawing.Size(100, 35)
    $btnNone.Location = New-Object System.Drawing.Point(125, 10)
    $btnNone.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $panelBottom.Controls.AddRange(@($btnOK, $btnAll, $btnNone))

    $chkList = New-Object System.Windows.Forms.CheckedListBox
    $chkList.CheckOnClick = $true
    $chkList.Dock = "Fill"
    $chkList.Font = New-Object System.Drawing.Font("Consolas", 10)
    $chkList.Padding = New-Object System.Windows.Forms.Padding(10)
    
    foreach ($item in $ValidItems) {
        $chkList.Items.Add($item.FullPath, $true) | Out-Null
    }

    $btnAll.Add_Click({
        for ($i = 0; $i -lt $chkList.Items.Count; $i++) { $chkList.SetItemChecked($i, $true) }
    })
    $btnNone.Add_Click({
        for ($i = 0; $i -lt $chkList.Items.Count; $i++) { $chkList.SetItemChecked($i, $false) }
    })

    $form.Controls.Add($chkList)
    $form.Controls.Add($panelBottom)
    $form.AcceptButton = $btnOK

    $result = $form.ShowDialog()
    $selectedPaths = @()
    
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($checked in $chkList.CheckedItems) {
            $selectedPaths += $checked
        }
    }
    $form.Dispose()

    return $ValidItems | Where-Object { $_.FullPath -in $selectedPaths }
}

function Show-InteractiveMenu {
    $options = @("Extract & Move files (GUI)", "Undo a previous move", "Exit")
    $selectedIndex = 0

    while ($true) {
        Clear-Host
        Write-Host "`n"
        Write-Host "  ======================================================" -ForegroundColor Cyan
        Write-Host "  |              SMART PATH MOVER & UNDO               |" -ForegroundColor Cyan
        Write-Host "  ======================================================" -ForegroundColor Cyan
        Write-Host "    Use [Up/Down] arrows to navigate, [Enter] to select.`n" -ForegroundColor DarkGray

        for ($i = 0; $i -lt $options.Count; $i++) {
            if ($i -eq $selectedIndex) {
                Write-Host "      > $($options[$i]) <  " -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host "        $($options[$i])    " -ForegroundColor Gray
            }
        }

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        
        if ($key.VirtualKeyCode -eq 38) { 
            $selectedIndex--
            if ($selectedIndex -lt 0) { $selectedIndex = $options.Count - 1 }
        } 
        elseif ($key.VirtualKeyCode -eq 40) { 
            $selectedIndex++
            if ($selectedIndex -ge $options.Count) { $selectedIndex = 0 }
        } 
        elseif ($key.VirtualKeyCode -eq 13) { 
            return $selectedIndex
        }
    }
}

function Pause {
    Write-Host "`nPress any key to return to menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# -------------------------------------------------------------------------------
# EXECUTION ROUTING
# -------------------------------------------------------------------------------

try {
    if ($Mode -eq "GUI") {
        while ($true) {
            $choice = Show-InteractiveMenu
            
            if ($choice -eq 0) { 
                Clear-Host
                Write-Host "`n[+] Opening Text Input Window..." -ForegroundColor Cyan
                $pastedText = Get-PastedTextGUI
                if ([string]::IsNullOrWhiteSpace($pastedText)) { Write-Host "`n[-] No text provided. Canceled." -ForegroundColor Yellow; Pause; continue }
                
                Write-Host "[*] Scanning for paths..." -ForegroundColor DarkGray
                [array]$validItems = Get-ValidPaths -TextContent $pastedText
                
                if ($validItems.Count -eq 0) { Write-Host "`n[-] No valid paths found in text." -ForegroundColor Yellow; Pause; continue }

                Write-Host "[+] Opening Checkbox Selection Window..." -ForegroundColor Cyan
                
                # FORCE selected items to be an array so .Count doesn't crash on single selections
                $selectedItems = @(Get-CheckedItemsGUI -ValidItems $validItems)
                
                if ($selectedItems.Count -eq 0) { Write-Host "`n[-] No files selected. Canceled." -ForegroundColor Yellow; Pause; continue }

                Write-Host "`n"
                $targetDirPrompt = Read-Host "    [?] Enter DESTINATION folder path"
                if ([string]::IsNullOrWhiteSpace($targetDirPrompt)) { Write-Host "`n[-] Invalid destination. Canceled." -ForegroundColor Yellow; Pause; continue }

                Execute-MoveOperation -SelectedItems $selectedItems -Destination $targetDirPrompt -CollisionAction "Prompt"
                Pause

            } elseif ($choice -eq 1) { 
                Clear-Host
                Write-Host "`n  ======================================================" -ForegroundColor Magenta
                Write-Host "  |                     UNDO MOVES                     |" -ForegroundColor Magenta
                Write-Host "  ======================================================`n" -ForegroundColor Magenta
                
                $manPath = Read-Host "    [?] Paste exact path to undo_manifest.json OR its folder"
                if ([string]::IsNullOrWhiteSpace($manPath)) { Write-Host "`n[-] Invalid path. Canceled." -ForegroundColor Yellow; Pause; continue }
                
                Execute-UndoOperation -ManifestLocation $manPath -MissingFolderAction "Prompt"
                Pause

            } elseif ($choice -eq 2) { 
                Clear-Host
                exit
            }
        }
    } 
    elseif ($Mode -eq "Move") {
        if (-not $InputFile -or -not $TargetDir) { throw "CLI Move requires -InputFile and -TargetDir parameters." }
        if (-not (Test-Path -LiteralPath $InputFile)) { throw "Input file not found: $InputFile" }
        
        $textContent = Get-Content -Raw -LiteralPath $InputFile
        [array]$validItems = Get-ValidPaths -TextContent $textContent
        
        if ($validItems.Count -eq 0) { throw "No valid existing paths found in the input file." }
        
        $cliCollisionAction = if ($Force) { "AutoRenameLog" } else { "Skip" }
        Write-Host "Starting CLI Move Operation..." -ForegroundColor Cyan
        Execute-MoveOperation -SelectedItems $validItems -Destination $TargetDir -CollisionAction $cliCollisionAction
    } 
    elseif ($Mode -eq "Undo") {
        if (-not $ManifestPath) { throw "CLI Undo requires -ManifestPath parameter." }
        
        $cliMissingAction = if ($Force) { "AutoRecreateLog" } else { "Skip" }
        Write-Host "Starting CLI Undo Operation..." -ForegroundColor Cyan
        Execute-UndoOperation -ManifestLocation $ManifestPath -MissingFolderAction $cliMissingAction -SkipConfirm:$Force
    }
} catch {
    Write-Host "`n[!] FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($Mode -eq "GUI") { Pause } else { exit 1 }
}