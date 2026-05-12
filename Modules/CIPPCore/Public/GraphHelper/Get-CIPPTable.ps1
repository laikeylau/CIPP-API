function Get-CIPPTable {
    <#
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param (
        $tablename = 'CippLogs'
    )
    $ContextParams = @{
        ConnectionString = $env:AzureWebJobsStorage
        TableName        = $tablename
    }
    # $ContextParams['MaxConnectionsPerServer'] = 30 # Disabled - AzBobbyTables 3.5.0 doesn't support this
    $Context = New-AzDataTableContext @ContextParams
    New-AzDataTable -Context $Context | Out-Null

    @{
        Context = $Context
    }
}
