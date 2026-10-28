# Ativacao automatica do E9 (Windows PowerShell 5.1+ / PowerShell 7+).
# Execute a partir de qualquer diretorio: .\ativar-dnssec.ps1

# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "scripts\_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'E9'
    return
}
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-DockerChecked {
    param([string[]]$DockerArgs)
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) { throw "Docker falhou (codigo $LASTEXITCODE): docker $($DockerArgs -join ' ')" }
}

Push-Location $PSScriptRoot
try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker nao encontrado no PATH.' }
    Invoke-DockerChecked @('compose','config','--quiet')
    foreach ($service in @('ns1','ns2','ns3','resolvedor','cliente')) {
        $running = (& docker inspect -f '{{.State.Running}}' $service 2>$null)
        if ($LASTEXITCODE -ne 0 -or "$running".Trim() -ne 'true') {
            throw "O conteiner '$service' nao esta ativo. Execute docker compose up -d --build primeiro."
        }
    }

    $ns1Path = '.\configs\ns1\named.conf'
    $resolverPath = '.\configs\resolvedor\named.conf'
    $anchorPath = '.\configs\resolvedor\trust-anchors.conf'
    foreach ($path in @($ns1Path,$resolverPath,$anchorPath)) {
        if (-not (Test-Path $path)) { throw "Arquivo ausente: $path" }
    }
    if (-not (Test-Path '.\configs\ns1\named.conf.dnssec') -or
        -not (Test-Path '.\configs\resolvedor\named.conf.dnssec')) {
        throw 'Arquivos .dnssec ausentes na pasta configs.'
    }

    # Copias locais para permitir restauracao em caso de falha.
    Copy-Item $ns1Path "$ns1Path.pre-e9" -Force
    Copy-Item $resolverPath "$resolverPath.pre-e9" -Force
    Copy-Item $anchorPath "$anchorPath.pre-e9" -Force

    Write-Host '1/4 Ativando assinatura DNSSEC no ns1...' -ForegroundColor Cyan
    Copy-Item '.\configs\ns1\named.conf.dnssec' $ns1Path -Force
    Invoke-DockerChecked @('exec','ns1','named-checkconf')
    Invoke-DockerChecked @('restart','ns1')

    Write-Host '2/4 Aguardando DNSKEY publicada pelo ns1 (ate 120 s)...' -ForegroundColor Cyan
    $keyFields = $null
    for ($i=0; $i -lt 60; $i++) {
        $dnskeyOutput = @(& docker exec cliente dig '@172.31.0.11' sd.lab DNSKEY +short +time=2 +tries=1 2>$null)
        if ($LASTEXITCODE -eq 0) {
            # dig pode dividir a base64 em varias partes separadas por espacos.
            foreach ($line in $dnskeyOutput) {
                if ($line -match '^\s*257\s+3\s+(\d+)\s+([A-Za-z0-9+/=\s]+)\s*$') {
                    $algorithm = $Matches[1]
                    $keyBase64 = ($Matches[2] -replace '\s+', '')
                    if ($keyBase64.Length -gt 20) {
                        $keyFields = @('257','3',$algorithm,$keyBase64)
                        break
                    }
                }
            }
        }
        if ($null -ne $keyFields) { break }
        Start-Sleep -Seconds 2
    }
    if ($null -eq $keyFields) { throw 'Nao foi possivel obter DNSKEY 257 do ns1. Consulte docker logs ns1.' }

    Write-Host '3/4 Configurando a ancora publica e ativando a validacao...' -ForegroundColor Cyan
    $anchor = 'trust-anchors {' + "`n" +
              '    sd.lab. static-key ' + ($keyFields[0..2] -join ' ') + "`n" +
              '        "' + $keyFields[3] + '";' + "`n" + '};' + "`n"
    [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'configs/resolvedor/trust-anchors.conf'), $anchor, [System.Text.Encoding]::ASCII)
    Copy-Item '.\configs\resolvedor\named.conf.dnssec' $resolverPath -Force
    Invoke-DockerChecked @('exec','resolvedor','named-checkconf')
    Invoke-DockerChecked @('restart','resolvedor')

    Write-Host '4/4 Testando resposta autenticada (ate 60 s)...' -ForegroundColor Cyan
    $success = $false
    for ($i=0; $i -lt 30; $i++) {
        $result = (& docker exec cliente dig '@172.31.0.53' app.sd.lab A +dnssec +nocookie +time=2 +tries=1 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and $result -match 'status:\s*NOERROR' -and
            $result -match 'flags:\s*[^;]*\bad\b' -and $result -match '\bRRSIG\s+A\b') {
            $success = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $success) {
        throw 'Nao foi confirmada resposta NOERROR com flag ad e RRSIG. Verifique docker logs ns1 e docker logs resolvedor.'
    }
    Write-Host 'DNSSEC ativo e validacao confirmada (NOERROR + ad + RRSIG).' -ForegroundColor Green
    Write-Host 'A chave publica esta em configs/resolvedor/trust-anchors.conf; a privada permanece no volume ns1_keys.'
    Write-Host 'Para consultar: docker exec cliente dig "@172.31.0.53" app.sd.lab A +dnssec'
} catch {
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Arquivos anteriores foram salvos com sufixo .pre-e9. Em caso de falha, revise os logs antes de restaurar.' -ForegroundColor Yellow
    throw
} finally {
    Pop-Location
}
