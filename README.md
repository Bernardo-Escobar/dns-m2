> **E9 automatizado:** apos E1-E8, execute `.\ativar-dnssec.ps1` na raiz do projeto.

> **Versao portatil:** leia primeiro [README_PORTABILIDADE.md](README_PORTABILIDADE.md). Este README original contem procedimentos legados baseados em scripts.

# UNIVALI - Sistemas Distribuidos M2 - DNS com enfase C (DNSSEC)

Laboratorio inicial para a equipe com BIND 9 em contêineres. Baseado nas secoes 4, 5, 10 e 11 do roteiro do professor. O ambiente e os scripts sao **propostas de implementacao**: precisam ser executados, validados e documentados pela equipe. **Nao sao evidencias de que os experimentos ja foram feitos.**

## 1. Estrutura da solucao

| No | Papel | Rede interna | Rede cliente |
|---|---|---|---|
| ns1 | Primario, unico que altera a zona | 172.30.0.11 | 172.31.0.11 |
| ns2 | Secundario autoritativo | 172.30.0.12 | 172.31.0.12 |
| ns3 | Secundario autoritativo | 172.30.0.13 | 172.31.0.13 |
| resolvedor | Recursivo com cache; depois validador DNSSEC | - | 172.31.0.53 |
| cliente | dig para sondagem | - | 172.31.0.100 |
| atacante | Copia de zona assinada adulterada, SOMENTE perfil seguranca do E9 | - | 172.31.0.66 |

Domínio privado: `sd.lab`. Registro inicial: `app.sd.lab -> 10.0.0.1`. Sem publicacao de portas no computador hospedeiro. As duas redes do Docker usam subredes estaticas, como no PDF. Se ja houver redes VPN/Docker conflitantes com 172.30.0.0/24 e 172.31.0.0/24, as faixas deverao ser ajustadas de forma consistente em todos os arquivos.

## 2. Antes de comecar - Windows 11

1. Instale Docker Desktop com backend WSL 2: https://www.docker.com/products/docker-desktop/
2. Abra o Docker Desktop e espere o motor iniciar.
3. Instale VS Code e Git, se ainda nao tiver.
4. Extraia este projeto numa pasta simples (por exemplo `C:\dns-m2`).
5. Abra **PowerShell** na pasta onde aparece `compose.yaml`.

```powershell
docker --version
docker compose version
docker info
```

Se o Windows bloquear os scripts PowerShell com mensagem sobre politica de execucao, rode **apenas nessa janela**:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 3. PRIMEIRA EXECUCAO - atividade de hoje

Dentro da pasta do projeto:

```powershell
docker compose up -d --build
docker compose ps
```

Confira os logs e a configuracao. A transferencia inicial pode levar alguns segundos:

```powershell
docker compose logs --tail=60 ns1 ns2 ns3
docker exec ns1 named-checkconf /etc/bind/named.conf
docker exec ns1 named-checkzone sd.lab /var/lib/bind/db.sd.lab
```

Verifique se todos os servidores conhecem o mesmo registro DNS:

```powershell
docker exec cliente dig @172.31.0.11 app.sd.lab +short
docker exec cliente dig @172.31.0.12 app.sd.lab +short
docker exec cliente dig @172.31.0.13 app.sd.lab +short
docker exec cliente dig @172.31.0.53 app.sd.lab +short
```

**Esperado nos quatro comandos:** `10.0.0.1`.

Valide a versao da zona (SOA), usando o script pronto:

```powershell
.\scripts\01-diagnostico.ps1
```

Os tres autoritativos devem mostrar o mesmo serial (`2026102301` inicialmente). Tire capturas e salve logs em `evidencias/`.

Se algo nao subir, use `docker compose ps -a` e `docker compose logs --tail=100 NOME_DO_SERVICO`. Nao avance antes de resolver o erro.

## 4. Comprovar uma alteracao (E2/E3)

Altere o registro `app` de `10.0.0.1` para `10.0.0.2`, atualize o serial e recarregue o primario com **um unico script**:

```powershell
.\scripts\02-alterar-ip.ps1 -NovoIP 10.0.0.2
.\scripts\01-diagnostico.ps1
```

**Esperado:** NS1, NS2 e NS3 passam a responder `10.0.0.2` e apresentam o mesmo novo serial. Caso a resposta do resolvedor continue antiga, isso pode ser o **cache pelo TTL** (E4), e nao erro na replicacao.

Para medir pelo menos 5 repeticoes de propagacao quando NOTIFY esta ativo:

```powershell
.\scripts\03-medir-replicacao.ps1
```

A medicao gera `evidencias/e3-notify.csv`, com tempos em milissegundos, media e desvio padrao **amostral**. A precisao e limitada pelo tempo de `docker exec` e da sondagem; informe essa limitacao no relatorio. Faca outra serie desativando `notify` no NS1 e comparando os valores; esse segundo cenario ainda precisa ser configurado e executado manualmente pela equipe.

## 5. Sequencia obrigatoria E1 a E8

Para CADA experimento, documente: objetivo, previsao ANTES do teste, procedimento, comando, evidencias coletadas, resultados reais e analise. Nao confunda resultado esperado com medido.

### E1 - Subida/topologia

`docker compose ps`; consultar SOA nos tres autoritativos; mostrar topologia do README e diagrama proprio com redes e IPs.

### E2 - Caminho da operacao

```powershell
docker exec cliente dig @172.31.0.53 app.sd.lab A
docker exec cliente dig @172.31.0.11 app.sd.lab A +norecurse
docker exec ns1 rndc -k /etc/bind/rndc.key querylog on
docker exec resolvedor rndc -k /etc/bind/rndc.key querylog on
docker compose logs --tail=60 ns1 resolvedor
```

Comparar flags `aa` (resposta autoritativa) e `ra` (recursao disponivel) e o encaminhamento aos autoritativos.

### E3 - Replicacao

Executar `.\scripts\03-medir-replicacao.ps1` e salvar CSV. Comparar contra o teste de `notify no;` no primario, aplicando `docker compose restart ns1` apos a mudanca na configuracao. Repor `notify yes;` depois. Quando a edicao for da configuracao `named.conf`, restart e mais seguro que `rndc reload sd.lab`.

### E4 - TTL/cache negativo

```powershell
docker exec cliente dig @172.31.0.53 app.sd.lab A
docker exec cliente dig @172.31.0.53 app.sd.lab A
```

Observe TTL caindo. Depois altere o IP no NS1 e compare a resposta direta do primario com a resposta do resolvedor. Para cache negativo, consulte `novo.sd.lab` quando ele ainda nao existe, depois crie esse registro na zona, aumente o serial e recarregue. Observe a resposta ate expirar o TTL negativo. Para esse experimento, evite reiniciar o resolvedor, para nao apagar o cache.

### E5 - Falhas sem quorum

```powershell
docker stop ns1
docker exec cliente dig @172.31.0.12 app.sd.lab +short
docker stop ns2
docker exec cliente dig @172.31.0.13 app.sd.lab +short
docker start ns1
docker start ns2
```

Registre tabela com nos ativos, leituras possiveis e possibilidade de editar/publicar novos dados. DNS classico **nao usa quorum de maioria** para atender leituras. Parar o primario impede as atualizacoes administrativas, mas secundarios podem continuar respondendo ate o `expire` do SOA.

### E6 - Particao de rede

```powershell
docker network disconnect m2_dns_interna ns3
```

NS3 continua na rede dos clientes. Altere um registro no NS1, verifique que NS2 atualiza e NS3 nao. Aguarde `expire` e registre o retorno do NS3. Depois reconecte:

```powershell
docker network connect --ip 172.30.0.13 m2_dns_interna ns3
```

Evite `docker compose down` durante o isolamento, pois remove as redes. O tempo de `expire` se refere a ausencia de renovacao com o primario, nao necessariamente ao momento exato do comando de desconexao.

### E7 - Recuperacao

Apos reconectar NS3, observe a nova transferencia e cronometre ate o serial bater com NS1:

```powershell
docker compose logs --tail=80 ns3
docker exec cliente dig @172.31.0.13 sd.lab SOA +short
```

Repita a medicao pelo menos cinco vezes. Antes de cada rodada, crie condicoes equivalentes e registre a variacao.

### E8 - Coordenacao e ordenacao

Mostrar que a versao da zona e o `serial` do SOA, e que o NS1 e o coordenador estatico de escritas. Testar uma atualizacao cujo serial seja menor que o atual e observar o comportamento dos secundarios. **Guarde um backup** do arquivo da zona antes desse teste para restaura-lo depois, com serial correto.

## 6. Seguranca (E9) - depois de E1-E8 funcionando

A etapa E9 requer assinatura da zona, validacao no resolvedor, falsificacao e medicao do custo em bytes.

Primeiro, ative DNSSEC:

```powershell
.\scripts\04-ativar-dnssec.ps1
```

O script altera a configuracao do NS1 para `dnssec-policy default; inline-signing yes;`, espera uma DNSKEY, extrai a **chave publica** (sem exportar a chave privada) para construir uma `trust-anchors` local e habilita `dnssec-validation yes;` no resolvedor. O script nao substitui a observacao e comprovacao na tela.

Confira resposta assinada e validada:

```powershell
docker exec cliente dig @172.31.0.11 app.sd.lab A +dnssec
docker exec cliente dig @172.31.0.53 app.sd.lab A +dnssec
```

**Esperado:** registros `RRSIG` no autoritativo quando solicitados e flag `ad` na resposta **validada pelo resolvedor**, status `NOERROR`. Lembre-se: `dig +dnssec` sozinho apenas solicita registros DNSSEC; a validacao ocorre no resolvedor que configuramos.

Teste UNICO e rigoroso: adulteracao do registro A mantendo a RRSIG original:

```powershell
.\scripts\05-testar-falsificacao.ps1
```

O script solicita uma AXFR da zona assinada, troca **apenas o IP** do registro `app` para `10.66.66.66` e preserva a assinatura `RRSIG` original (que deixa de corresponder ao conteudo). O servidor `atacante` oferece essa copia adulterada; o resolvedor sera temporariamente configurado para perguntar somente a ele. **Resultado esperado:** `SERVFAIL`. Confirme nos logs que a falha foi criptografica, e nao indisponibilidade ou erro de configuracao.

O script restaura automaticamente a configuracao e a zona ao finalizar. Em caso de interrupcao abrupta, restaure manualmente com:

```powershell
.\scripts\05-testar-falsificacao.ps1 -Restaurar
```

Meça o custo de tamanho (campo `MSG SIZE rcvd`):

```powershell
.\scripts\06-comparar-tamanho.ps1
```

Esse teste usa **dados alterados com assinatura antiga preservada**, portanto o conjunto de registros fica criptograficamente invalido. Isto demonstra adulteracao de um dado assinado. Para comparar, uma mudanca normal no primario com `dnssec-policy` e assinada de novo automaticamente e pode continuar valida. Se o professor preferir expirar a RRSIG em vez de alterar o registro assinado, sera necessario preparar um cenario adicional de expiracao.

## 7. Relatorio e seminario

- Fundamentacao: DNS hierarquico, autoritativo vs recursivo, SOA, TTL, NOTIFY, AXFR/IXFR, caches, serial RFC 1982, DNSSEC, assinaturas e trust anchors.
- Responder **Q1 a Q14** da secao 4 e **S1 a S4** da secao 5 do roteiro, apontando as evidencias experimentais.
- Relatorio de **15 a 25 paginas** como orientacao, em formato livre com capa/sumario e referencias ABNT, incluindo experimentos, ambiente, quadro-sintese e papel de cada integrante.
- Informar o uso de IA generativa e a forma de verificacao, se utilizada.
- Apresentacao: 10 minutos + 5 minutos de arguição; todos apresentam. A secao 11 pede demonstracao ao vivo de ao menos 8 minutos e recomenda slides com divisao de tempos que soma menos; confirmem esse detalhe com o professor.
- Data no roteiro: **28/11/2026** para relatorio e seminario.

## 8. Observacoes sobre a reprodutibilidade

- Esse kit foi preparado a partir do roteiro, mas **nao foi possivel iniciar contêineres neste ambiente de preparacao**. Valide na sua maquina; versoes, comportamento e logs reais precisam ser preenchidos no trabalho.
- A configuracao de laboratorio nao deve ser publicada como servidor DNS aberto na internet. Ela usa regras simplificadas de acesso, rede privada e uma ancora de confianca estatica para a zona ficticia.
- As chaves privadas DNSSEC ficam no volume Docker `ns1_keys`. Se apagar o volume com `docker compose down -v`, as chaves serao regeneradas e a ancora de confianca antiga deixara de servir; execute novamente `04-ativar-dnssec.ps1` para obter a chave nova.
- `docker compose down` para e remove contêineres e redes, mas nao os volumes nomeados (sem `-v`).
- Os resultados da equipe devem registrar tambem os erros e divergencias observados, e nao apenas os casos que funcionaram.

## 9. Fontes

- Roteiro Trabalho M2 Completo, paginas 4-16 e 40-42.
- BIND 9 Administrator Reference Manual: https://bind9.readthedocs.io/en/stable/
- BIND DNSSEC Guide: https://bind9.readthedocs.io/en/stable/dnssec-guide.html
- Mockapetris & Dunlap, *Development of the Domain Name System*, SIGCOMM 1988.
- RFC 1034, 1035, 1982, 1995, 1996 e 2308.
