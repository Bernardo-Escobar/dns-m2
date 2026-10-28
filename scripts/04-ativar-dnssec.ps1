# E9: habilita assinatura inline no NS1 e validacao no resolvedor.

# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'E9'
    return
}
$ErrorActionPreference = 'Stop'
$base = Resolve-Path "$PSScriptRoot/.."
Push-Location $base
try {
    Write-Host 'Etapa 1: ativando dnssec-policy default e inline-signing no NS1...' -ForegroundColor Cyan
    Copy-Item .\configs\ns1\named.conf.dnssec .\configs\ns1\named.conf -Force
    docker compose restart ns1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao reiniciar NS1.' }

    Write-Host 'Etapa 2: aguardando a publicacao da DNSKEY (ate 90 segundos)...' -ForegroundColor Cyan
    $linha = $null
    for ($i=0; $i -lt 45; $i++) {
        $resposta = @(& docker exec cliente dig "@172.31.0.11" sd.lab DNSKEY +short 2>$null)
        $linha = $resposta | Where-Object { $_ -match '^\s*257\s+3\s+\d+\s+' } | Select-Object -First 1
        if ($linha) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $linha) {
        throw 'DNSKEY ainda nao publicada. Veja: docker compose logs --tail=100 ns1'
    }
    $campos = ($linha.Trim() -split '\s+')
    $chave = ($campos[3..($campos.Length - 1)] -join '')
    $ancora = 'trust-anchors { sd.lab. static-key ' + $campos[0] + ' ' + $campos[1] + ' ' + $campos[2] + ' "' + $chave + '"; };'
    [System.IO.File]::WriteAllText((Resolve-Path .\configs\resolvedor\trust-anchors.conf), $ancora + "`n", [System.Text.Encoding]::ASCII)
    Write-Host 'Etapa 3: ancora publica de confianca configurada para sd.lab.' -ForegroundColor Green

    Copy-Item .\configs\resolvedor\named.conf.dnssec .\configs\resolvedor\named.conf -Force
    docker compose restart resolvedor | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao reiniciar resolvedor.' }
    Start-Sleep -Seconds 3

    Write-Host "`nVerificacao: DNSKEY autoritativa" -ForegroundColor Cyan
    docker exec cliente dig "@172.31.0.11" sd.lab DNSKEY +short
    Write-Host "`nVerificacao: resposta validadora (procure 'ad' nas flags; NOERROR esperado)" -ForegroundColor Cyan
    docker exec cliente dig "@172.31.0.53" app.sd.lab A +dnssec
    Write-Host "`nCaso haja SERVFAIL, veja: docker compose logs --tail=100 ns1 resolvedor" -ForegroundColor Yellow
} finally {
    Pop-Location
}
