# Laboratório DNS com BIND 9 e DNSSEC

Projeto da disciplina de Sistemas Distribuídos da UNIVALI, tema DNS e ênfase C — DNSSEC. O laboratório usa Docker Compose para estudar replicação de zonas, cache, consistência eventual, falhas, partições, recuperação e validação criptográfica.

**Integrantes:** Bernardo Victoria Escobar Silva e Gabriel Santos Bortoloci.  
**Professor:** Ramices dos Santos Silva.

Este README reúne a instalação, a execução dos experimentos E1–E9 e os procedimentos de recuperação. Substitui `README_PORTABILIDADE.md` e `GUIA_AUTOMACAO_E1_E9.md`.

## 1. Ambiente e topologia

| Nó | Função | Rede interna | Rede de clientes |
|---|---|---|---|
| ns1 | Primário autoritativo e ponto de publicação | 172.30.0.11 | 172.31.0.11 |
| ns2 | Secundário autoritativo | 172.30.0.12 | 172.31.0.12 |
| ns3 | Secundário autoritativo | 172.30.0.13 | 172.31.0.13 |
| resolvedor | Resolução com cache e, no E9, validação DNSSEC | — | 172.31.0.53 |
| cliente | Consultas com dig | — | 172.31.0.100 |
| atacante | Cópia adulterada da zona assinada, usada no E9 | — | 172.31.0.66 |

- Rede de sincronização: `m2_dns_interna`, sub-rede `172.30.0.0/24`.
- Rede de consultas: `m2_dns_clientes`, sub-rede `172.31.0.0/24`.
- DNS: porta 53, UDP/TCP. Não há portas publicadas no hospedeiro.
- Imagem construída com Alpine Linux 3.20, BIND 9 e bind-tools.
- Limite de memória: `128m` por servidor BIND e `32m` para o cliente.
- O atacante pertence ao perfil opcional `seguranca`.

Na cópia inicial distribuída, a zona é `sd.lab`, com `app.sd.lab = 10.0.0.1`, serial `2026102301` e DNSSEC desabilitado. O SOA usa refresh de 30 s, retry de 10 s, expire de 300 s e MINIMUM de 20 s; o TTL padrão é 60 s. Após executar os testes, o endereço e o serial podem mudar.

O primário publica alterações; os secundários recebem cópias por transferência de zona. O resolvedor mantém cache, mas não é uma réplica autoritativa.

## 2. Requisitos

- Docker Desktop com contêineres Linux e backend WSL 2 no Windows.
- PowerShell 5.1 ou superior para os scripts.
- Git, para clonar e versionar o projeto.

O Docker também pode executar os contêineres em Linux ou macOS, mas os comandos e scripts deste guia foram organizados para PowerShell no Windows.

Extraia ou clone o projeto e abra o PowerShell na pasta que contém `compose.yaml`. Confira:

```powershell
docker --version
docker compose version
docker info
```

Se a política local bloquear os scripts, após conferir seu conteúdo, libere a execução somente na sessão atual:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Execute uma única cópia do laboratório por vez: os nomes de contêineres e redes são fixos. Verifique se as sub-redes não conflitam com VPNs ou outras redes Docker.

## 3. Inicialização e conferência

```powershell
docker compose config --quiet
docker compose up -d --build
.\scripts\00-checar-docker.ps1
.\scripts\01-diagnostico.ps1
```

Aguarde a carga inicial das zonas. Confirme os registros e os seriais:

```powershell
docker compose ps
docker exec cliente dig "@172.31.0.11" app.sd.lab A +short
docker exec cliente dig "@172.31.0.12" app.sd.lab A +short
docker exec cliente dig "@172.31.0.13" app.sd.lab A +short
docker exec cliente dig "@172.31.0.53" app.sd.lab A +short
docker exec cliente dig "@172.31.0.11" sd.lab SOA +short
docker exec cliente dig "@172.31.0.12" sd.lab SOA +short
docker exec cliente dig "@172.31.0.13" sd.lab SOA +short
```

Na primeira execução, espera-se `10.0.0.1` nas quatro consultas A e seriais iguais nos três autoritativos. O resolvedor pode apresentar um valor anterior após alterações, até o cache expirar.

Para registrar versões e uso de memória na máquina de execução:

```powershell
docker exec ns1 named -v
docker stats --no-stream
```

No PowerShell, mantenha os argumentos `@IP` entre aspas. As consultas deste guia são feitas dentro do contêiner `cliente`.

## 4. Execução dos experimentos E1 a E8

Execute **um experimento por vez**, com DNSSEC desabilitado. Antes de cada teste, registre a previsão da equipe. Ao terminar, confira os resultados e a restauração antes de avançar.

| Experimento | Comando |
|---|---|
| E1 — Subida e topologia | `.\scripts\08-experimentos-e1-e8.ps1 -Experimento E1` |
| E2 — Caminho da operação | `.\scripts\08-experimentos-e1-e8.ps1 -Experimento E2` |
| E3 — Replicação com e sem NOTIFY | `.\scripts\08-experimentos-e1-e8.ps1 -Experimento E3 -ConfirmarAlteracoes -Repeticoes 5` |
| E4 — Cache positivo e negativo | `.\scripts\08-experimentos-e1-e8.ps1 -Experimento E4 -ConfirmarAlteracoes` |
| E5 — Falha do primário e da maioria | `.\scripts\08-experimentos-e1-e8.ps1 -Experimento E5 -ConfirmarAlteracoes` |
| E6 — Partição da rede interna | `.\scripts\08-experimentos-e1-e8.ps1 -Experimento E6 -ConfirmarAlteracoes` |
| E7 — Recuperação | `.\scripts\08-experimentos-e1-e8.ps1 -Experimento E7 -ConfirmarAlteracoes -Repeticoes 5` |
| E8 — Coordenação e serial SOA | `.\scripts\08-experimentos-e1-e8.ps1 -Experimento E8 -ConfirmarAlteracoes` |

Os testes que alteram o ambiente exigem `-ConfirmarAlteracoes`. Os procedimentos manuais podem complementar a automação para atender às evidências do roteiro.

### O que verificar em cada teste

- **E1:** serviços ativos, transferências iniciais e igualdade dos seriais. Produzir o diagrama próprio com nós, redes e endereços.
- **E2:** comparar `aa`, `rd` e `ra`, identificar o encaminhamento nos logs e apresentar um diagrama de sequência. O modo automatizado consulta e coleta logs, mas não publica uma alteração; documente a escrita manualmente ou em uma execução identificada do E3.
- **E3:** conservar cinco medições por secundário em cada condição, com média e desvio-padrão amostral. A sondagem tem pausa de 100 ms, além do custo de `docker exec`. Sem NOTIFY, o refresh pode tornar o teste mais demorado.
- **E4:** observar TTL decrescente, resposta antiga após mudança e NXDOMAIN persistindo após criação do nome. Não reiniciar ou limpar o resolvedor durante a janela que se deseja medir. Calcular `janela teórica ≈ TTL + atraso de replicação` e comparar com uma medição cujo início esteja identificado.
- **E5:** confirmar leituras com ns1 parado e depois somente ns3 ativo. Elaborar o quadro de nós ativos, leitura e escrita. O script coleta leituras; a indisponibilidade de publicação é discutida a partir do primário estático, sem tentar uma escrita com ele parado.
- **E6:** ns3 deve permanecer acessível pela rede de clientes, mas conservar o dado antigo. Após expire, registrar SERVFAIL e comparar com ns1/ns2. Se não ocorrer expiração no intervalo observado, registrar o resultado como inconclusivo para essa etapa.
- **E7:** verificar uma versão antiga antes da reconexão e a convergência ao serial esperado depois. Repetir ao menos cinco vezes e declarar se a recuperação foi natural, por NOTIFY ou induzida por `rndc refresh`.
- **E8:** mostrar o primário estático, o serial inferior não adotado pelos secundários e a restauração com versão adequada. Discutir teoricamente dois primários sem coordenação; não é necessário implementar esse cenário para a discussão.

### Limitações atuais das medições automatizadas

A documentação consolidada não altera os scripts. Na versão analisada de `08-experimentos-e1-e8.ps1`:

- **E3:** o cronômetro começa depois da chamada que solicita o reload; a duração dessa chamada fica fora da medição.
- **E4:** a sondagem do cache positivo começa após aguardar os secundários. Portanto, o tempo registrado não representa toda a janela desde a publicação.
- **E7:** existe um cronômetro iniciado antes da reconexão, mas o tempo gravado vem de `Esperar`, que inicia outro cronômetro após a reconexão e o refresh. O término é detectado pelo IP, e os seriais são coletados depois.

Antes de usar esses tempos como medidas completas, ajuste a instrumentação ou faça uma medição manual controlada. Para E7, use um único cronômetro desde a reconexão até a primeira consulta que confirme o serial esperado. Não misture séries obtidas com marcos temporais ou métodos diferentes.

### Alteração manual de um registro

Com DNSSEC desabilitado, edite `zones/db.sd.lab`, altere o registro e incremente o serial SOA. Depois valide e recarregue:

```powershell
docker exec ns1 named-checkzone sd.lab /var/lib/bind/db.sd.lab
docker exec ns1 rndc reload sd.lab
```

Para alterações no `named.conf`, valide com `named-checkconf` e aplique `rndc reconfig` ou reinicie o serviço conforme a mudança. `rndc reload sd.lab` trata a zona e não substitui a aplicação de mudanças gerais de configuração.

O script auxiliar `02-alterar-ip.ps1` também publica uma alteração:

```powershell
.\scripts\02-alterar-ip.ps1 -NovoIP 10.0.0.2
```

Não o execute durante outra medição. Os scripts `03-medir-replicacao.ps1` e `07-e4-cache-negativo.ps1` permanecem como auxiliares, com saídas e pressupostos próprios; o segundo cria `novo.sd.lab` e não o remove automaticamente.

## 5. E9 com DNSSEC

Conclua E1–E8 antes desta etapa. Confira os cinco serviços principais e mantenha o resolvedor apontado para os autoritativos legítimos.

### 5.1 Ativar assinatura e validação

Use o script da **raiz do projeto**:

```powershell
.\ativar-dnssec.ps1
```

Ele aplica `dnssec-policy default` e `inline-signing yes` em ns1, obtém a DNSKEY atual, configura a âncora pública local, ativa a validação no resolvedor e procura uma resposta com `NOERROR`, `ad` e `RRSIG`. Não é necessário copiar chaves manualmente. As configurações anteriores são copiadas para arquivos `.pre-e9`.

Use esse caminho como procedimento padrão; não intercale com o auxiliar legado `scripts/04-ativar-dnssec.ps1`.

```powershell
docker exec cliente dig "@172.31.0.11" sd.lab DNSKEY +dnssec
docker exec cliente dig "@172.31.0.11" app.sd.lab A +dnssec
docker exec cliente dig "@172.31.0.53" app.sd.lab A +dnssec
```

A presença de RRSIG no autoritativo mostra a assinatura. A flag `ad` na resposta do resolvedor indica autenticação. `+dnssec` solicita registros DNSSEC; não faz o dig validar a assinatura por conta própria.

A chave privada permanece no volume `ns1_keys`. A âncora em `configs/resolvedor/trust-anchors.conf` precisa corresponder à DNSKEY da instalação atual.

### 5.2 Adulterar o dado mantendo a assinatura original

```powershell
.\scripts\05-testar-falsificacao.ps1
```

O script exporta a zona assinada por AXFR, altera apenas o A de `app.sd.lab` para `10.66.66.66` e preserva a RRSIG. Em seguida, inicia o atacante e direciona temporariamente o resolvedor a ele.

Verifique o conjunto das evidências:

1. A resposta direta do atacante contém o endereço adulterado e RRSIG.
2. A consulta normal ao resolvedor retorna SERVFAIL.
3. O controle com `+cdflag` retorna NOERROR e o endereço adulterado.
4. Os logs apontam falha de validação da assinatura.
5. Após a restauração, o resolvedor retorna o endereço legítimo com NOERROR e `ad`.

Os arquivos original e adulterado ficam em `evidencias/E9/`. O teste implementado é de adulteração, não de expiração de assinatura. Uma edição normal em ns1 pode ser reassinada automaticamente e não reproduz esse ataque.

### 5.3 Comparar o tamanho das respostas legítimas

Depois de confirmar a restauração:

```powershell
.\scripts\06-comparar-tamanho.ps1
```

Esse script consulta **ns1, em 172.31.0.11**, com `+nocookie`, variando `+nodnssec` e `+dnssec`. Salva `evidencias/E9/comparacao-tamanho.txt`.

Calcule a diferença em bytes e o aumento percentual a partir de `MSG SIZE rcvd`. A comparação mede mensagens DNS recebidas; não inclui todo o tráfego da validação nem mede CPU. `+nodnssec` não desativa a validação de um resolvedor.

Consultas ao resolvedor ou com COOKIE podem produzir outros tamanhos. No relatório, identifique servidor, opções, execução e arquivos usados. Resultados históricos não são valores garantidos para uma nova instalação.

## 6. Evidências e rastreabilidade

A execução direta dos scripts de experimento e da ativação na raiz aciona `_registrar-evidencias.ps1`. Esse arquivo é um auxiliar interno; não precisa ser chamado manualmente. A coleta cria uma pasta por execução em `evidencias/E1` a `evidencias/E9` ou `evidencias/AUX`, com:

| Arquivo | Conteúdo |
|---|---|
| `execucao.json` | Script, parâmetros e início |
| `terminal.txt` | Transcrição do PowerShell |
| `resultado.json` | Status do script e duração total |
| `erro.txt` | Exceção, quando ocorre |
| `docker-compose-ps.txt` | Estado final dos contêineres |
| `logs-ns1.txt`, `logs-ns2.txt`, `logs-ns3.txt`, `logs-resolvedor.txt` | Logs do intervalo |

Os experimentos também geram arquivos próprios. No E1–E8, ficam em uma segunda pasta com data e hora, sem o nome do script. No E9, vários arquivos de saída ficam diretamente em `evidencias/E9/` e podem ser sobrescritos: preserve uma cópia identificada antes de repetir o teste.

`SUCESSO` em `resultado.json` significa que o script terminou sem erro detectado pelo coletor; não certifica todos os critérios do experimento. A transcrição pode omitir saídas de programas externos; combine-a com capturas, logs e CSVs. O arquivo `previsao-preencher.txt` é apenas um lembrete: registre a previsão real antes de executar.

Use no relatório os dados da mesma série identificada. Preserve tentativas com erro e explique mudanças de método ou exclusões. Informe as versões efetivamente usadas e calcule média e desvio-padrão amostral das séries com pelo menos cinco rodadas.

## 7. Recuperação e limpeza

### Restaurar um teste E9 interrompido

Se restarem os backups do teste de adulteração:

```powershell
.\scripts\05-testar-falsificacao.ps1 -Restaurar
docker exec cliente dig "@172.31.0.53" app.sd.lab A +dnssec
```

Confira NOERROR, o endereço legítimo e `ad`. O modo `-Restaurar` usa os backups existentes; após confirmar a recuperação, confira e remova apenas os backups `atacante-zona.pre-teste.bak` e `resolvedor-conf.pre-teste.bak` para permitir outra execução. Esse modo não deve ser tratado como restauração genérica sem backups.

O teste normal tenta restaurar o ambiente em `finally` e remove os backups após o sucesso. A ativação DNSSEC, por sua vez, guarda `.pre-e9`, mas não desfaz automaticamente uma ativação que falhou. Antes de repetir a ativação, preserve esses arquivos, pois podem ser sobrescritos.

### Recuperar nós após uma interrupção

```powershell
docker start ns1 ns2
```

Se ns3 ficou desconectado da rede interna, reconecte-o somente após conferir que a conexão está ausente:

```powershell
docker network inspect m2_dns_interna
docker network connect --ip 172.30.0.13 m2_dns_interna ns3
```

Execute o diagnóstico e compare os seriais. Os blocos `finally` tentam restaurar zona, rede e serviços após erros tratáveis, mas não garantem recuperação após encerramento abrupto, queda de energia ou indisponibilidade do Docker. Após uma restauração, aguarde a convergência antes do próximo teste.

### Parar e recriar o ambiente

```powershell
docker compose --profile seguranca down
```

Esse comando remove os contêineres e redes, incluindo o atacante, e preserva o volume nomeado de chaves. As cópias dos secundários e o cache não têm volume persistente neste Compose.

Para voltar ao estado inicial E1–E8, pare o laboratório e restaure, a partir de uma cópia inicial confiável:

1. `configs/ns1/named.conf`, sem a política e a assinatura inline de DNSSEC.
2. `configs/resolvedor/named.conf`, com `dnssec-validation no` e os três forwarders legítimos.
3. `configs/resolvedor/trust-anchors.conf`, vazio ou somente com comentário.
4. `zones/db.sd.lab`, usando `zones/db.sd.lab.inicial` como fonte.

Os arquivos `.pre-e9` só servem para esse retorno se realmente corresponderem à fase inicial. Confira seu conteúdo antes de utilizá-los. A redefinição do serial inicial pressupõe que os contêineres antigos já foram removidos; em um laboratório em execução, restaure os dados com um serial mais recente.

Se também quiser descartar as chaves e começar uma instalação nova:

```powershell
docker compose --profile seguranca down -v
docker compose up -d --build
```

`down -v` apaga o volume `ns1_keys`. Ao executar E9 novamente, use a ativação da raiz para gerar/configurar a âncora correspondente à chave atual. Nenhum desses comandos restaura sozinho os arquivos locais de configuração.

## 8. Diagnóstico rápido

| Sintoma | Conferência |
|---|---|
| Contêiner parado ou BIND indisponível | `docker compose ps -a` e `docker compose logs --tail=100 ns1 ns2 ns3 resolvedor` |
| Erro na zona | `docker exec ns1 named-checkzone sd.lab /var/lib/bind/db.sd.lab` |
| Erro na configuração | `docker exec ns1 named-checkconf` e `docker exec resolvedor named-checkconf` |
| Secundário não atualiza | Conferir serial, conectividade interna, logs de transferência e prazo de refresh |
| Resolvedor responde valor antigo | Comparar com autoritativos e conferir TTL; pode ser cache esperado |
| SERVFAIL no E9 legítimo | Conferir DNSKEY, âncora atual, data/hora, forwarders e logs de validação |
| Erro de nomes ou redes em uso | Verificar outra cópia do laboratório e conflitos de sub-rede |

Para inspecionar um autoritativo sem solicitar recursão:

```powershell
docker exec cliente dig "@172.31.0.13" app.sd.lab A +norecurse
```

`rndc flush` limpa o cache e pode ajudar no diagnóstico, mas não deve ser aplicado durante um teste que mede sua persistência.

## 9. Organização para entrega

O repositório deve conter `compose.yaml`, `Dockerfile`, `configs/`, `zones/`, `scripts/`, `ativar-dnssec.ps1`, este README e as evidências selecionadas. No `.gitignore`, remova a regra genérica `*.csv` se ela impedir o versionamento das medições; mantenha `K*.private` para não publicar chaves privadas exportadas.

O relatório deve incluir ambiente e URL do repositório, fundamentação, diagramas, E1–E9, Q1–Q14, S1–S4, quadro-síntese, limitações, participação dos integrantes, uso de IA e sua verificação, além das referências. Para cada experimento, relacione previsão, procedimento, evidências, resultado e teoria.

O roteiro orienta 15–25 páginas sem anexos e apresentação de 10 minutos com 5 minutos de arguição, com participação de todos. Há divergência no material sobre vídeos e demonstração ao vivo; alinhe o formato com o professor. A data indicada no roteiro fornecido é 28/11/2026.

## 10. Fontes

- Roteiro Trabalho M2 Completo, disciplina de Sistemas Distribuídos, UNIVALI, 2026 — requisitos comuns, tema DNS, relatório e seminário.
- [BIND 9 Administrator Reference Manual](https://bind9.readthedocs.io/).
- [Development of the Domain Name System — Mockapetris e Dunlap, 1988](https://doi.org/10.1145/52324.52338).
- [RFC 1034 — Conceitos do DNS](https://www.rfc-editor.org/rfc/rfc1034.html).
- [RFC 1035 — Especificação do DNS](https://www.rfc-editor.org/rfc/rfc1035.html).
- [RFC 1982 — Aritmética de seriais](https://www.rfc-editor.org/rfc/rfc1982.html).
- [RFC 1995 — IXFR](https://www.rfc-editor.org/rfc/rfc1995.html).
- [RFC 1996 — NOTIFY](https://www.rfc-editor.org/rfc/rfc1996.html).
- [RFC 2308 — Cache negativo](https://www.rfc-editor.org/rfc/rfc2308.html).
- [RFC 4033 — Introdução ao DNSSEC](https://www.rfc-editor.org/rfc/rfc4033.html).
- [RFC 4035 — Validação DNSSEC](https://www.rfc-editor.org/rfc/rfc4035.html).
