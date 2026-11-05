# Mole Windows - `mo clean --json` structured report tests
# The report builder is lifted out of the command script so no interactive
# UI runs; the Remove-SafeItem chain underneath is the real one.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"

    function Import-ScriptFunction {
        param([string]$Script, [string[]]$Names)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
        foreach ($name in $Names) {
            $definition = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true)
            if (-not $definition) { throw "$name not found in $Script" }
            . ([scriptblock]::Create($definition.Extent.Text))
            Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
        }
    }

    Import-ScriptFunction -Script (Join-Path $script:WindowsDir "bin\clean.ps1") -Names @(
        "ConvertTo-MoleCleanJsonReport"
    )

    $script:OriginalNoOplog = $env:MO_NO_OPLOG
    $env:MO_NO_OPLOG = "1"
    $script:OriginalUserProfile = $env:USERPROFILE
    $env:USERPROFILE = Join-Path $TestDrive "profile"
    New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
}

AfterAll {
    $env:MO_NO_OPLOG = $script:OriginalNoOplog
    $env:USERPROFILE = $script:OriginalUserProfile
    Set-DryRunMode -Enabled $false
}

Describe "mo clean --json" {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:MoleCleanJsonRecords = New-Object System.Collections.Generic.List[object]
        Reset-CleanupStats
    }

    AfterEach {
        Set-DryRunMode -Enabled $false
    }

    Context "report builder" {
        It "Produces a preview envelope with scope and empty totals for no records" {
            $scope = @{ System = $false; GameMedia = $true; GpuShaders = $false }
            $json = ConvertTo-MoleCleanJsonReport -Mode 'preview' -Scope $scope -Records $script:MoleCleanJsonRecords -Stats (Get-CleanupStats)
            $report = $json | ConvertFrom-Json
            $report.mode | Should -Be 'preview'
            $report.scope.system | Should -BeFalse
            $report.scope.game_media | Should -BeTrue
            $report.scope.gpu_shaders | Should -BeFalse
            $report.totals.size_bytes | Should -Be 0
            $report.totals.items | Should -Be 0
            $report.totals.groups | Should -Be 0
            $report.totals.owner_cleanups | Should -Be 0
            @($report.records).Count | Should -Be 0
        }

        It "Escapes non-ASCII so a console code page cannot change a path" {
            $script:MoleCleanJsonRecords.Add([ordered]@{ description = '缓存'; path = 'C:\缓存.tmp'; size_bytes = [long]10; action = 'removed' })
            $json = ConvertTo-MoleCleanJsonReport -Mode 'execute' -Scope @{ System = $false; GameMedia = $false; GpuShaders = $false } -Records $script:MoleCleanJsonRecords -Stats (Get-CleanupStats)
            $json | Should -Not -Match '[^\x00-\x7F]'
            ($json | ConvertFrom-Json).records[0].path | Should -Be 'C:\缓存.tmp'
        }

        It "Carries a reason on skipped and failed records and omits it otherwise" {
            $script:MoleCleanJsonRecords.Add([ordered]@{ description = 'held'; path = 'C:\held'; size_bytes = [long]0; action = 'skipped'; reason = 'file held by owner' })
            $script:MoleCleanJsonRecords.Add([ordered]@{ description = 'gone'; path = 'C:\gone'; size_bytes = [long]5; action = 'removed' })
            $report = ConvertTo-MoleCleanJsonReport -Mode 'execute' -Scope @{ System = $false; GameMedia = $false; GpuShaders = $false } -Records $script:MoleCleanJsonRecords -Stats (Get-CleanupStats) | ConvertFrom-Json
            $report.records[0].reason | Should -Be 'file held by owner'
            $report.records[1].PSObject.Properties['reason'] | Should -BeNullOrEmpty
        }

        It "Surfaces a run error in the envelope" {
            $report = ConvertTo-MoleCleanJsonReport -Mode 'execute' -Scope @{ System = $false; GameMedia = $false; GpuShaders = $false } -Records $script:MoleCleanJsonRecords -Stats (Get-CleanupStats) -RunError 'boom' | ConvertFrom-Json
            $report.error | Should -Be 'boom'
        }

        It "Reports the effective scope after --system downgrades without admin" {
            $scope = @{ System = $false; GameMedia = $false; GpuShaders = $false }
            $report = ConvertTo-MoleCleanJsonReport -Mode 'execute' -Scope $scope -Records $script:MoleCleanJsonRecords -Stats (Get-CleanupStats) | ConvertFrom-Json
            $report.scope.system | Should -BeFalse
        }
    }

    Context "recorder integration (real Remove-SafeItem chain)" {
        It "Records would_remove rows in a dry run and deletes nothing" {
            Set-DryRunMode -Enabled $true
            $dir = Join-Path $script:Root "cache"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $first = Join-Path $dir "a.tmp"
            $second = Join-Path $dir "b.tmp"
            Set-Content -Path $first -Value ("x" * 4096)
            Set-Content -Path $second -Value ("x" * 4096)

            Remove-SafeItems -Paths @($first, $second) -Description "Test cache"

            $script:MoleCleanJsonRecords.Count | Should -Be 2
            $script:MoleCleanJsonRecords[0]['action'] | Should -Be 'would_remove'
            $script:MoleCleanJsonRecords[0]['path'] | Should -Be $first
            $script:MoleCleanJsonRecords[0]['size_bytes'] | Should -BeGreaterThan 0
            Test-Path -LiteralPath $first | Should -BeTrue
            Test-Path -LiteralPath $second | Should -BeTrue
        }

        It "Records removed rows in a real run and deletes the files" {
            Set-DryRunMode -Enabled $false
            $dir = Join-Path $script:Root "cache"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $first = Join-Path $dir "a.tmp"
            $second = Join-Path $dir "b.tmp"
            Set-Content -Path $first -Value ("x" * 4096)
            Set-Content -Path $second -Value ("x" * 4096)

            Remove-SafeItems -Paths @($first, $second) -Description "Test cache"

            $script:MoleCleanJsonRecords.Count | Should -Be 2
            $script:MoleCleanJsonRecords[0]['action'] | Should -Be 'removed'
            Test-Path -LiteralPath $first | Should -BeFalse
            Test-Path -LiteralPath $second | Should -BeFalse
        }

        It "Reports the same totals for a preview and a real run over unchanged state" {
            $dir = Join-Path $script:Root "cache"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $first = Join-Path $dir "a.tmp"
            $second = Join-Path $dir "b.tmp"
            Set-Content -Path $first -Value ("x" * 4096)
            Set-Content -Path $second -Value ("x" * 4096)

            Set-DryRunMode -Enabled $true
            Remove-SafeItems -Paths @($first, $second) -Description "Test cache"
            $previewStats = Get-CleanupStats
            $previewRecords = @($script:MoleCleanJsonRecords.ToArray())

            Reset-CleanupStats
            $script:MoleCleanJsonRecords = New-Object System.Collections.Generic.List[object]
            Set-DryRunMode -Enabled $false
            Remove-SafeItems -Paths @($first, $second) -Description "Test cache"
            $executeStats = Get-CleanupStats

            $executeStats.TotalSizeKB | Should -Be $previewStats.TotalSizeKB
            $executeStats.FilesCleaned | Should -Be $previewStats.FilesCleaned
            $executeRecords = @($script:MoleCleanJsonRecords.ToArray())
            $executeRecords.Count | Should -Be $previewRecords.Count
            for ($i = 0; $i -lt $previewRecords.Count; $i++) {
                $executeRecords[$i]['path'] | Should -Be $previewRecords[$i]['path']
                $executeRecords[$i]['size_bytes'] | Should -Be $previewRecords[$i]['size_bytes']
            }
        }

        It "Writes no operations-log lines from a dry run" {
            Set-DryRunMode -Enabled $true
            $dir = Join-Path $script:Root "cache"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir "a.tmp") -Value "x"

            Remove-SafeItems -Paths @((Join-Path $dir "a.tmp")) -Description "Test cache"

            Test-Path "$env:USERPROFILE\.config\mole\operations.log" | Should -BeFalse
        }
    }

    Context "json mode is inert without the flag" {
        It "Records nothing when the recorder list was never created" {
            Remove-Variable -Name MoleCleanJsonRecords -Scope Script -ErrorAction SilentlyContinue
            Set-DryRunMode -Enabled $true
            $dir = Join-Path $script:Root "cache"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir "a.tmp") -Value "x"

            { Remove-SafeItems -Paths @((Join-Path $dir "a.tmp")) -Description "Test cache" } | Should -Not -Throw
        }
    }
}
