# Guia de revisão: host Windows e cliente Mac

Registro preparado em 01/10/2026 para publicar o trabalho desenvolvido e testado nesta branch.
Escopo entregue: host Windows nativo de laboratório com RTX 4090/NVENC e cliente Mac para visualizar/controlar esse host.
O cliente Windows final, a instalação do host e a equivalência completa ao Parsec continuam fora do aceite deste incremento.

## Estado do código e integração

As campanhas e os fontes validados partem de `5002116872492da705aa6252f26482b02e3df5b5`, na branch `codex/windows-foundation`.
A publicação usa o fork `vhccruz/lightray`, com pull request dirigido à `main` de `diogoviannaaraujo/lightray`.
O novo commit upstream `5ef9685` elevou o requisito do aplicativo para macOS 27/Swift 6.4 e alterou o renderer e a recuperação do host Mac.
O laboratório usa Swift 6.4, mas o sistema é macOS 26.6.1; a implementação validada conserva o manifesto anterior com mínimo macOS 14.
Este PR preserva os fontes das campanhas e permanece como rascunho para revisão e adaptação à nova base, sem declarar validação do renderer macOS 27.
Os hashes e revisões nas evidências identificam os snapshots efetivamente testados; eles não são reescritos para simular execução posterior ao commit.
Relatórios/PDF/apresentação anteriores que mencionam alterações locais sem commit descrevem o estado na data de sua geração.

## Mapa do trabalho entregue

| Área | Implementação | Documentação para revisão |
| --- | --- | --- |
| Fundação Windows | Inventário, corpus HEVC auditado, decode de referência, Media Foundation/D3D11VA e comparação de pixels | [Revisão inicial](developer-report-2026-09-29.md), [validação nativa](native-validation-progress.md), [resoluções](resolution-validation-progress.md) |
| Core compartilhado | Preparação isolada de Swift Crypto, DLL/ABI C experimental, framing, transporte e harness de host | [Core Swift](swift-core-progress.md), [ponte do host](host-bridge-progress.md), [perfil de compatibilidade](compatibility-profile.md) |
| Encoder NVIDIA | NVENC HEVC nativo, conversão D3D11 BGRA/NV12, IDR, ciclo de vida e probes de recursos | [NVENC](host-nvenc-progress.md), [host ao vivo](host-live-progress.md) |
| Host remoto | Captura DXGI ou WGC explícita, anúncio de display físico, UDP autenticado, SendInput e limpeza limitada | [Desktop](host-desktop-progress.md), [recuperação](capture-recovery-progress.md), [WGC e conexão](connection-capture-progress-2026-10-01.md) |
| Robustez | Limites de memória e filas, FEC independente, NACK no orçamento do datagrama, backpressure e rotas autenticadas | [Robustez](robustness-progress.md), testes do core em `macos/Tests/LightrayCoreTests/` |
| Cliente Mac | Launcher Computadores, catálogo público limitado, seleção de tela por UUID, disconnect/reconnect, preferências e painel de sessão | [Conexão](connection-capture-progress-2026-10-01.md), [controles](session-controls-progress.md) |
| Teclado e métricas | Command/Control, liberação de input/foco, Alt+Tab/Windows, HUD de etapas, timing opcional e decode limitado | [UX](client-ux-progress.md), [telemetria](host-telemetry-progress.md), [extensão experimental](../video.md#experimental-host-timing-extension-local-windows-laboratory) |
| Planejamento e referência | Revisão do Parsec, prioridades F01–F18, testes, dependências e critérios de aceite | [Plano de produto](product-validation-plan-2026-10-01.md), [matriz de lacunas](../reviews/parsec-parity-2026-10-01.md) |

O host captura somente adapter/output 0, HEVC Main 8-bit SDR, com configurações fixas de laboratório.
WGC é uma seleção explícita; DXGI continua padrão e sua ausência de primeiro frame em algumas campanhas permanece sem causa estabelecida.
FFmpeg é usado somente para inspeção/decode offline, sem participar do encoder nativo ou da sessão Windows → Mac.
O header NVENC vendorizado preserva licença MIT, origem e hash; não há DLL de driver redistribuída no commit.
A ABI, os peers com chaves públicas de fixture e o TLV de timing `0xF0` são experimentais e não constituem distribuição/atribuição definitiva de protocolo.

## Resultado observado e limites

- O cliente Mac recebeu vídeo e controlou uma janela Windows real: texto, clique, rolagem e Command→Ctrl+A/C/V, com desconexão e segunda sessão pela interface.
- `desktop-028` encontrou `0xc0000005` durante perda injetada da captura; a evidência negativa e a linha CSV parcial foram preservadas.
- Após manter o apartamento COM durante a vida da captura, `desktop-029` recuperou três vezes em 165–199 ms até aquisição e encerrou normalmente; não houve dump/stack nem teste de todas as transições reais.
- `desktop-030` recebeu aproximadamente 42 segundos de vídeo 4K com alvo de 90 FPS e amostras de 80–90 FPS decodificados; origem/Samsung reportaram 60 Hz e 32,4% das superfícies foram reutilizadas.
- O encode p99 de 14,973 ms excede o orçamento de 11,11 ms; esses dados não certificam 90 imagens únicas/apresentações por segundo, mouse→imagem ou desempenho equivalente ao Parsec.
- O catálogo foi testado em UserDefaults isolado; onboarding de pareamento pela UI em perfil descartável, DNS assíncrono, clipboard, áudio, mouse relativo e gates prolongados continuam pendentes.

## Testes e reprodução

| Verificação | Estado |
| --- | --- |
| Suíte Mac | 116 casos aprovados: 83 core e 33 Mac; repetida antes e após organizar a documentação |
| Suíte Python | 31 casos aprovados; repetida antes e após organizar a documentação |
| Build Mac | Debug/testes e Release aprovados em macOS 26.6.1 com Swift 6.4; assinatura ad hoc apenas de laboratório |
| Componentes nativos Windows | Build MSVC `/W4 /WX /O2`; 39 casos: 12 recuperação, 19 input e 8 metadados de display |
| Core no Windows | Resultados anteriores Debug/Release com 92 casos por configuração, identificados separadamente; não repetidos no último incremento de UI/backend |
| GPU e desktop | Campanhas datadas, CSVs/logs e screenshots selecionados em `evidence/`; não executados como efeito colateral de publicar o PR |

```sh
swift test --package-path macos
swift build --package-path macos -c release
python3 -m unittest discover -s tools/windows/tests -v
git diff --check
```

No Windows, seguir o [README do laboratório](../../tools/windows/README.md), preparar a DLL compatível `swift-core-003` e executar `build-desktop-host.ps1`.
Somente depois de reservar a sessão/monitor e fornecer pareamento privado, usar os runners limitados de desktop com `-DesktopApproved` e, para a alternativa WGC, `-CaptureBackend wgc`.
Reinventariar endereços, IDs de tela e caminhos; os valores das evidências são históricos, sem garantia de disponibilidade em outra máquina.
As suítes de protocolo/componentes não substituem os gates de desktop, segurança, instalação e estabilidade do plano.
Os [logs da preparação da publicação](evidence/publication-2026-10-01/README.md) registram as repetições finais de testes/build e a conferência dos links e manifestos.

## Evidências e entregáveis

Começar pelo [relatório consolidado](developer-report-2026-10-01.md) e pelo [incremento mais recente](connection-capture-progress-2026-10-01.md).
Os [relatórios para compartilhar](reports/README.md) incluem o PDF mais recente e a apresentação histórica, com escopo/data explícitos.
O diretório `evidence/` conserva somente material selecionado para revisão, com manifests por campanha quando disponíveis; logs PowerShell podem estar em UTF-16LE.
Os atributos Git preservam os bytes das evidências e do header NVIDIA fixado, inclusive CRLF/UTF-16, para não invalidar hashes na publicação ou no checkout Windows.
Não entram no commit `output/`, `tmp/`, `tools/windows/results/`, aplicativos/hosts compilados, pareamentos reais, configuração SSH, credenciais ou chaves privadas.
Fixtures criptográficas são públicas, identificadas nos testes e nunca devem ser usadas como pareamento real.
