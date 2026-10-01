# Primeiro smoke de apresentação — 29/09/2026

- `queue-1/` e `queue-2/`: resultados nativos, CSVs de 600 frames, diagnósticos e códigos de saída dos launchers autorizados.
- `provenance.json`: hashes dos fontes/executável, GPU/driver, quantidade de rodadas e confirmação de exit 0.
- `cleanup.json`: zero tarefas temporárias e zero processos do probe após as rodadas.
- `comparison-mac.json` e `comparison-windows.json`: percentis recalculados e integridade estrutural conferida nos dois sistemas, com os mesmos hashes dos arquivos de entrada.
- `lab-tests-mac.log` e `lab-tests-windows.log`: 20 testes aprovados, incluindo controles de dados parciais, reordenação, NaN, resumos divergentes e cargas incompatíveis.
- `docs-check.log`: verificação dos blocos/vetores e links documentais.

O executável corresponde ao hash preservado em `../presentation-preparation/presentation-readiness.json`.
O snapshot de preparação permanece histórico e indica que a execução visual ainda estava pendente naquele momento.
Não foram preservados scripts de launcher gerados com caminhos pessoais; somente os resultados e metadados necessários à revisão.
Os valores são de submissão D3D11 com conteúdo sintético em janela; não são medição independente de exibição física, decode, rede ou input→photon.
