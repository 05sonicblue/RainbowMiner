﻿
function Set-BashFile {
[cmdletbinding()]   
param(
    [Parameter(Mandatory = $true)]
    $FilePath,
    [Parameter(Mandatory = $False)]
    $Cmd
)
    if (-not (Test-Path Variable:Global:GlobalOCD)) {[System.Collections.ArrayList]$Global:GlobalOCD = @()}

    if ($Cmd) {
        [System.Collections.ArrayList]$OCDcmd = @()
        $Cmd | Foreach-Object {$OCDcmd.Add($_) > $null}
    } else {
        $OCDcmd = $Global:GlobalOCD
    }
    if ($OCDcmd.Count) {
        $OCDcmd.Insert(0,"`#`!/usr/bin/env bash")
        $OCDcmd | Out-File "$FilePath" -ErrorAction Ignore -Force
        $OCDcmd.Clear()
    }
    if ($Cmd) {Remove-Variable "OCDcmd"}
}

function Invoke-OCDaemonWithName {
[cmdletbinding()]   
param(
    [Parameter(Mandatory = $False)]
    $FilePath,
    [Parameter(Mandatory = $False)]
    $Name,
    [Parameter(Mandatory = $False)]
    $Cmd,
    [Parameter(Mandatory = $False)]
    [Switch]$Move = $false,
    [Parameter(Mandatory = $False)]
    [Switch]$Quiet = $false
)
    if (-not ($Cmd -or $Global:GlobalOCD.Count) -and (-not $FilePath -or -not (Test-Path $FilePath))) {return}

    if (-not $Name) {$Name = (Get-ChildItem $FilePath -ErrorAction Ignore).BaseName}

    "$(Get-Date)" | Out-File "/opt/rainbowminer/ocdcmd/$Name.lock" -ErrorAction Ignore -Force
    if ($Cmd -or $Global:GlobalOCD.Count) {
        Set-BashFile -FilePath "/opt/rainbowminer/ocdcmd/$Name.sh" -Cmd $Cmd
    } else {
        Copy-Item $FilePath "/opt/rainbowminer/ocdcmd/$Name.sh" -ErrorAction Ignore
        if ($Move) {Remove-Item $FilePath -Force -ErrorAction Ignore}
    }
    if (Test-Path "/opt/rainbowminer/ocdcmd/$Name.lock") {Remove-Item "/opt/rainbowminer/ocdcmd/$Name.lock" -Force -ErrorAction Ignore}
    $StopWatch = New-Object -TypeName System.Diagnostics.StopWatch
    $StopWatch.Start()
    $stoptime = 5000
    While ((Test-Path "/opt/rainbowminer/ocdcmd/$Name.sh") -and $StopWatch.ElapsedMilliseconds -lt $stoptime) {
        Start-Sleep -Seconds 1
        if ($stoptime -lt 30000 -and (Test-Path "/opt/rainbowminer/ocdcmd/$Name.run")) {$stoptime = 30000}
    }
    Remove-Variable "StopWatch"
    if (Test-Path "/opt/rainbowminer/ocdcmd/$Name.out") {
        if (-not $Quiet) {Get-Content "/opt/rainbowminer/ocdcmd/$Name.out" -Raw}
        Remove-Item "/opt/rainbowminer/ocdcmd/$Name.out" -Force -ErrorAction Ignore
    }
    if ($Quiet) {-not (Test-Path "/opt/rainbowminer/ocdcmd/$Name.sh")}
}

function Initialize-OCDaemon {
    if ($IsLinux) {
        try {
            $pre = Get-MD5Hash $Pwd
            $Session.OCDaemonPrefix = "$($pre.Substring(0,4))$($pre.Substring(28,4))"
            $Session.OCDaemonCount  = 0
            Get-ChildItem "/opt/rainbowminer/ocdcmd" -Filter "$($Session.OCDaemonPrefix)*" -File -Force | Foreach-Object {Remove-Item $_.FullName -ErrorAction Ignore -Force}
        } catch {if ($Error.Count){$Error.RemoveAt(0)}}
    }
}

function Test-OCDaemon {
    $IsLinux -and (Test-Path "/var/run/ocdaemon.pid") -and (Get-Content "/var/run/ocdaemon.pid" -Raw -ErrorAction Ignore | Foreach-Object {Get-Process -Id $_ -ErrorAction Ignore} | Measure-Object).Count
}

function Set-OCDaemon {
[cmdletbinding()]   
param(
    [Parameter(Mandatory = $True)]
    [String]$Cmd,
    [Parameter(Mandatory = $False)]
    [String]$OnEmptyAdd = ""
)
    if (-not (Test-Path Variable:Global:GlobalOCD)) {[System.Collections.ArrayList]$Global:GlobalOCD = @()}
    if ($OnEmptyAdd -and -not $Global:GlobalOCD.Count) {$Global:GlobalOCD.Add($OnEmptyAdd) > $null}
    $Global:GlobalOCD.Add($Cmd) > $null
}


function Invoke-OCDaemon {
[cmdletbinding()]   
param(
    [Parameter(Mandatory = $False)]
    $Cmd,
    [Parameter(Mandatory = $False)]
    $FilePath,
    [Parameter(Mandatory = $False)]
    $Miner,
    [Parameter(Mandatory = $False)]
    [Switch]$Quiet
)
    if (-not (Test-Path Variable:Global:GlobalOCD)) {[System.Collections.ArrayList]$Global:GlobalOCD = @()}

    if ($Cmd -or $Global:GlobalOCD.Count) {
        if (Test-OCDaemon) {
            $tmpfn = "$($Session.OCDaemonPrefix).$($Session.OCDaemonCount)"
            Invoke-OCDaemonWithName -Name $tmpfn -Cmd $Cmd
            if (Test-Path "/opt/rainbowminer/ocdcmd/$tmpfn.sh") {
                Write-Log -Level Warn "OCDaemon failed. Please run `"./install.sh`" at the command line"
            }
            $Session.OCDaemonCount++
        } else {
            $IsTemporaryPath = $false
            if ($Miner) {
                $ScreenName = ("$($Miner.DeviceName -join "_")" -replace "[^A-Z0-9_-]").ToLower()
                Invoke-Exe "screen" -ArgumentList "-ls" -ExpandLines | Where-Object {$_ -match "(\d+)\.(oc_[a-z0-9_-]+)"} | Foreach-Object {
                    $Name = $Matches[2]
                    if ($Name -match "($(($ScreenName -split "_") -join "|"))") {
                        Invoke-Exe "screen" -ArgumentList "-S $Name -X stuff `^C" > $null
                        Start-Sleep -Milliseconds 250
                        Invoke-Exe "screen" -ArgumentList "-S $Name -X quit" > $null
                        Start-Sleep -Milliseconds 250
                    }
                }
                $ScreenName = "oc_$ScreenName"
                $FilePath = Join-Path (Split-Path $Miner.Path) "$($Miner.BaseAlgorithm -join "_")_$($ScreenName).sh"
            } else {
                if ($FilePath -eq "") {$FilePath = ".\Cache\tmp_$([System.IO.Path]::GetRandomFileName() -replace "\..+$").sh";$IsTemporaryPath = $true}
                elseif ($FilePath -notmatch "\.sh$") {$FilePath = "$FilePath.sh"}

                $FilePath = $Global:ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)

                $ScreenName = "$(Split-Path $FilePath -Leaf)" -replace "\.sh$"
                Invoke-Exe "screen" -ArgumentList "-ls" -ExpandLines | Where-Object {$_ -match "\d+\.$ScreenName\s+"} | Foreach-Object {
                    Invoke-Exe "screen" -ArgumentList "-S $ScreenName -X stuff `^C" > $null
                    Start-Sleep -Milliseconds 250
                    Invoke-Exe "screen" -ArgumentList "-S $ScreenName -X quit" > $null
                    Start-Sleep -Milliseconds 250
                }
            }

            Set-BashFile -FilePath $FilePath -Cmd $Cmd

            if (Test-Path $FilePath) {
                (Start-Process "chmod" -ArgumentList "+x $FilePath" -PassThru).WaitForExit() > $null
                Invoke-Exe "screen" -ArgumentList "-S $ScreenName -d -m" > $null
                Start-Sleep 1
                Invoke-Exe "screen" -ArgumentList "-S $ScreenName -X stuff $FilePath`n" > $null
                Start-Sleep 1
                if ($IsTemporaryPath) {Remove-Item $FilePath -Force -ErrorAction Ignore}
            }
        }
    }
}