#Requires -Modules Pester
# TaRouting.Tests.ps1 — unit tests for the routing-config toggle helpers
# These functions are pure string transforms — no file I/O, no network, fully deterministic.

# Top-level BeforeAll: path setup runs during the run phase, not just discovery.
# Pester v5 does NOT carry script-level user variables into BeforeAll/It blocks.
BeforeAll {
    $script:repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:scriptDir = Join-Path $script:repoRoot 'src\Cobol2c.Runner\scripts'
    Import-Module (Join-Path $script:scriptDir 'TaRouting.psm1') -Force
}

Describe 'TaRouting helpers' {
    BeforeAll {
        # Sample routing config: GridInterface ships C#-enabled (~), FormFormatting is COBOL
        $script:json = '{"~Gss.Support.Base.GridInterface":"GSSERP.SCR100","Gss.Support.Base.FormFormattingInterface":"GSSERP.SCR003"}'
    }

    Describe 'Get-RouteKey' {
        It 'finds key by COBOL program name (no GSSERP. prefix)' {
            Get-RouteKey $json 'SCR100' | Should -Be 'Gss.Support.Base.GridInterface'
        }

        It 'finds key by COBOL program name (with GSSERP. prefix)' {
            Get-RouteKey $json 'GSSERP.SCR003' | Should -Be 'Gss.Support.Base.FormFormattingInterface'
        }

        It 'returns null for an unlisted program' {
            Get-RouteKey $json 'INV010XR' | Should -BeNullOrEmpty
        }
    }

    Describe 'Use-Cobol (force COBOL — remove ~)' {
        It 'removes ~ from a C#-enabled entry' {
            $key    = Get-RouteKey $json 'SCR100'
            $result = Use-Cobol $json $key
            $result | Should -Match '"Gss.Support.Base.GridInterface":'
            $result | Should -Not -Match '"~Gss.Support.Base.GridInterface"'
        }

        It 'is idempotent when ~ is already absent' {
            $key    = Get-RouteKey $json 'SCR003'
            $result = Use-Cobol $json $key
            # SCR003 had no ~ — should be unchanged
            $result | Should -Be $json
        }
    }

    Describe 'Use-Csharp (restore C# — add ~)' {
        It 'adds ~ to a COBOL-routed entry' {
            $key    = Get-RouteKey $json 'SCR003'
            $result = Use-Csharp $json $key
            $result | Should -Match '"~Gss.Support.Base.FormFormattingInterface"'
        }

        It 'is idempotent when ~ is already present' {
            $key    = Get-RouteKey $json 'SCR100'
            $result = Use-Csharp $json $key
            $result | Should -Be $json
        }
    }

    Describe 'Add-CobolRoute (bring unlisted program under control)' {
        It 'inserts a new no-~ entry for an unlisted program' {
            $result = Add-CobolRoute $json 'Gss.SupplyChain.Inventory.Base.PartCrossReferenceMaintenance' 'INV010XR'
            $result | Should -Match '"Gss.SupplyChain.Inventory.Base.PartCrossReferenceMaintenance"'
            $result | Should -Match '"GSSERP.INV010XR"'
            # Must NOT have a ~ (COBOL routing on)
            $result | Should -Not -Match '"~Gss.SupplyChain'
        }

        It 'is idempotent when the class is already in the JSON' {
            $result = Add-CobolRoute $json 'Gss.Support.Base.GridInterface' 'SCR100'
            $result | Should -Be $json
        }

        It 'strips GSSERP. prefix from the pgm argument' {
            $result = Add-CobolRoute $json 'Some.New.Class' 'GSSERP.INV999'
            $result | Should -Match '"GSSERP.INV999"'
            $result | Should -Not -Match '"GSSERP.GSSERP'
        }

        It 'produces valid JSON when inserting into an empty object' {
            # Regression for the trailing-comma bug: Insert into {} would yield {"x":"y",}
            $result = Add-CobolRoute '{}' 'Gss.NewModule.SomeClass' 'NEW001'
            { $result | ConvertFrom-Json } | Should -Not -Throw
            $result | Should -Match '"Gss.NewModule.SomeClass"'
            $result | Should -Match '"GSSERP.NEW001"'
        }
    }

    Describe 'Round-trip: Use-Cobol then Use-Csharp restores original' {
        It 'round-trips an existing C#-enabled entry' {
            $key      = Get-RouteKey $json 'SCR100'
            $cobol    = Use-Cobol  $json  $key
            $restored = Use-Csharp $cobol $key
            $restored | Should -Be $json
        }
    }
}
