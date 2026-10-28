# Captura padronizada para todos os scripts. PowerShell 5.1+.
param(
    [Parameter(Mandatory=$true)][string]$ScriptPath,
    [System.Collections.IDictionary]$Parametros = @{},
    [string]$Experimento = 'AUX'
)
$ErrorActionPreference = 'Stop'
$raiz = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$nome = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
$marca = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$dir = Join-Path $raiz ("evidencias\{0}\{1}-{2}" -f $Experimento,$marca,$nome)
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$transcricao = Join-Path $dir 'terminal.txt'
$inicio = Get-Date
$status = 'ERRO'
$erro = $null
$iniciouTranscricao = $false
$anterior = $env:DNS_EVIDENCE_WRAPPED
try {
    Start-Transcript -LiteralPath $transcricao -Force -ErrorAction Stop | Out-Null
    $iniciouTranscricao = $true
    Write-Host "Evidencias desta execucao: $dir" -ForegroundColor Cyan
    Write-Host "Script: $ScriptPath | Experimento: $Experimento | Inicio: $($inicio.ToString('o'))"
    # Guarda os parametros de execucao sem modificar o script original.
    $dados = [ordered]@{script=$nome; experimento=$Experimento; inicio=$inicio.ToString('o'); parametros=$Parametros}
    $dados | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'execucao.json') -Encoding UTF8
    $env:DNS_EVIDENCE_WRAPPED = '1'
    & $ScriptPath @Parametros
    if (-not $?) { throw "O script $nome terminou com falha." }
    $status = 'SUCESSO'
} catch {
    $erro = ($_ | Out-String)
    Write-Host "Falha registrada em $dir" -ForegroundColor Red
    $erro | Set-Content -LiteralPath (Join-Path $dir 'erro.txt') -Encoding UTF8
    throw
} finally {
    $env:DNS_EVIDENCE_WRAPPED = $anterior
    $fim = Get-Date
    # Captura contextual adicional, sem depender de prints do script.
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        try {
            $ps = @(& {
                $ErrorActionPreference = 'Continue'
                & docker compose --project-directory $raiz ps --all 2>&1
            })
            $codigo = $LASTEXITCODE
            $ps | Out-File -LiteralPath (Join-Path $dir 'docker-compose-ps.txt') -Encoding UTF8 -Width 400
            if ($codigo -ne 0) { throw "docker compose ps retornou $codigo" }
        } catch { "Falha ao coletar docker compose ps: $_" | Set-Content (Join-Path $dir 'docker-ps-erro.txt') }
        foreach ($servico in @('ns1','ns2','ns3','resolvedor')) {
            try {
                $desde = $inicio.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                $saida = @(& {
                    $ErrorActionPreference = 'Continue'
                    & docker logs --since $desde $servico 2>&1
                })
                $codigo = $LASTEXITCODE
                $saida | Out-File -LiteralPath (Join-Path $dir "logs-$servico.txt") -Encoding UTF8 -Width 400
                if ($codigo -ne 0) { throw "docker logs $servico retornou $codigo" }
            } catch { "Falha ao coletar logs $servico`: $_" | Set-Content (Join-Path $dir "logs-$servico-erro.txt") }
        }
    }
    $resumo = [ordered]@{
        script=$nome; experimento=$Experimento; status=$status;
        inicio=$inicio.ToString('o'); fim=$fim.ToString('o');
        duracao_segundos=[math]::Round(($fim-$inicio).TotalSeconds,3);
        erro=if ($erro) {$erro.Trim()} else {$null}
    }
    $resumo | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'resultado.json') -Encoding UTF8
    if ($iniciouTranscricao) { try { Stop-Transcript | Out-Null } catch {} }
    Write-Host "Evidencias: $dir | Status: $status"
}
