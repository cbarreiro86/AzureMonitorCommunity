# Migration Tooling Script

Param(
    [Parameter(Mandatory=$True)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$True)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$True)]
    [string]$WorkspaceName,

    [Parameter(Mandatory=$True)]
    [string]$DCRName,

    [Parameter(Mandatory=$True)]
    [string]$Location,

    [Parameter(Mandatory=$False)]
    [string]$FolderPath = ".",

    [Parameter(Mandatory=$False)]
    [switch]$GetDcrPayload,

    [Parameter(Mandatory=$False)]
    [string]$DCEName = "null"
)

class DCRPerformanceCounter
{
    [string]$name
    [string[]]$streams
    [int]$samplingFrequencyInSeconds
    [string[]]$counterSpecifiers
    [string] $platformType
}

class DCRWindowsEvent
{
    [string]$name
    [string[]]$streams
    [string[]]$xPathQueries
}

class DCRLinuxSyslog
{
    [string]$name
    [string[]]$streams
    [string[]]$facilityNames
    [string[]]$logLevels
}

class DCRCustomLogSettings
{
    [DCRCustomLogSettingsText]$text
}

class DCRCustomLogSettingsText
{
    [string]$recordStartTimestampFormat
}

class DCRCustomLogFiles
{
    [string[]]$streams
    [string[]]$filePatterns
    [string]$format
    [DCRCustomLogSettings]$settings
    [string]$name
}

class DCRIISLog
{
    [string]$name
    [string[]]$streams
}

function Get-UserWorkspace
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName
    )

    # The $Workspace Name in this context in case insensitive
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName

    return $workspace
}

function Get-WorkspaceDataSources
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName,
        [ValidateSet("WindowsPerformanceCounter", "WindowsEvent", "LinuxSyslog", "LinuxPerformanceObject", "CustomLog")]
        [Parameter(Mandatory=$true)][string] $DataSourceType
    )

    $dataSources = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind $DataSourceType
    return $dataSources
}

function Get-DCRFromWorkspace
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName,
        [Parameter(Mandatory=$true)][string] $DCRName,
        [Parameter(Mandatory=$true)][string] $Location,
        [Parameter(Mandatory=$true)][string] $FolderPath,
        [Parameter(Mandatory=$true)][string] $SubscriptionId,
        [Parameter(Mandatory=$true)][string] $DCEName
    )

    $windowsDCRTemplateParams = Get-DCRBaseArmTemplateParams -DCRName "$($DCRName)-windows"
    $windowsDCRArmTemplate = Get-DCRArmTemplate -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Location $Location -PlatformType "Windows" -FolderPath $FolderPath -SubscriptionId $SubscriptionId -DCEName $DCEName
    
    $linuxDCRTemplateParams = Get-DCRBaseArmTemplateParams -DCRName "$($DCRName)-linux"
    $linuxDCRArmTemplate = Get-DCRArmTemplate -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Location $Location -PlatformType "Linux" -FolderPath $FolderPath -SubscriptionId $SubscriptionId -DCEName $DCEName

    $currentDateTime = Get-Date -Format "MM-dd-yyyy-HH-mm-ss"
    if($windowsDCRArmTemplate.Count -gt 0)
    {
        $windowsDCRTemplateParams | Out-File "$($FolderPath)/dcr_windows_arm_template_$currentDateTime.parameters.json"
        $windowsDCRArmTemplate | Out-File "$($FolderPath)/dcr_windows_arm_template_$currentDateTime.json"
    }

    if($linuxDCRArmTemplate.Count -gt 0)
    {
        $linuxDCRTemplateParams | Out-File "$($FolderPath)/dcr_linux_arm_template_$currentDateTime.parameters.json"
        $linuxDCRArmTemplate | Out-File "$($FolderPath)/dcr_linux_arm_template_$currentDateTime.json"
    }

    if (Find-IfVmiEnabled -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName)
    {
        Get-VmiDcrArmTemplate -ProcessAndDependencies $true -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -DCRName $DCRName -Location $Location | Out-File "$($FolderPath)/MSVMI-PerfandDa-$DCRName.json"
        Get-VmiDcrBaseArmTemplateParams -ProcessAndDependencies $true -DCRName $DcrName | Out-File "$($FolderPath)/MSVMI-PerfandDa-$DCRName.parameters.json"
        Get-VmiDcrArmTemplate -ProcessAndDependencies $false -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -DCRName $DCRName -Location $Location | Out-File "$($FolderPath)/MSVMI-Perf-$DCRName.json"
        Get-VmiDcrBaseArmTemplateParams -ProcessAndDependencies $false -DCRName $DcrName | Out-File "$($FolderPath)/MSVMI-Perf-$DCRName.parameters.json"
        if ($GetDcrPayload)
        {
            Get-VmiDcrPayload -ProcessAndDependencies $true -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName | Out-File "$($FolderPath)/MSVMI-PerfandDa-$DCRName-payload.json"
            Get-VmiDcrPayload -ProcessAndDependencies $false -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName | Out-File "$($FolderPath)/MSVMI-Perf-$DCRName-payload.json"
        } 
    }

}

function Get-DCRArmTemplate
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName,
        [Parameter(Mandatory=$true)][string] $Location,
        [ValidateSet("Linux", "Windows")]
        [Parameter(Mandatory=$true)][string] $PlatformType,
        [Parameter(Mandatory=$true)][string] $FolderPath,
        [Parameter(Mandatory=$true)][string] $SubscriptionId,
        [Parameter(Mandatory=$true)][string] $DCEName
    )

    $dcrJson = Get-DCRBaseJson -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -PlatformType $PlatformType
    
    $dataCollectionEndpoint = GetOrCreate-DataCollectionEndpoint -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -DCEName $DCEName
    if ($dataCollectionEndpoint.id -ne $null)
    {
        $dceId = $dataCollectionEndpoint.id
    }
    
    #ARM Template File
    $schema = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    $contentVersion = "1.0.0.0"
    $paramName = "dataCollectionRules_name"
    $paramMetadata = @{
        "defaultValue" = "my_default_dcr-$($PlatformType.ToLower())";
        "type" = "String";
    }
    $dceParamName = "dataCollectionEndpoint_id"
    $dceParamMetadata = @{
        "defaultValue" = "$dceId";
        "type" = "String";
    }

    $parameters = @{
        "$($paramName)" = $paramMetadata;
        "$($dceParamName)" = $dceParamMetadata;
    }
    $variables = @{}

    $result = @{}

    if($dcrJson.Count -gt 0)
    {
        $resources = @(
        [ordered]@{
            "type" = "Microsoft.Insights/dataCollectionRules";
            "apiVersion" = "2022-06-02";
            "name" = "[parameters('$($paramName)')]";
            "location" = $Location;
            "kind" = $PlatformType;
            "properties" = $dcrJson.properties
        })

        $dcrTemplate =
        [ordered]@{
            "`$schema" = $schema;
            "contentVersion" = $contentVersion;
            "parameters" = $parameters;
            "variables" = $variables;
            "resources" = $resources
        }
        
        $result = ConvertTo-Json -InputObject $dcrTemplate -Depth 20
    }

    return $result
}

function Get-DCRBaseArmTemplateParams
{
    param (
        [Parameter(Mandatory=$true)][string] $DCRName
    )
    #ARM Template Parameters File
    $schema = "https://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#"
    $contentVersion = "1.0.0.0"
    $paramName = "dataCollectionRules_name"
    $paramMetadata = @{
        "value" = "$DCRName";
    }
    $parameters = @{
        "$($paramName)" = $paramMetadata;
    }

    $dcrTemplateParams = 
    [ordered]@{
        "`$schema" = $schema;
        "contentVersion" = $contentVersion;
        "parameters" = $parameters
    }

    return ConvertTo-Json -Depth 5 $dcrTemplateParams
}

function Get-DCRBaseJson
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName,
        [ValidateSet("Linux", "Windows")]
        [Parameter(Mandatory=$true)][string] $PlatformType
    )
    
    $dcrJson = @{}

    $dataSources = Get-DataSources -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -PlatformType $PlatformType
    $destinations = Get-Destinations -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    $dataFlows = [System.Collections.ArrayList]@(Get-DataFlows -WorkspaceName $WorkspaceName -PlatformType $PlatformType -ResourceGroupName $ResourceGroupName)
    $streamDeclarations = Get-CustomLogStreamDeclarations -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName

    if(-not (Get-DataSourceIsEmpty -DataSource $dataSources))
    {
        $properties = 
        [ordered]@{
            "dataCollectionEndpointId" = "[parameters('dataCollectionEndpoint_id')]";
            "streamDeclarations" = $streamDeclarations;
            "dataSources" = $dataSources;
            "destinations" = $destinations;
            "dataFlows" = $dataFlows;
        }

        $dcrJson.Add('properties', $properties)
    }
    
    # If the GetDcrPayloadJson parameter was set, output it to a file
    if ($GetDcrPayload)
    {
        $dcrJson | ConvertTo-Json -Depth 10 | Out-File "$($FolderPath)/dcr-payload-$($PlatformType).json"
    }
    
    return $dcrJson
}

function Get-DataSources
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName,
        [ValidateSet("Linux", "Windows")]
        [Parameter(Mandatory=$true)][string] $PlatformType
    )

    # Data sources are platform dependent
    # For Windows: perfCounters (WindowsPerfCounters), windowsEventLogs
    # For Linux: perfCounters (LinuxPerformanceObject), sysLog (LinuxSysLogs)
    $dcrDataSources = [ordered]@{}

    if($PlatformType -eq "Linux")
    {
        $perfCounterDataSources = Get-LinuxPerformanceCountersInDCRFormat -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
        $linuxSyslogDataSources = Get-LinuxSyslogInDCRFormat -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName

        if(($null -ne $linuxSyslogDataSources))
        {
            $linuxSyslogDataSources = [System.Collections.ArrayList]@($linuxSyslogDataSources)
            $dcrDataSources["syslog"] = $linuxSyslogDataSources
        }
    }
    else
    {
        $perfCounterDataSources = Get-WindowsPerformanceCountersInDCRFormat -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
        $windowsEventDataSources = Get-WindowsEventsInDCRFormat -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName

        if(($null -ne $windowsEventDataSources))
        {
            $windowsEventDataSources = [System.Collections.ArrayList]@($windowsEventDataSources)
            $dcrDataSources["windowsEventLogs"] = $windowsEventDataSources
        }
    }

    if(($null -ne $perfCounterDataSources) -and ($perfCounterDataSources[0].GetType().Name -eq "DCRPerformanceCounter"))
    {
        
        $perfCounterDataSources = [System.Collections.ArrayList]@($perfCounterDataSources)
        $dcrDataSources["performanceCounters"] = $perfCounterDataSources
    }

    $customLogDataSources = Get-CustomLogsInDCRFormat -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    if(($customLogDataSources -ne $null))
    {
        $customLogDataSources = [System.Collections.ArrayList]@($customLogDataSources)
        $dcrDataSources["logFiles"] = $customLogDataSources
    }

    $iisLogs = Get-IisLogsInDCRFormat
    if (($iisLogs -ne $null))
    {
        $iisLogs = [System.Collections.ArrayList]@($iisLogs)
        $dcrDataSources["iisLogs"] = $iisLogs
    }

    return $dcrDataSources
}

function Get-DataSourceIsEmpty
{
    param (
        [Parameter(Mandatory=$true)][hashtable] $DataSource
    )

    if($DataSource.Count -eq 0)   
    {
        return $true
    } 
    else
    {
        return $false
    }
}

function Get-ValidatedWindowsCounterSpecifier
{
    param(
        [Parameter(Mandatory=$true)][string] $counterSpecifier
    )

    # This function applies Modifications if necessary to the counterSpecifier

    # Case 0
    # \Memory(*)\Counter Name is an invalid perfCounter
    # Whenever we encounter it, transform it to \Memory\CounterName (with no instance specified)
    $counterSpecifier = $counterSpecifier.replace("Memory(*)", "Memory")
    return $counterSpecifier
}

function Get-WindowsPerformanceCountersInDCRFormat
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName
    )

    $dataSourceType = "WindowsPerformanceCounter"
    $workspaceDataSourceList = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind $dataSourceType
    $dcrPerfCounterStream = Get-DCRStream -DataSourceType $dataSourceType

    $dcrWindowsPerfCounterTable = [ordered]@{}
    $count = 1
    foreach($dataSource in $workspaceDataSourceList)
    {
        $properties = $dataSource.Properties
        $currentKey = [string]$properties.intervalSeconds

        if($dcrWindowsPerfCounterTable.Contains($currentKey))
        {
            $counterSpecifierValidated = Get-ValidatedWindowsCounterSpecifier -counterSpecifier "\$($properties.objectName)($($properties.instanceName))\$($properties.counterName)"
            $dcrWindowsPerfCounterTable[$currentKey].counterSpecifiers += $counterSpecifierValidated
        }
        else
        {
            $newPerfCounter = New-Object DCRPerformanceCounter
            $newPerfCounter.name = "DS_$($dataSourceType)_$($count)"
            $counterSpecifierValidated = Get-ValidatedWindowsCounterSpecifier -counterSpecifier "\$($properties.objectName)($($properties.instanceName))\$($properties.counterName)"
            $newPerfCounter.counterSpecifiers = @($counterSpecifierValidated)
            $newPerfCounter.samplingFrequencyInSeconds = $properties.intervalSeconds
            $newPerfCounter.streams = $dcrPerfCounterStream
            $newPerfCounter.platformType = "Windows"
            $dcrWindowsPerfCounterTable.Add($currentKey, $newPerfCounter)
            $count += 1
        }
    }

    $dcrDataSourceList = [System.Collections.ArrayList]::new()
    foreach($key in $dcrWindowsPerfCounterTable.Keys)
    {
        $dcrDataSourceList.Add($dcrWindowsPerfCounterTable[$key]) | Out-Null
    }

    return $dcrDataSourceList
}

function Get-LinuxPerformanceCountersInDCRFormat
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName
    )

    $dataSourceType = "LinuxPerformanceObject"
    $workspaceDataSourceList = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind $dataSourceType
    $dcrPerfCounterStream = Get-DCRStream -DataSourceType $dataSourceType

    $dcrLinuxPerfCounterTable = [ordered]@{}
    $count = 1
    foreach($dataSource in $workspaceDataSourceList)
    {
        $properties = $dataSource.Properties
        $currentKey = "$($properties.objectName)-$($properties.intervalSeconds)"
        $newPerfCounter = New-Object DCRPerformanceCounter
        $newPerfCounter.name = "DS_$($dataSourceType)_$($count)"
        $newPerfCounter.counterSpecifiers = @()
        $newPerfCounter.samplingFrequencyInSeconds = $properties.intervalSeconds
        $newPerfCounter.streams = $dcrPerfCounterStream
        $newPerfCounter.platformType = "Linux"
        
        foreach($counter in $properties.performanceCounters)
        {
            $newPerfCounter.counterSpecifiers += "\$($properties.objectName)($($properties.instanceName))\$($counter.counterName)"
        }

        $dcrLinuxPerfCounterTable.Add($currentKey, $newPerfCounter)
        $count += 1
    }

    $dcrDataSourceList = [System.Collections.ArrayList]::new()
    foreach($key in $dcrLinuxPerfCounterTable.Keys)
    {
        $dcrDataSourceList.Add($dcrLinuxPerfCounterTable[$key]) | Out-Null
    }

    return $dcrDataSourceList
}

function Get-WindowsEventsInDCRFormat
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName
    )

    $dataSourceType = "WindowsEvent"
    $workspaceWindowsEvents = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind $dataSourceType
    $dcrWindowsEventLogsStream = Get-DCRStream -DataSourceType $dataSourceType

    $dcrWindowsEventLogs = [System.Collections.ArrayList]::new()

    # Compressing all the workspace events into a single dcr event log
    $dcrWindowsEvent = New-Object DCRWindowsEvent
    $dcrWindowsEvent.name = "DS_WindowsEventLogs"
    $dcrWindowsEvent.streams = $dcrWindowsEventLogsStream
    $dcrWindowsEvent.xPathQueries = @()

    $iter_count = 0

    foreach($windowsEvent in $workspaceWindowsEvents)
    {
        $xPathQuery = Get-XPathQueryKey -WindowsEventProperties $windowsEvent.Properties
        $dcrWindowsEvent.xPathQueries += "$($windowsEvent.Properties.eventLogName)!*$($xpathQuery)"
        $iter_count += 1
    }

    if ($iter_count -ne 0)
    {
        $dcrWindowsEventLogs.Add($dcrWindowsEvent) | Out-Null
    }
    
    return $dcrWindowsEventLogs
}

function Get-XPathQueryKey
{
    param (
        [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.OperationalInsights.Models.PSWindowsEventDataSourceProperties] $WindowsEventProperties
    )

    # AMA defines five log levels 
    # Critical (1), Error (2), Warning(3), Information(4) Verbose(5) and Undefined/Anything else (0)
    # whereas MMA seems to only have three
    # Error (2), Warning(3) and Information(4) 
    # but if set to collect Error event at MMA, both Error and Critical will be collected as Errro event.

    $eventTypeStr = ""

    foreach($type in $WindowsEventProperties.eventTypes)
    {   
        if($eventTypeStr.Length -gt 0)
        {
            $eventTypeStr += " or "
        }

        if($type.eventType.ToString() -eq "Error")
        {
            $eventTypeStr += "Level=1 or Level=2"
        }
        elseif($type.eventType.ToString() -eq "Warning")
        {
            $eventTypeStr += "Level=3"
        }
        elseif($type.eventType.ToString() -eq "Information")
        {
            $eventTypeStr += "Level=4"
        }
    }

    #Example: [System[(Level=1 or Level=2 or Level=3)]]
    return "[System[($($eventTypeStr))]]"
}

function Get-CustomLogsInDCRFormat
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName
    )

    $dataSourceType = "CustomLog"
    $workspaceDataSourceList = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind $dataSourceType

    $dcrCustomLogs = New-Object DCRCustomLogFiles
    $dcrCustomLogSettings = New-Object DCRCustomLogSettings
    $dcrCustomLogSettings.text = New-Object DCRCustomLogSettingsText
    $dcrCustomLogs.settings = $dcrCustomLogSettings

    foreach($dataSource in $workspaceDataSourceList)
    {    
        if ($dataSource.Properties -ne $null -and $dataSource.Properties.customLogName -ne $null -and $dataSource.Properties.inputs -ne $null)
        {
            $properties = $dataSource.Properties
            $tableName = $properties.customLogName

            foreach($input in $properties.inputs)
            {
                if($input.location -ne $null -and $input.location.fileSystemLocations -ne $null)
                {
                    $filePatterns = $null
                    if($input.location.fileSystemLocations.linuxFileTypeLogPaths -ne $null)
                    {
                        $filePatterns = $input.location.fileSystemLocations.linuxFileTypeLogPaths
                    }
                    elseif($input.location.fileSystemLocations.windowsFileTypeLogPaths -ne $null)
                    {
                        $filePatterns = $input.location.fileSystemLocations.windowsFileTypeLogPaths
                    }

                    $dcrCustomLogs.filePatterns += $filePatterns
                }
                else 
                {
                    Write-Output "Error: Custom log Data Source does not contain location information."    
                }
            }
            
            $dcrCustomLogs.streams += $tableName
            $dcrCustomLogs.name = $dataSource.Name
            $dcrCustomLogs.settings.text = @{
                "recordStartTimestampFormat" = "ISO 8601"
            }
            $dcrCustomLogs.format = "text"
        }
        else 
        {
            Write-Output "Error: Custom log Data Source does not contain properties information."
        }
    }
    return $dcrCustomLogs
}

function Get-IisLogsInDCRFormat
{
    $dataSourceType = "iisLog"
    $dcrIisLogStream = Get-DCRStream -DataSourceType $dataSourceType

    $newIisLog = New-Object DCRIISLog
    $newIisLog.name = "DS_IISLogs"
    $newIisLog.streams = $dcrIisLogStream

    return $newIisLog
}

function Get-LinuxSyslogInDCRFormat
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName
    )

    $dataSourceType = "LinuxSyslog"
    $workspaceDataSourceList = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind $dataSourceType
    $dcrLinuxSyslogStream = Get-DCRStream -DataSourceType $dataSourceType

    $dcrLinuxSyslogTable = @{}
    $count = 1
    foreach($dataSource in $workspaceDataSourceList)
    {
        $properties = $dataSource.Properties
        if($properties.syslogSeverities.Length -gt 0)
        {
            $syslogLevels = Get-SyslogLevels -LinuxSyslogProperties $properties
            $logLevelsKey = $syslogLevels -join "-"
            if($dcrLinuxSyslogTable.Contains($logLevelsKey))
            {
                $dcrLinuxSyslogTable[$logLevelsKey].facilityNames += Get-SyslogFacilityName  -mmaFacilityName $properties.syslogName
            }
            else
            {
                $newLinuxSyslog = New-Object DCRLinuxSyslog
                $newLinuxSyslog.name = "DS_$($dataSourceType)_$($count)"
                $facilityName = Get-SyslogFacilityName  -mmaFacilityName $properties.syslogName
                $newLinuxSyslog.facilityNames = @($facilityName)
                $newLinuxSyslog.logLevels = $syslogLevels
                $newLinuxSyslog.streams = $dcrLinuxSyslogStream
                $dcrLinuxSyslogTable.Add($logLevelsKey, $newLinuxSyslog)
                $count += 1
            }
        }
    }

    $dcrDataSourceList = [System.Collections.ArrayList]::new()
    foreach($key in $dcrLinuxSyslogTable.Keys)
    {
        $dcrDataSourceList.Add($dcrLinuxSyslogTable[$key]) | Out-Null
    }

    return $dcrDataSourceList
}

function Get-SyslogLevels
{
    param (
        [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.OperationalInsights.Models.PSLinuxSyslogDataSourceProperties] $LinuxSyslogProperties
    )

    # Sorting the severities 
    # Sometimes the severities from the workpsace may not be in the correct order which is:
    # Emergency, Alert, Critical, Error, Warning, Notice, Info, Debug

    $sortedSeverities = New-Object string[] 8
    foreach($sev in $LinuxSyslogProperties.SyslogSeverities)
    {
        switch ($sev.Severity.value__) {
            0 { $sortedSeverities[0] = "Emergency"; Break }
            1 { $sortedSeverities[1] = "Alert"; Break }
            2 { $sortedSeverities[2] = "Critical"; Break }
            3 { $sortedSeverities[3] = "Error"; Break }
            4 { $sortedSeverities[4] = "Warning"; Break }
            5 { $sortedSeverities[5] = "Notice"; Break }
            6 { $sortedSeverities[6] = "Info"; Break }
            7 { $sortedSeverities[7] = "Debug" }
        }
    }

    # Remove the null entries
    $sortedSeverities = $sortedSeverities | Where-Object { $_ -ne $null }

    $syslogLevels = @()
    foreach($severity in $sortedSeverities)
    {
        switch($severity)
        {
            Emergency { $syslogLevels += "Emergency"; Break }
            Alert { $syslogLevels += "Alert"; Break }
            Critical { $syslogLevels += "Critical"; Break }
            Error { $syslogLevels += "Error"; Break }
            Warning { $syslogLevels += "Warning"; Break }
            Notice { $syslogLevels += "Notice"; Break }
            Info { $syslogLevels += "Info"; Break }
            Debug { $syslogLevels += "Debug" }
        }
    }

    [array]::Reverse($syslogLevels)
    return $syslogLevels
}

function Get-SyslogFacilityName
{
    param (
        [Parameter(Mandatory=$true)][string] $MmaFacilityName
    )

    $amaFacilityName = ""
   
    switch($MmaFacilityName)
    {
        "auth"     { $amaFacilityName = "auth"; Break }
        "authpriv" { $amaFacilityName = "authpriv"; Break }
        "cron"     { $amaFacilityName = "cron"; Break }
        "daemon"   { $amaFacilityName = "daemon"; Break }
        "ftp"      { $amaFacilityName = "mark"; Break } # ftp resolves to mark going from MMA to AMA
        "kern"     { $amaFacilityName = "kern"; Break }
        "local0"   { $amaFacilityName = "local0"; Break }
        "local1"   { $amaFacilityName = "local1"; Break }
        "local2"   { $amaFacilityName = "local2"; Break }
        "local3"   { $amaFacilityName = "local3"; Break }
        "local4"   { $amaFacilityName = "local4"; Break }
        "local5"   { $amaFacilityName = "local5"; Break }
        "local6"   { $amaFacilityName = "local6"; Break }
        "local7"   { $amaFacilityName = "local7"; Break }
        "lpr"      { $amaFacilityName = "lpr"; Break  }
        "mail"     { $amaFacilityName = "mail"; Break }
        "news"     { $amaFacilityName = "news"; Break }
        "syslog"   { $amaFacilityName = "syslog"; Break }
        "user"     { $amaFacilityName = "user"; Break }
        "uucp"     { $amaFacilityName = "uucp"; Break }
        default    { $amaFacilityName = "*"; Break } # Is this safe to assume wildcad whenever there is no match?
    }

    return $amaFacilityName
}

function Get-Destinations
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName
    )

    $workspace = Get-UserWorkspace -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName

    $laDest = 
    [ordered]@{
        "workspaceResourceId" = $workspace.ResourceId;
        "workspaceId" = $workspace.CustomerId;
        "name" = $WorkspaceName;
    }

    $logAnalytics = @($laDest)
    $destinations = 
    @{
        "logAnalytics" = $logAnalytics;
    }
    
    return $destinations

}

function Get-DCRStream
{
    param (
        [ValidateSet("WindowsPerformanceCounter", "WindowsEvent", "LinuxSyslog", "LinuxPerformanceObject", "CustomLog", "iisLog")]
        [Parameter(Mandatory=$true)][string] $DataSourceType,
        [Parameter(Mandatory=$false)][string] $WorkspaceName,
        [Parameter(Mandatory=$false)][string] $ResourceGroupName
    )
    
    $stream = @()
    switch($DataSourceType)
    {
        "WindowsPerformanceCounter" { $stream += "Microsoft-Perf"; Break }
        "LinuxPerformanceObject" { $stream += "Microsoft-Perf"; Break }
        "WindowsEvent" { $stream += "Microsoft-Event"; Break }
        "LinuxSyslog" { $stream += "Microsoft-Syslog"; Break }
        "CustomLog" 
        {
            $workspaceDataSourceList = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind $dataSourceType
            foreach($dataSource in $workspaceDataSourceList)
            {
                if ($dataSource.Properties -ne $null -and $dataSource.Properties.customLogName -ne $null)
                {
                    $stream += "Custom-" + $dataSource.Properties.customLogName
                }
            }
            Break
        }

        "IISLog" { $stream += "Microsoft-W3CIISLog"; Break }
    }

    return $stream
}

function GetOrCreate-DataCollectionEndpoint
{
    param (
        [Parameter(Mandatory=$true)][string] $SubscriptionId,
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName,
        [Parameter(Mandatory=$true)][string] $DCEName
    )

    if ($DCEName -eq "null")
    {
        $DCEName = $SubscriptionId + "-dce"
    }
    
    # If DCE does not exist, it will create a new one. If it does exists, it will return the existing one
    $dce = az monitor data-collection endpoint create --name $dceName --public-network-access "Enabled" --resource-group $ResourceGroupName
    if ($dce.Count -gt 0)
    {
        return $dce | ConvertFrom-Json
    }
    else {
        Write-Host "Error: Unable to get or create a Data Collection Endpoint."
        return $null
    }
}

function Get-DataFlows
{
    param (
        [Parameter(Mandatory=$true)][string] $WorkspaceName,
        [ValidateSet("Linux", "Windows")]
        [Parameter(Mandatory=$true)][string] $PlatformType,
        [Parameter(Mandatory=$true)][string] $ResourceGroupName
    )

    if($PlatformType -eq "Linux")
    {
        $perfCountersStream = Get-DCRStream -DataSourceType LinuxPerformanceObject
    }
    else
    {
        $perfCountersStream = Get-DCRStream -DataSourceType WindowsPerformanceCounter
    }
    
    $windowsEventsStream = Get-DCRStream -DataSourceType WindowsEvent
    $linuxSyslogStream = Get-DCRStream -DataSourceType LinuxSyslog

    if($PlatformType -eq "Linux")
    {
        $streams = @($perfCountersStream, $linuxSyslogStream)
    }
    else
    {
        $streams = @($perfCountersStream, $windowsEventsStream)
    }

    $streams += Get-DCRStream -DataSourceType CustomLog -WorkspaceName $WorkspaceName -ResourceGroupName $ResourceGroupName
    $streams += Get-DCRStream -DataSourceType IISLog

    $destinations = @($WorkspaceName)
    $workspaceDataFlow = 
    [ordered]@{
        "streams" = $streams;
        "destinations" = $destinations;
    }
    
    $dataFlows = @($workspaceDataFlow)
    return $dataFlows
}

function Get-CustomLogStreamDeclarations
{
    param (
        [Parameter(Mandatory=$true)][string] $ResourceGroupName,
        [Parameter(Mandatory=$true)][string] $WorkspaceName
    )

    $dataSourceType = "CustomLog"
    $workspaceDataSourceList = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind $dataSourceType
    $streamDeclarations = @{}

    foreach($dataSource in $workspaceDataSourceList)
    {
        if($dataSource.Properties -ne $null -and $dataSource.Properties.customLogName -ne $null)
        {
            $streamName = "Custom-" + $dataSource.Properties.customLogName
            $streamDeclarations[$streamName] = @{
                "columns" = @(
                    @{
                        "name" = "TimeGenerated";
                        "type" = "datetime";
                    },
                    @{
                        "name" = "RawData";
                        "type" = "string";
                    }
                )
            }
        }
        else {
            Write-Host "Error: Unable to get stream name for Custom Log data source."
        }
    }
    return $streamDeclarations
}

function ConnectToAz {
    param (
        # This helps tie the AzContext to a specific Subscription 
        [Parameter(Mandatory=$true)][string] $SubscriptionId
    )

    $azContext = Get-AzContext

    if ($null -ne $azContext)
    {
        Write-Output "You are already logged into Azure"

        $currentAzContextSubId = $azContext.Subscription.Id

        if($currentAzContextSubId -ne $SubscriptionId)
        {
            #Switching to a different Subscription
            Set-AzContext -Subscription $SubscriptionId
        }
    }
    else 
    {
        try 
        {
            Write-Output "Connecting to Azure..."
            Connect-AzAccount | Out-Null
            Set-AzContext -Subscription $SubscriptionId | Select-Object -Property Name, Account, Environment, Subscription | Format-List
            Write-Output "Successfully connected to Azure"
        }
        catch 
        {
            Write-Output "Error connection to Azure. Please try again!"
            Exit
        }
    }
}

<# ====================================== #>
# Output Folder
if(-not ($PSBoundParameters.ContainsKey('FolderPath')))
{
    $FolderPath = "."
}

if($FolderPath.LastIndexOf("/") -eq $FolderPath.Length-1)
{
    $FolderPath = $FolderPath.Substring(0, $FolderPath.Length-1)
}

# User parameters selections
Write-Output "You entered:"
Write-Output ""
Write-Output "Subscription Id     $($SubscriptionId)"
Write-Output "ResourceGroupName   $($ResourceGroupName)"
Write-Output "Workspace Name      $($WorkspaceName)"
Write-Output ""

# User authentication
$WarningPreference = 'SilentlyContinue'
ConnectToAz -SubscriptionId $SubscriptionId

# Entry point of the script
Get-DCRFromWorkspace -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -DCRName $DCRName -Location $Location -FolderPath $FolderPath -SubscriptionId $SubscriptionId -DCEName $DCEName

# End of script
Write-Output ""
Write-Output "Success!"
Write-Output "Check your output folder! (Relative path:  $($FolderPath))"
