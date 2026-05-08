@{
    RootModule = 'CippLocalAuth.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'CIPP Linux'
    Description = 'Local authentication module for CIPP Linux deployment'
    FunctionsToExport = @(
        'Get-JWTSecret',
        'New-JWTToken',
        'Test-JWTToken',
        'Get-CippLocalUsers',
        'Get-CippLocalUser',
        'New-CippLocalUser',
        'Confirm-CippLocalLogin'
    )
}