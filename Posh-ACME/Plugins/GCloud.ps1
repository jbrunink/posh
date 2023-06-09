function Get-CurrentPluginType { 'dns-01' }

function Add-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)]
        [string]$RecordName,
        [Parameter(Mandatory,Position=1)]
        [string]$TxtValue,
        [Parameter(Mandatory,Position=2)]
        [string]$GCKeyFile,
        [string[]]$GCProjectId,
        [Parameter(ValueFromRemainingArguments)]
        $ExtraParams
    )

    # Cloud DNS API Reference
    # https://cloud.google.com/dns/api/v1beta2/

    Connect-GCloudDns $GCKeyFile
    if (-not $GCProjectId) { $GCProjectId = @($script:GCToken.DefaultProject) }

    Write-Verbose "Attempting to find hosted zone for $RecordName"
    if (-not ($zoneID,$projID = Find-GCZone $RecordName $GCProjectId)) {
        throw "Unable to find Google hosted zone for $RecordName in project(s) $($GCProjectId -join ',')"
    }

    $recRoot = "https://www.googleapis.com/dns/v1beta2/projects/$projID/managedZones/$zoneID"

    # query the current txt record set
    $queryParams = @{
        Uri = '{0}/rrsets?type=TXT&name={1}.' -f $recRoot,$RecordName
        Headers = $script:GCToken.AuthHeader
        Verbose = $false
        ErrorAction = 'Stop'
    }
    try {
        Write-Debug "GET $($queryParams.Uri)"
        $response = Invoke-RestMethod @queryParams @script:UseBasic
        Write-Debug ($response | ConvertTo-Json -Depth 5)
    } catch { throw }
    $rrsets = $response.rrsets

    if ($rrsets.Count -eq 0) {
        # create a new record from scratch
        Write-Debug "Creating new record for $RecordName"
        $changeBody = @{
            additions = @(
                @{
                    name    = "$RecordName."
                    type    = 'TXT'
                    ttl     = 10
                    rrdatas = @("`"$TxtValue`"")
                }
            )
        }
    } else {
        if ("`"$TxtValue`"" -in $rrsets[0].rrdatas) {
            Write-Debug "Record $RecordName already contains $TxtValue. Nothing to do."
            return
        }

        # append to the existing value list which basically involves
        # both deleting and re-creating the record in the same "change"
        # operation
        Write-Debug "Appending to $RecordName with $($rrsets[0].Count) existing value(s)"
        $toDelete = $rrsets[0] | ConvertTo-Json | ConvertFrom-Json
        $rrsets[0].rrdatas += "`"$TxtValue`""
        $changeBody = @{
            deletions = @($toDelete)
            additions = @($rrsets[0])
        }
    }

    Write-Verbose "Sending update for $RecordName"
    $queryParams = @{
        Uri         = "$recRoot/changes"
        Method      = 'Post'
        Body        = ($changeBody | ConvertTo-Json -Depth 5)
        Headers     = $script:GCToken.AuthHeader
        ContentType = 'application/json'
        Verbose     = $false
        ErrorAction = 'Stop'
    }
    try {
        Write-Debug "POST $($queryParams.Uri)`n$($changeBody | ConvertTo-Json -Depth 5)"
        $response = Invoke-RestMethod @queryParams @script:UseBasic
        Write-Debug ($response | ConvertTo-Json -Depth 5)
    } catch { throw }

    <#
    .SYNOPSIS
        Add a DNS TXT record to Google Cloud DNS.

    .DESCRIPTION
        Add a DNS TXT record to Google Cloud DNS.

    .PARAMETER RecordName
        The fully qualified name of the TXT record.

    .PARAMETER TxtValue
        The value of the TXT record.

    .PARAMETER GCKeyFile
        Path to a service account JSON file that contains the account's private key and other metadata. This should have been downloaded when originally creating the service account.

    .PARAMETER GCProjectId
        The Project ID (or IDs) that contain the DNS zones you will be modifying. This is only required if the GCKeyFile references an account in a different project than the DNS zone or you have zones in multiple projects. When using this parameter, include the project ID associated with the GCKeyFile in addition to any others you need.

    .PARAMETER ExtraParams
        This parameter can be ignored and is only used to prevent errors when splatting with more parameters than this function supports.

    .EXAMPLE
        Add-DnsTxt '_acme-challenge.example.com' 'txt-value' -GCKeyFile .\account.json

        Adds a TXT record for the specified site with the specified value using the specified Google Cloud service account.
    #>
}

function Remove-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)]
        [string]$RecordName,
        [Parameter(Mandatory,Position=1)]
        [string]$TxtValue,
        [Parameter(Mandatory,Position=2)]
        [string]$GCKeyFile,
        [Parameter(ValueFromRemainingArguments)]
        $ExtraParams
    )

    # Cloud DNS API Reference
    # https://cloud.google.com/dns/api/v1beta2/

    Connect-GCloudDns $GCKeyFile
    if (-not $GCProjectId) { $GCProjectId = @($script:GCToken.DefaultProject) }

    Write-Verbose "Attempting to find hosted zone for $RecordName"
    if (-not ($zoneID,$projID = Find-GCZone $RecordName $GCProjectId)) {
        throw "Unable to find Google hosted zone for $RecordName in project(s) $($GCProjectId -join ',')"
    }

    $recRoot = "https://www.googleapis.com/dns/v1beta2/projects/$projID/managedZones/$zoneID"

    # query the current txt record set
    $queryParams = @{
        Uri = '{0}/rrsets?type=TXT&name={1}.' -f $recRoot,$RecordName
        Headers = $script:GCToken.AuthHeader
        Verbose = $false
        ErrorAction = 'Stop'
    }
    try {
        Write-Debug "GET $($queryParams.Uri)"
        $response = Invoke-RestMethod @queryParams @script:UseBasic
        Write-Debug ($response | ConvertTo-Json -Depth 5)
    } catch { throw }
    $rrsets = $response.rrsets

    if ($rrsets.Count -eq 0) {
        Write-Debug "Record $RecordName already deleted."
        return
    } else {
        if ("`"$TxtValue`"" -notin $rrsets[0].rrdatas) {
            Write-Debug "Record $RecordName doesn't contain $TxtValue. Nothing to do."
            return
        }

        # removing the value involves deleting the existing record and
        # re-creating it without the value in the same change set. But if it's
        # the last one, we just want to delete it.
        Write-Debug "Removing from $RecordName with $($rrsets[0].Count) existing value(s)"
        $changeBody = @{
            deletions = @(
                ($rrsets[0] | ConvertTo-Json | ConvertFrom-Json)
            )
        }
        if ($rrsets[0].rrdatas.Count -gt 1) {
            $rrsets[0].rrdatas = @(
                $rrsets[0].rrdatas | Where-Object { $_ -ne "`"$TxtValue`"" }
            )
            $changeBody.additions = @($rrsets[0])
        }
    }

    Write-Verbose "Sending update for $RecordName"
    $queryParams = @{
        Uri         = "$recRoot/changes"
        Method      = 'Post'
        Body        = ($changeBody | ConvertTo-Json -Depth 5)
        Headers     = $script:GCToken.AuthHeader
        ContentType = 'application/json'
        Verbose     = $false
        ErrorAction = 'Stop'
    }
    try {
        Write-Debug "POST $($queryParams.Uri)`n$($changeBody | ConvertTo-Json -Depth 5)"
        $response = Invoke-RestMethod @queryParams @script:UseBasic
        Write-Debug ($response | ConvertTo-Json -Depth 5)
    } catch { throw }

    <#
    .SYNOPSIS
        Remove a DNS TXT record from Google Cloud DNS.

    .DESCRIPTION
        Remove a DNS TXT record from Google Cloud DNS.

    .PARAMETER RecordName
        The fully qualified name of the TXT record.

    .PARAMETER TxtValue
        The value of the TXT record.

    .PARAMETER GCKeyFile
        Path to a service account JSON file that contains the account's private key and other metadata. This should have been downloaded when originally creating the service account.

    .PARAMETER GCProjectId
        The Project ID (or IDs) that contain the DNS zones you will be modifying. This is only required if the GCKeyFile references an account in a different project than the DNS zone or you have zones in multiple projects. When using this parameter, include the project ID associated with the GCKeyFile in addition to any others you need.

    .PARAMETER ExtraParams
        This parameter can be ignored and is only used to prevent errors when splatting with more parameters than this function supports.

    .EXAMPLE
        Remove-DnsTxt '_acme-challenge.example.com' 'txt-value' -GCKeyFile .\account.json

        Removes a TXT record the specified site with the specified value using the specified Google Cloud service account.
    #>
}

function Save-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments)]
        $ExtraParams
    )
    <#
    .SYNOPSIS
        Not required.

    .DESCRIPTION
        This provider does not require calling this function to commit changes to DNS records.

    .PARAMETER ExtraParams
        This parameter can be ignored and is only used to prevent errors when splatting with more parameters than this function supports.
    #>
}

############################
# Helper Functions
############################

function Connect-GCloudDns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)]
        [string]$GCKeyFile
    )

    # Using OAuth 2.0 for Server to Server Applications
    # https://developers.google.com/identity/protocols/OAuth2ServiceAccount

    # just return if we've already got a valid non-expired token
    if ($script:GCToken -and (Get-DateTimeOffsetNow) -lt $script:GCToken.Expires) {
        return
    }

    Write-Verbose "Signing into GCloud DNS"

    # We want to cache the contents of GCKeyFile so renewals don't break if the original
    # file is moved/deleted. But we still want to primarily use the actual file by default
    # in case it has been updated.

    # expand the path to the file
    $GCKeyFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($GCKeyFile)

    # get the previously cached values
    $cachedFiles = Import-PluginVar 'GCKeyObj'
    if (-not $cachedFiles -or $cachedFiles -is [string]) {
        $cachedFiles = [pscustomobject]@{}
    }

    if (Test-Path $GCKeyFile -PathType Leaf) {

        Write-Debug "Using key file"
        $GCKeyObj = Get-Content $GCKeyFile -Raw | ConvertFrom-Json

        # add the contents to our cached files
        $b64Contents = $GCKeyObj | ConvertTo-Json -Compress | ConvertTo-Base64Url
        $cachedFiles | Add-Member $GCKeyFile $b64Contents -Force
        Export-PluginVar 'GCKeyObj' $cachedFiles

    } elseif ($GCKeyFile -in $cachedFiles.PSObject.Properties.Name) {

        Write-Warning "GCKeyFile not found at `"$GCKeyFile`". Attempting to use cached key data."
        $b64Contents = $cachedFiles.$GCKeyFile
        try {
            $GCKeyObj = $b64Contents | ConvertFrom-Base64Url | ConvertFrom-Json
        } catch { throw }

    } else {
        throw "GCKeyFile not found at `"$GCKeyFile`" and no cached data exists."
    }

    Write-Debug "Loading private key for $($GCKeyObj.client_email)"
    $key = Import-Pem -InputString $GCKeyObj.private_key | ConvertFrom-BCKey

    $unixNow = (Get-DateTimeOffsetNow).ToUnixTimeSeconds()

    # build the claim set for DNS read/write
    $jwtClaim = @{
        iss   = $GCKeyObj.client_email
        aud   = $GCKeyObj.token_uri
        scope = 'https://www.googleapis.com/auth/ndev.clouddns.readwrite'
        exp   = ($unixNow + 3600).ToString()
        iat   = $unixNow.ToString()
    }
    Write-Debug "Claim set: $($jwtClaim | ConvertTo-Json)"

    # build a signed jwt
    $header = @{alg='RS256';typ='JWT'}
    $jwt = New-Jws $key $header ($jwtClaim | ConvertTo-Json -Compress) -Compact -NoHeaderValidation

    # build the POST body
    $authBody = "assertion=$jwt&grant_type=$([uri]::EscapeDataString('urn:ietf:params:oauth:grant-type:jwt-bearer'))"

    # attempt to sign in
    try {
        Write-Debug "Sending OAuth2 login"
        $response = Invoke-RestMethod $GCKeyObj.token_uri -Method Post -Body $authBody @script:UseBasic
        Write-Debug ($response | ConvertTo-Json)
    } catch { throw }

    # save a custom token to memory
    $script:GCToken = @{
        AuthHeader = @{
            Authorization = "$($response.token_type) $($response.access_token)"
        }
        Expires = (Get-DateTimeOffsetNow).AddSeconds($response.expires_in - 300)
        DefaultProject = $GCKeyObj.project_id
    }

}

function Find-GCZone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)]
        [string]$RecordName,
        [Parameter(Mandatory,Position=1)]
        [string[]]$GCProjectId
    )

    # setup a module variable to cache the record to zone mapping
    # so it's quicker to find later
    if (!$script:GCRecordZones) { $script:GCRecordZones = @{} }

    # check for the record in the cache
    if ($script:GCRecordZones.ContainsKey($RecordName)) {
        return $script:GCRecordZones.$RecordName
    }

    # get the list of available zones across the projects we have IDs for
    $zones = @($GCProjectId | ForEach-Object {
        $projID = $_
        $queryParams = @{
            Uri = "https://www.googleapis.com/dns/v1beta2/projects/$projID/managedZones"
            Headers = $script:GCToken.AuthHeader
            Verbose = $false
            ErrorAction = 'Stop'
        }
        Write-Debug "GET $($queryParams.Uri)"
        try {
            Invoke-RestMethod @queryParams @script:UseBasic |
                Select-Object -ExpandProperty managedZones |
                Where-Object { $_.visibility -eq 'public' } |
                Select-Object id,dnsName,@{L='projID';E={$projID}}
        } catch { throw }
    })

    if ($zones.Count -eq 0) {
        throw "No managed zones found"
    }

    # Since Google could be hosting both apex and sub-zones, we need to find the closest/deepest
    # sub-zone that would hold the record rather than just adding it to the apex. So for something
    # like _acme-challenge.site1.sub1.sub2.example.com, we'd look for zone matches in the following
    # order:
    # - site1.sub1.sub2.example.com
    # - sub1.sub2.example.com
    # - sub2.example.com
    # - example.com

    $pieces = $RecordName.Split('.')
    for ($i=0; $i -lt ($pieces.Count-1); $i++) {
        $zoneTest = "$( $pieces[$i..($pieces.Count-1)] -join '.' )."
        Write-Debug "Checking $zoneTest"

        if ($zoneMatch = $zones | Where-Object { $_.dnsName -eq $zoneTest }) {
            $zoneID = $zoneMatch.id
            $projID = $zoneMatch.projID
            $script:GCRecordZones.$RecordName = @($zoneID,$projID)
            return @($zoneID,$projID)
        }
    }

    return $null
}
