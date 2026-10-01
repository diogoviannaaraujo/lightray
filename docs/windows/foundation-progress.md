# Execução das primeiras etapas — 28/09/2026

Estado: primeiro incremento local de E01/E02 concluído, com correções e testes; homologação Windows ainda não iniciada.
Checkout de desenvolvimento: `/Users/vhccruz/Dev/lightray`, branch `codex/windows-foundation`, a partir de `5002116872492da705aa6252f26482b02e3df5b5`.
Origem: `https://github.com/diogoviannaaraujo/lightray.git`.
A pasta recebida `/Users/vhccruz/Dev/lightray-main` continua preservada como baseline do código; o desenvolvimento passa a ocorrer no checkout completo.
As alterações deste incremento estão locais e não foram publicadas.

## Itens executados

| Item | Resultado | Evidência |
| --- | --- | --- |
| E01.3 | Checkout completo e branch de trabalho a partir do SHA auditado; documentos da revisão copiados sem outputs de build | Git local e baseline executada no novo diretório |
| E02.1–E02.4 | Contrato fixado para handshake, transporte, streams, input, controle e HEVC | [Perfil de compatibilidade](compatibility-profile.md) |
| E02.5 | RS documentado e fixture independente com dados, coeficientes e paridade de três códigos | [Gerador Python](../../tools/vectors/fec_reference.py), [JSON](../../macos/Tests/LightrayCoreTests/Fixtures/fec-reference.json) e teste de encode/recovery |
| E02.6 / R01 | Comprimento do último shard validado também em paridade e antes da alocação do receiver | Casos 0, 1, stride, stride+1 e UInt16.max; rejeição sem trap |
| E02.6 / R02 | Configuração vazia rejeitada e framing/cabeçalhos NAL validados antes do codec | Testes de parser, decoder e fixtures HEVC válidos existentes |
| E02.7 / R03 | NACK dividido pelo MDS, saída excessiva recusada e registrada em contador | MTUs 256/512/1200/9000, decriptação dos datagramas produzidos e ranges completos |
| E02.8 / R04 | Resultado de enqueue propagado; motion retido/coalescido; falha de input confiável encerra sessão para reset no host | Saturação, key-up, button-up, motion pendente, recuperação após ACK e perda unidirecional |
| Preparação parcial E01.8 | Três streams HEVC e seus manifests importados do SHA da pesquisa, total de 1.699.953 bytes | [Manifesto de origem e hashes](evidence/foundation/hevc-corpus.json) |

O contrato documental não cria uma nova negociação no protocolo: dados válidos mantêm seu formato.
As mudanças de API são locais: `ClientEndpoint.send` e `Connection.queue` agora devolvem aceitação como `Bool`, com retorno descartável para compatibilidade dos chamadores atuais.

## Comportamento e limites das correções

R01 agora rejeita paridade com lastLength fora de `1...stride`, impedindo o `removeLast` negativo reproduzido na revisão.
Também há teste direto do receiver para evitar que um chamador local contorne essa validação específica.

R02 recusa VPS/SPS/PPS vazios no core e verifica tipo/cabeçalho dos parameter sets na fronteira VideoToolbox.
Payloads com tamanho NAL vazio, incompleto, além do buffer ou header HEVC inválido falham de forma controlada.
Isso é validação estrutural; a interpretação completa de SPS/PPS/slices continua responsabilidade do codec.

R03 trata um NACK grande antes de serializá-lo, dividindo seus ranges conforme o tamanho negociado.
A investigação também mostrou que o limite de 128 ranges marcava como enviados pedidos que não saíam no pacote; agora os ranges omitidos permanecem devidos.
O teste confere todos os 159 ranges solicitados em duas consultas e os bytes dos datagramas efetivamente cifrados.

R04 não aumenta indefinidamente a fila de input.
O movimento absoluto guarda a posição mais recente e tenta novamente quando há capacidade, com tentativas espaçadas para não gerar busy loop.
Se uma tecla, botão ou scroll não for aceito, o cliente interrompe a sessão, descarta input antigo ainda na saída e tenta enviar CLOSE diretamente.
O host existente libera input em `sessionEnded` ou `paused`; os testes simulam ambos, inclusive quando todo tráfego cliente→host é perdido.
Quando o caminho está indisponível, a liberação depende do timeout do host; não há promessa de liberação instantânea sem comunicação.
Estes são testes dos eventos/estado de protocolo e da ligação por inspeção com `Injector.reset`; não houve injeção em desktop real nesta etapa.

## Verificações e resultados

| Verificação | Resultado | Log |
| --- | --- | --- |
| Baseline antes das alterações | 59 testes de core + 5 de adaptadores = 64 aprovados | [baseline-tests.log](evidence/foundation/baseline-tests.log) |
| Gerador antes das alterações | 11 aprovados | [baseline-vectors.log](evidence/foundation/baseline-vectors.log) |
| Regressões novas na implementação original | Seis funções de teste falharam com 23 ocorrências, sem crash do processo | [regressions-before.log](evidence/foundation/regressions-before.log) |
| Suíte após as correções | 68 testes de core + 7 de adaptadores = 75 aprovados | [tests-after.log](evidence/foundation/tests-after.log) |
| Gerador após as alterações | 11 aprovados | [vector-tests-after.log](evidence/foundation/vector-tests-after.log) |
| Referência FEC independente | Três casos regenerados e conferidos | [fec-reference.log](evidence/foundation/fec-reference.log) |
| Build release host/cliente Mac | Aprovado | [release-build.log](evidence/foundation/release-build.log) |
| Checker documental/vetores | 15 blocos conferidos, zero problemas | [vector-check.log](evidence/foundation/vector-check.log) |
| Diff, links, fixtures e baseline preservada | Diff sem whitespace errors; seis documentos sem links locais quebrados; seis fixtures HEVC idênticos à origem; 73 arquivos originais preservados | [artifact-check.json](evidence/foundation/artifact-check.json) |

Correção de contagem da revisão inicial: os 59 testes mencionados eram os do core; havia mais cinco do target Mac, portanto a baseline já tinha 64 testes de produto.
Os 11 do gerador são uma suíte separada.
As contagens não somam novamente os casos parametrizados de uma mesma função de teste.

Os primeiros testes novos precisaram de um ajuste no harness para usar um chunk com payload em vez de atribuir payload ao enum PADDING; o log red/green preservado corresponde ao harness compilando e às falhas reais da baseline.
Os probes antigos da revisão registram o comportamento defeituoso e devem ser executados apenas no checkout original; suas precondições não são gates do código corrigido.

Comandos de reprodução, na raiz do checkout de desenvolvimento:

```sh
swift test --package-path macos
swift test --package-path tools/vectors
swift run --package-path tools/vectors lightray-vectors check
swift build -c release --package-path macos
python3 tools/vectors/fec_reference.py --check macos/Tests/LightrayCoreTests/Fixtures/fec-reference.json
git diff --check
```

## Pendências e próxima ordem

1. E02.9 / R06 — Orçamento agregado de bytes e metadados por stream/sessão, com testes pequenos que pressionem limites sem provocar OOM real.
2. E02.10 / R07–R08 — Fila de decode limitada por tamanho/idade e callbacks protegidos por geração, com cancellation/teardown exercitados.
3. E02.11 — Corrigir destino de envio após rebind do host e melhorar métricas/diagnóstico de socket.
4. E01.2/E01.4–E01.7 — Concluir identidade SSH e inventariar Windows, ferramentas, GPU, sessão gráfica e rede.
5. E03 — Somente então executar os experimentos nativos de core/decoder/apresentação e registrar a escolha de stack.

A nova tentativa de acesso ao alias `rtx4090` continuou falhando antes da autenticação porque a chave ED25519 do servidor não está reconhecida neste Mac.
A identidade não foi aceita automaticamente; a confirmação solicitada na revisão permanece pendente.
Nenhum driver, serviço, plano de energia, firewall ou workload da RTX foi alterado.
Não há medições Windows, resultados de FPS/latência reais nem aprovação de M0/M1 completos: o laboratório e os outros bloqueios de robustez continuam necessários.
