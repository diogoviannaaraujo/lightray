# Evidências da telemetria do host — 30/09/2026

Relatório e interpretação: [telemetria Windows → Mac](../../host-telemetry-progress.md).

- `desktop-020`: tentativa que falhou com perda da duplicação DXGI; não é um resultado de desempenho válido.
- `desktop-021`: recuperação por reinício do host; `recovery-client.log` e `recovery-reconciliation.json` conferem seis amostras exatas.
- `desktop-022`: host atualizado usado nas quatro rodadas, no teste com cliente anterior e na inspeção do painel; contém CSV completo, resultados e leituras globais de GPU.
- `benchmark/`: logs e medidas de CPU/RSS das quatro rodadas, além de quatro verificações com oito amostras exatas cada.
- `benchmark-summary.json`: distribuições e limites da comparação; FPS e médias do cliente são janelas amostradas, enquanto captura/encode usam frames do CSV dentro dos recortes de IDs.
- `legacy-client.log`: cliente anterior aceitando o host com telemetria; `legacy-host-client.log` e `desktop-023`: cliente novo aceitando host e DLL anteriores, sem telemetria.
- `ui-client.log` e `ui-observations.json`: verificação de janela, tela cheia, ocultação/reabertura e campos indisponíveis; observações registradas, não replay automatizado.
- `mac-tests.log`, `python-tests.log`, `windows-debug-tests.log`, `windows-release-tests.log`, arquivos de build e resultados ABI: verificações concluídas em 29/09/2026 para as fontes usadas nesta campanha.
- `source-manifest.json`: hashes das fontes, cliente Mac atual/anterior, executável Windows atual/anterior e DLL da rodada principal.
- `cleanup.json`: ausência de processos, tarefas, endpoint UDP e regra temporária de firewall ao encerrar.

Arquivos UTF-16 foram normalizados para UTF-8.
Workers, pareamento, conteúdo de clipboard e capturas de aplicativos pessoais não estão incluídos.
As quatro rodadas mantiveram input ativo e receberam eventos; os resultados são exploratórios e não isolam causalmente o custo do painel.
Não houve execução do Parsec nesta campanha, medição física de latência ou certificação de 90 apresentações por segundo.
