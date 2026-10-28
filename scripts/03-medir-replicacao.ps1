# Cinco repeticoes do E3 (NOTIFY ligado). Mede desde o comando de reload.

# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'E3'
    return
}
$ErrorActionPreference = 'Stop'
$registros = @()
# Define o proximo IP a partir do estado atual; cada rodada precisa mudar o valor
$zona = Join-Path $PSScriptRoot '..\zones\db.sd.lab'
$estado = [System.IO.File]::ReadAllText((Resolve-Path $zona))
$ipAtual = [regex]::Match($estado, '(?m)^app\s+IN\s+A\s+((?:\d{1,3}\.){3}\d{1,3})').Groups[1].Value
if (-not $ipAtual) { throw 'Nao foi possivel localizar o IP atual de app.sd.lab.' }
for ($i = 1; $i -le 5; $i++) {
    $ip = if ($ipAtual -eq '10.0.0.2') { '10.0.0.3' } else { '10.0.0.2' }
    $ipAtual = $ip
    & "$PSScriptRoot/02-alterar-ip.ps1" -NovoIP $ip -SemReload
    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    docker exec ns1 rndc -k /etc/bind/rndc.key reload sd.lab | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Nao foi possivel recarregar a zona do NS1." }
    $fim2 = $null
    $fim3 = $null
    while ($relogio.Elapsed.TotalSeconds -lt 45) {
        if ($null -eq $fim2) {
            $r2 = (& docker exec cliente dig "@172.31.0.12" app.sd.lab A +short | Out-String).Trim()
            if ($r2 -eq $ip) { $fim2 = [math]::Round($relogio.Elapsed.TotalMilliseconds, 0) }
        }
        if ($null -eq $fim3) {
            $r3 = (& docker exec cliente dig "@172.31.0.13" app.sd.lab A +short | Out-String).Trim()
            if ($r3 -eq $ip) { $fim3 = [math]::Round($relogio.Elapsed.TotalMilliseconds, 0) }
        }
        if ($null -ne $fim2 -and $null -ne $fim3) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $fim2 -or $null -eq $fim3) {
        Write-Warning "Repeticao ${i}: limite de 45s excedido (NS2=$fim2; NS3=$fim3)."
    }
    $registros += [PSCustomObject]@{ Repeticao=$i; IP=$ip; NS2_ms=$fim2; NS3_ms=$fim3 }
    Write-Host "Repeticao $i/5: NS2=$fim2 ms, NS3=$fim3 ms" -ForegroundColor Cyan
}
$registros | Format-Table -AutoSize
$saida = Join-Path $PSScriptRoot '..\evidencias\e3-notify.csv'
$registros | Export-Csv -Path $saida -NoTypeInformation -Encoding UTF8
Write-Host "CSV salvo em $saida" -ForegroundColor Green
foreach ($col in @('NS2_ms','NS3_ms')) {
    $medidas = @($registros | ForEach-Object { $_.$col } | Where-Object { $null -ne $_ })
    if ($medidas.Count -eq 5) {
        $media = ($medidas | Measure-Object -Average).Average
        $soma = 0.0
        foreach ($v in $medidas) { $soma += [math]::Pow($v - $media, 2) }
        $desvio = [math]::Sqrt($soma / ($medidas.Count - 1))
        Write-Host "$col - media: $([math]::Round($media,1)) ms; desvio padrao amostral: $([math]::Round($desvio,1)) ms"
    } else { Write-Warning "${col}: menos de 5 valores validos, nao calcular estatisticas." }
}
Write-Host 'Importante: a latencia de docker exec/PowerShell faz parte da medicao deste script.'
