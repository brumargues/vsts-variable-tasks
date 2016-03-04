[cmdletbinding()]
param(
    [string[]] $Items = @(".\vsts-extension-packageandpublish"),
    [switch] $Force = $false,
    [switch] $Package = $false,
    [switch] $PublishLocal = $false,
    [switch] $PublishMarket = $false,
    [switch] $Release = $false,
    [string] $ServiceUrl = "https://jessehouwing.visualstudio.com/DefaultCollection"

)

if ((Get-Command "tfx" -ErrorAction SilentlyContinue) -eq $null) 
{ 
    [Environment]::SetEnvironmentVariable("Path", "$($env:Path);node_modules\.bin\", "Process")
}

$patchMarkerName = "task.json.lastpatched"
$uploadMarkerName = "task.json.lastuploaded"
$packagedMarkerName = ".lastpackaged"
$publisherId = "jessehouwing"
$extensionId = "jessehouwing-vsts-extension-tasks"

if (-not $Release.IsPresent)
{
    $extensionId = "$extensionId-TEST"
}

cd -Path $PSScriptRoot

if ($Force)
{
    Write-Warning "Force specified"
}

function Update-TaskVersion
{
    param(
        [Parameter(Mandatory=$true)]
        [string] $TaskPath
    )

    $result = $false

    $patch = $Force -or {
       $item = Get-ChildItem $TaskPath\*.* -Recurse | ?{ -not ("$($_.Name)" -eq "$uploadMarkerName") } | Sort {$_.LastWriteTime} | select -last 1
       return -not ("$($item.Name)" -eq "$patchMarkerName")
    }

    if ($patch)
    {
        $taskJson = ConvertFrom-Json (Get-Content "$TaskPath\task.json" -Raw)
        $taskJson.Version.Patch = $taskJson.Version.Patch + 1
        $taskjson | ConvertTo-JSON -Depth 255 | Out-File  "$TaskPath\task.json" -Force -Encoding ascii
        New-Item -Path $TaskPath -Name $patchMarkerName -ItemType File -Force | Out-Null
        $result = $true

        Write-Output "Updated version to $($taskJson.Version)"
    }
    
    return $result
}

function Publish-TaskLocally
{
    param(
        [Parameter(Mandatory=$true)]
        [string] $TaskPath
    )

    $result = $false
    $publish = $Force -or {
        $item = Get-ChildItem $TaskPath -Recurse | Sort {$_.LastWriteTime} | select -last 1
        return -not ("$($item.Name)" -eq "$uploadMarkerName")
    }

    if ($publish)
    {
        tfx build tasks upload --task-path $TaskPath --service-url $ServiceUrl
        New-Item -Path $TaskPath -Name $uploadMarkerName -ItemType File -Force | Out-Null
        $result = $true

        Write-Output Published
    }
    
    return $result
}

function Publish-ExtensionToMarket
{
    param(
    )

    $result = $false
    
    $extensionJson = ConvertFrom-Json (Get-Content ".\vss-extension.json" -Raw)
    $Version = [System.Version]::Parse($extensionJson.Version)
    $versionString = $Version.ToString(3)

    tfx extension publish --vsix "$publisherId.$extensionId$versionString.vsix" --service-url https://app.market.visualstudio.com

    return $result
}

function Package-Extension
{
    $result = $false

    $patch = $Force -or {
       $item = Get-ChildItem *.* -Recurse | ?{ -not ("$($_.Name)" -eq "$packagedMarkerName") } | Sort {$_.LastWriteTime} | select -last 1
       return -not ("$($item.Name)" -eq "$packagedMarkerName")
    }

    if ($patch)
    {
        $extensionJson = ConvertFrom-Json (Get-Content ".\vss-extension.json" -Raw)
        $Version = [System.Version]::Parse($extensionJson.Version)
        $Version = New-Object System.Version -ArgumentList $Version.Major, $Version.Minor, ($Version.Build + 1)
        $extensionJson.Version = $Version.ToString(3)
        $extensionJson.Id = "$extensionId"
        $extensionJson.Public = $Release.IsPresent

        $extensionJson | ConvertTo-JSON -Depth 255 | Out-File  ".\vss-extension.json" -Force -Encoding ascii
        New-Item -Path . -Name $packagedMarkerName -ItemType File -Force | Out-Null
        $result = $true

        Write-Output "Updated version to $($extensionJson.Version)"
    }
    
    tfx extension create --root . --output-path . --manifest-globs vss-extension.json
    return $result
}

$updated = $false
foreach ($Item in $Items)
{

    if (Test-Path $Item)
    {
        Write-Output "Processing: $Item"
        Copy-Item .\vsts-*-shared\*.psm1 .\$item -Force
        $taskUpdated = Update-TaskVersion -TaskPath $item
        $updated = ($updated -or $taskUpdated)
        if ($taskUpdated -and $PublishLocal)
        {
            $published = Publish-TaskLocally -TaskPath $Item
        }
    }
    else
    {
        Write-Error "Path not found: $Item"
    }
}

if (($updated -or $Force) -and $Package)
{

    $packaged = Package-Extension
    if ($packaged -and $PublishMarket)
    {
        Publish-ExtensionToMarket
    }
}
