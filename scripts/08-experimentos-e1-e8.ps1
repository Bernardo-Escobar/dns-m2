# Experimentos E1-E8 - PowerShell 5.1+ - executar da raiz ou qualquer pasta.
# E3/E4/E6/E7/E8 modificam o laboratorio: backups e restauracao em finally.
param(
 [Parameter(Mandatory=$true)][ValidateSet('E1','E2','E3','E4','E5','E6','E7','E8')][string]$Experimento,
 [int]$Repeticoes=5,
 [int]$TimeoutSegundos=380,
 [switch]$ConfirmarAlteracoes
)
# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento $Experimento
    return
}

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($Repeticoes -lt 5) { throw 'Repeticoes deve ser pelo menos 5.' }
$raiz=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $raiz
$marca=Get-Date -Format 'yyyyMMdd-HHmmss'
$dir=Join-Path $raiz "evidencias\$Experimento\$marca"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$zona=Join-Path $raiz 'zones\db.sd.lab'
$conf=Join-Path $raiz 'configs\ns1\named.conf'
$originalZona=[IO.File]::ReadAllText($zona)
$originalConf=[IO.File]::ReadAllText($conf)
$estadoE3=Join-Path $dir 'diagnostico-e3.txt'
$mudouZona=$false; $mudouConf=$false; $isolado=$false
$parados=New-Object 'System.Collections.Generic.List[string]'
$rede='m2_dns_interna'
function Salvar([string]$nome,[object]$valor) { @($valor) | Out-File -FilePath (Join-Path $dir $nome) -Encoding utf8 -Width 300 }
function D([string[]]$argumentos) {
 # Docker Compose e BIND escrevem mensagens informativas em stderr.
 # No Windows PowerShell 5.1, 2>&1 com Stop pode gerar excecao indevida.
 # Avaliar o codigo de saida do processo, nao a existencia de stderr.
 $out = @(& {
   $ErrorActionPreference = 'Continue'
   & docker @argumentos 2>&1
 })
 $codigo = $LASTEXITCODE
 if ($codigo -ne 0) { throw "docker $($argumentos -join ' ') falhou (exit $codigo): $($out -join ' ')" }
 return $out
}
# Nao confundir o container iniciado com o BIND pronto para consultas e RNDC.
function AguardarPrimario([int]$limite=90) {
 $sw=[Diagnostics.Stopwatch]::StartNew()
 $ultima=''
 while($sw.Elapsed.TotalSeconds -lt $limite) {
  try {
   $status=(D @('inspect','--format','{{.State.Running}}','ns1') -join '').Trim()
   if($status -ne 'true'){ $ultima="container ns1: $status"; Start-Sleep -Milliseconds 500; continue }
   D @('exec','ns1','rndc','status') | Out-Null
   $soa=Soa '172.31.0.11'
   if($soa){ return }
   $ultima='rndc respondeu, mas SOA ainda nao disponivel'
  } catch { $ultima=$_.Exception.Message }
  Start-Sleep -Milliseconds 500
 }
 throw "BIND do ns1 nao ficou pronto em $limite s. Ultima verificacao: $ultima"
}
function AplicarConfiguracaoPrimario {
 # rndc reconfig recarrega named.conf sem reiniciar o processo BIND.
 # Evita a janela de indisponibilidade causada por docker compose restart ns1.
 D @('exec','ns1','named-checkconf') | Out-Null
 AguardarPrimario 90
 D @('exec','ns1','rndc','reconfig') | Out-Null
 AguardarPrimario 90
}
function Dig([string]$ip,[string]$nome='app.sd.lab',[string]$tipo='A',[string[]]$opcoes=@()) {
 return ((D (@('exec','cliente','dig',"@$ip",$nome,$tipo,'+time=2','+tries=1')+$opcoes)) -join "`n")
}
function Soa([string]$ip) {
 $r=Dig $ip 'sd.lab' 'SOA' @('+short')
 $m=[regex]::Match($r,'\b(\d{10})\b')
 if (-not $m.Success) { return '' }
 return $m.Value
}
function IP([string]$ip) {
 $r=Dig $ip 'app.sd.lab' 'A' @('+short')
 $m=[regex]::Match($r,'(?m)^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*$')
 if (-not $m.Success) { return '' }
 return $m.Groups[1].Value
}
function Publicar([string]$novo) {
 $atual=[IO.File]::ReadAllText($zona)
 $m=[regex]::Match($atual,'(?m)^(app\s+IN\s+A\s+)(\d{1,3}(?:\.\d{1,3}){3})')
 $s=[regex]::Match($atual,'(?m)^(\s*)(\d{10})(\s*;\s*serial\b[^\r\n]*)')
 if (-not $m.Success -or -not $s.Success) { throw 'Zona fora do formato esperado: app ou serial.' }
 $novoSerial=([long]$s.Groups[2].Value+1).ToString()
 $atual=$atual.Substring(0,$m.Groups[2].Index)+$novo+$atual.Substring($m.Groups[2].Index+$m.Groups[2].Length)
 $s=[regex]::Match($atual,'(?m)^(\s*)(\d{10})(\s*;\s*serial\b[^\r\n]*)')
 $atual=$atual.Substring(0,$s.Groups[2].Index)+$novoSerial+$atual.Substring($s.Groups[2].Index+$s.Groups[2].Length)
 [IO.File]::WriteAllText($zona,$atual,[Text.Encoding]::ASCII)
 $script:mudouZona=$true
 D @('exec','ns1','rndc','reload','sd.lab') | Out-Null
 return $novoSerial
}
function Esperar([string]$ip,[string]$esperado,[int]$limite=90) {
 $sw=[Diagnostics.Stopwatch]::StartNew()
 while ($sw.Elapsed.TotalSeconds -lt $limite) {
  try { if ((IP $ip) -eq $esperado) { return [math]::Round($sw.Elapsed.TotalSeconds,3) } } catch {}
  Start-Sleep -Milliseconds 100
 }
 throw "Timeout aguardando $esperado em $ip ($limite s)"
}
function Estatisticas([object[]]$valores) {
 $a=@($valores | ForEach-Object {[double]$_})
 if ($a.Count -eq 0) { return 'sem dados' }
 $media=($a|Measure-Object -Average).Average
 $soma=0.0; foreach($x in $a){$soma += [math]::Pow($x-$media,2)}
 $dp=if($a.Count -gt 1){[math]::Sqrt($soma/($a.Count-1))}else{0}
 return ('n={0}; media={1:N3}s; desvio padrao amostral={2:N3}s' -f $a.Count,$media,$dp)
}
function Logs { foreach($s in @('ns1','ns2','ns3','resolvedor')) { try { Salvar "logs-$s.txt" (D @('logs','--since','15m',$s)) } catch {Salvar "erro-logs-$s.txt" $_} } }
function Medir([string]$modo,[int]$vezes) {
 $linhas=@(); $t2=@(); $t3=@()
 for($i=1;$i -le $vezes;$i++) {
  AguardarPrimario 90
  $atual=IP '172.31.0.11'; if(-not $atual){throw 'Primario nao respondeu apos a verificacao de disponibilidade.'}
  $novo=if($atual -eq '10.0.0.2'){'10.0.0.3'}else{'10.0.0.2'}
  $serial=Publicar $novo
  $sw=[Diagnostics.Stopwatch]::StartNew(); $v2=$null;$v3=$null
  while($sw.Elapsed.TotalSeconds -lt 100) {
   if($null -eq $v2){try{if((IP '172.31.0.12') -eq $novo){$v2=[math]::Round($sw.Elapsed.TotalSeconds,3)}}catch{}}
   if($null -eq $v3){try{if((IP '172.31.0.13') -eq $novo){$v3=[math]::Round($sw.Elapsed.TotalSeconds,3)}}catch{}}
   if($null -ne $v2 -and $null -ne $v3){break}
   Start-Sleep -Milliseconds 100
  }
  if($null -eq $v2 -or $null -eq $v3){throw "Replicacao incompleta em $modo, rodada $i"}
  $t2+= $v2;$t3+= $v3
  $linhas += [pscustomobject]@{Modo=$modo;Rodada=$i;Serial=$serial;IP=$novo;Ns2_s=$v2;Ns3_s=$v3}
  $linhas | Export-Csv (Join-Path $dir "medicoes-$modo.csv") -NoTypeInformation -Encoding UTF8
  Write-Host "$modo rodada $i ns2=$v2 s ns3=$v3 s"
 }
 $linhas | Export-Csv (Join-Path $dir "medicoes-$modo.csv") -NoTypeInformation -Encoding UTF8
 Salvar "estatisticas-$modo.txt" @("ns2: $(Estatisticas $t2)","ns3: $(Estatisticas $t3)")
}
try {
 Salvar 'previsao-preencher.txt' "Experimento $Experimento. Preencha a previsao ANTES de executar e compare com os resultados."
 Salvar 'estado-inicial.txt' @((D @('compose','ps')),"ns1 SOA: $(Soa '172.31.0.11')","ns2 SOA: $(Soa '172.31.0.12')","ns3 SOA: $(Soa '172.31.0.13')")
 switch ($Experimento) {
 'E1' {
  Salvar 'compose.txt' (D @('compose','ps'))
  Salvar 'ns2-transferencias.txt' (D @('compose','logs','ns2'))
  Salvar 'ns3-transferencias.txt' (D @('compose','logs','ns3'))
  Salvar 'seriais.txt' @("ns1 $(Soa '172.31.0.11')","ns2 $(Soa '172.31.0.12')","ns3 $(Soa '172.31.0.13')")
  Salvar 'redes.txt' (D @('network','inspect','m2_dns_interna','m2_dns_clientes'))
 }
 'E2' {
  foreach($s in @('ns1','ns2','ns3','resolvedor')){D @('exec',$s,'rndc','querylog','on') | Out-Null}
  D @('exec','resolvedor','rndc','flush') | Out-Null
  Salvar 'consulta-resolvedor.txt' (Dig '172.31.0.53' 'app.sd.lab' 'A')
  Salvar 'consulta-autoritativa.txt' (Dig '172.31.0.11' 'app.sd.lab' 'A' @('+norecurse'))
  Salvar 'trilha-escrita.txt' @('Edicao exclusiva no primario; NOTIFY -> IXFR/AXFR -> secundario.','Registre o evento de publicacao em E3 e confronte com os logs abaixo.')
  Start-Sleep -Seconds 2; Logs
 }
 'E3' {
  if(-not $ConfirmarAlteracoes){throw 'E3 modifica zona e configuracao. Execute com -ConfirmarAlteracoes.'}
  if($originalConf -notmatch 'notify\s+yes\s*;'){throw 'E3 requer notify yes na configuracao original.'}
  AguardarPrimario 90
  $serialBase=Soa '172.31.0.11'
  $serialNs2=Soa '172.31.0.12'
  $serialNs3=Soa '172.31.0.13'
  Salvar 'diagnostico-inicial-e3.txt' @("SOA ns1: $serialBase","SOA ns2: $serialNs2","SOA ns3: $serialNs3","Origem NOTIFY configurada: 172.30.0.11")
  if($serialBase -ne $serialNs2 -or $serialBase -ne $serialNs3){throw 'E3 exige seriais sincronizados antes de iniciar. Aguarde ou verifique a transferencia de zona.'}
  Medir 'com-notify' $Repeticoes
  $desativado=([regex]::new('notify\s+yes\s*;')).Replace($originalConf,'notify no;',1)
  [IO.File]::WriteAllText($conf,$desativado,[Text.Encoding]::ASCII);$mudouConf=$true
  AplicarConfiguracaoPrimario
  Salvar 'modo-sem-notify.txt' @('notify no aplicado por rndc reconfig, sem reiniciar ns1.',"SOA primario: $(Soa '172.31.0.11')")
  # Aguarda refresh do SOA (30s), sem NOTIFY.
  Medir 'sem-notify' $Repeticoes
 }
 'E4' {
  if(-not $ConfirmarAlteracoes){throw 'E4 modifica zona. Execute com -ConfirmarAlteracoes.'}
  D @('exec','resolvedor','rndc','flush') | Out-Null
  Salvar 'cache-inicial.txt' (Dig '172.31.0.53')
  Start-Sleep -Seconds 3
  Salvar 'cache-ttl-decrescente.txt' (Dig '172.31.0.53')
  $velho=IP '172.31.0.11'; $novo=if($velho -eq '10.0.0.2'){'10.0.0.3'}else{'10.0.0.2'}
  $serial=Publicar $novo
  $t2=Esperar '172.31.0.12' $novo; $t3=Esperar '172.31.0.13' $novo
  $linhas=@(); $sw=[Diagnostics.Stopwatch]::StartNew()
  while($sw.Elapsed.TotalSeconds -lt 75) {
   $resp=Dig '172.31.0.53'; $linhas += [pscustomobject]@{Tempo_s=[math]::Round($sw.Elapsed.TotalSeconds,2);Resposta=([regex]::Match($resp,'(?m)^app\.sd\.lab\.\s+\d+\s+IN\s+A\s+([\d.]+)').Groups[1].Value)}
   if($linhas[-1].Resposta -eq $novo){break};Start-Sleep -Seconds 2
  }
  $linhas|Export-Csv (Join-Path $dir 'cache-positivo.csv') -NoTypeInformation -Encoding UTF8
  Salvar 'janela.txt' @("Serial $serial; replica ns2=$t2 s ns3=$t3 s","Limite teorico aproximado: TTL 60s + atraso replicacao maximo $([math]::Max($t2,$t3))s")
  # Nome unico para cache negativo, sem depender de novo.sd.lab preexistente.
  $nome="ausente-$marca.sd.lab"
  Salvar 'negativo-antes.txt' (Dig '172.31.0.53' $nome)
  $atual=[IO.File]::ReadAllText($zona)
  $s=[regex]::Match($atual,'(?m)(\d{10})(\s*;\s*serial\b)')
  if(-not $s.Success){throw 'Serial nao encontrado.'}
  $atual=$atual.Substring(0,$s.Groups[1].Index)+([long]$s.Groups[1].Value+1)+$atual.Substring($s.Groups[1].Index+$s.Groups[1].Length)
  $atual += "`n" + "ausente-$marca IN A 10.0.0.77`n"
  [IO.File]::WriteAllText($zona,$atual,[Text.Encoding]::ASCII)
  D @('exec','ns1','rndc','reload','sd.lab') | Out-Null
  Salvar 'negativo-logo-apos.txt' (Dig '172.31.0.53' $nome)
  Start-Sleep -Seconds 23
  Salvar 'negativo-apos-ttl.txt' (Dig '172.31.0.53' $nome)
 }
 'E5' {
  if(-not $ConfirmarAlteracoes){throw 'E5 para ns1 e ns2. Execute com -ConfirmarAlteracoes.'}
  D @('stop','ns1') | Out-Null;$parados.Add('ns1')
  Salvar 'somente-ns1-parado.txt' @((Dig '172.31.0.12'),(Dig '172.31.0.13'))
  D @('stop','ns2') | Out-Null;$parados.Add('ns2')
  Salvar 'ns1-ns2-parados.txt' (Dig '172.31.0.13')
  Salvar 'quorum.txt' @('DNS autoritativo nao exige quorum para leitura; escrita de zona primaria indisponivel enquanto ns1 estiver parado.','1 no ativo (ns3) ainda pode servir dados ate SOA expire; N=3, R=1, W centralizado no primario. Nao se aplica quorum R+W>N.')
 }
 'E6' {
  if(-not $ConfirmarAlteracoes){throw 'E6 isola ns3 e espera expire. Execute com -ConfirmarAlteracoes.'}
  D @('network','disconnect',$rede,'ns3') | Out-Null;$isolado=$true
  Salvar 'ns3-ainda-acessivel.txt' (Dig '172.31.0.13')
  $velho=IP '172.31.0.11';$novo=if($velho -eq '10.0.0.2'){'10.0.0.3'}else{'10.0.0.2'}
  Publicar $novo | Out-Null
  $t2=Esperar '172.31.0.12' $novo
  Salvar 'divergencia.txt' @("ns2 apos $t2 s: $(IP '172.31.0.12')","ns3 isolado: $(IP '172.31.0.13')")
  $inicio=Get-Date; $linhas=@()
  while(((Get-Date)-$inicio).TotalSeconds -lt [math]::Min($TimeoutSegundos,380)) {
   $resposta=Dig '172.31.0.13'
   $status=[regex]::Match($resposta,'status:\s*(\w+)').Groups[1].Value
   $linhas += [pscustomobject]@{Segundos=[math]::Round(((Get-Date)-$inicio).TotalSeconds,1);Status=$status}
   if($status -eq 'SERVFAIL'){break}
   Start-Sleep -Seconds 5
  }
  $linhas|Export-Csv (Join-Path $dir 'expiracao.csv') -NoTypeInformation -Encoding UTF8
  Salvar 'consulta-final-ns3.txt' (Dig '172.31.0.13')
 }
 'E7' {
  if(-not $ConfirmarAlteracoes){throw 'E7 faz 5 ciclos de isolamento e reconexao de ns3. Execute com -ConfirmarAlteracoes.'}
  $tempos=@();$linhas=@()
  for($i=1;$i -le $Repeticoes;$i++) {
   D @('network','disconnect',$rede,'ns3') | Out-Null;$isolado=$true
   $velho=IP '172.31.0.11';$novo=if($velho -eq '10.0.0.2'){'10.0.0.3'}else{'10.0.0.2'}
   Publicar $novo | Out-Null
   Esperar '172.31.0.12' $novo | Out-Null
   $sw=[Diagnostics.Stopwatch]::StartNew()
   D @('network','connect','--ip','172.30.0.13',$rede,'ns3') | Out-Null;$isolado=$false
   D @('exec','ns3','rndc','refresh','sd.lab') | Out-Null
   $t=Esperar '172.31.0.13' $novo 100
   $tempos += $t
   $linhas += [pscustomobject]@{Rodada=$i;IP=$novo;Tempo_s=$t;SerialNs1=(Soa '172.31.0.11');SerialNs3=(Soa '172.31.0.13')}
  }
  $linhas|Export-Csv (Join-Path $dir 'recuperacao.csv') -NoTypeInformation -Encoding UTF8
  Salvar 'estatisticas.txt' (Estatisticas $tempos)
 }
 'E8' {
  if(-not $ConfirmarAlteracoes){throw 'E8 publica temporariamente um serial menor. Execute com -ConfirmarAlteracoes.'}
  $serial=Soa '172.31.0.11';if(-not $serial){throw 'SOA do primario indisponivel.'}
  $texto=[IO.File]::ReadAllText($zona)
  $s=[regex]::Match($texto,'(?m)(\d{10})(\s*;\s*serial\b)')
  if(-not $s.Success){throw 'Serial no arquivo nao encontrado.'}
  if([long]$s.Groups[1].Value -lt 2){throw 'Serial pequeno demais.'}
  $menor=([long]$s.Groups[1].Value-1).ToString()
  $texto=$texto.Substring(0,$s.Groups[1].Index)+$menor+$texto.Substring($s.Groups[1].Index+$s.Groups[1].Length)
  [IO.File]::WriteAllText($zona,$texto,[Text.Encoding]::ASCII);$mudouZona=$true
  D @('exec','ns1','rndc','reload','sd.lab') | Out-Null
  D @('exec','ns2','rndc','refresh','sd.lab') | Out-Null
  D @('exec','ns3','rndc','refresh','sd.lab') | Out-Null
  Start-Sleep -Seconds 5
  Salvar 'seriais-apos-menor.txt' @("primario $(Soa '172.31.0.11')","ns2 $(Soa '172.31.0.12')","ns3 $(Soa '172.31.0.13')")
  Salvar 'interpretacao.txt' @('Primario e coordenador estatico das escritas; serial SOA ordena versoes.','Serial menor nao deve substituir zona mais nova em secundario; discutir ausencia de consenso entre multiplos primarios.')
 }
 }
 Logs
 Write-Host "Evidencias: $dir" -ForegroundColor Green
} finally {
 try {
  foreach($s in $parados){D @('start',$s) | Out-Null}
  if($isolado){D @('network','connect','--ip','172.30.0.13',$rede,'ns3') | Out-Null}
  if($mudouConf){
   [IO.File]::WriteAllText($conf,$originalConf,[Text.Encoding]::ASCII)
   AplicarConfiguracaoPrimario
  }
  if($mudouZona){
   # Nunca voltar o serial para tras: restaurar dados anteriores com serial MAIS ALTO.
   $agora=[IO.File]::ReadAllText($zona)
   $a=[regex]::Match($agora,'(?m)(\d{10})(\s*;\s*serial\b)')
   $b=[regex]::Match($originalZona,'(?m)(\d{10})(\s*;\s*serial\b)')
   if(-not $a.Success -or -not $b.Success){throw 'Restauracao exige ajuste manual do serial.'}
   $serialNovo=([math]::Max([long]$a.Groups[1].Value,[long]$b.Groups[1].Value)+1).ToString()
   $restaurado=$originalZona.Substring(0,$b.Groups[1].Index)+$serialNovo+$originalZona.Substring($b.Groups[1].Index+$b.Groups[1].Length)
   [IO.File]::WriteAllText($zona,$restaurado,[Text.Encoding]::ASCII)
   AguardarPrimario 90
   D @('exec','ns1','rndc','reload','sd.lab') | Out-Null
   foreach($s in @('ns2','ns3')){try{D @('exec',$s,'rndc','refresh','sd.lab')|Out-Null}catch{}}
  }
  Salvar 'restauracao.txt' @('Configuracoes restauradas; serial da zona incrementado para preservar monotonicidade.',"ns1: $(Soa '172.31.0.11')")
 } catch { Salvar 'ERRO-RESTAURACAO.txt' $_;Write-Warning "Restauracao incompleta: $_" }
 Pop-Location
}
