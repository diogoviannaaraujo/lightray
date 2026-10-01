# Lightray — atualização para revisão do desenvolvedor

Data: 01/10/2026.
Escopo: cliente Mac conectado a host Windows nativo com captura DXGI/WGC e encoding HEVC/NVENC na RTX 4090.
Base das campanhas: `5002116872492da705aa6252f26482b02e3df5b5`, branch `codex/windows-foundation`.
O [guia de revisão do pull request](pull-request-review.md) registra a publicação deste snapshot e a adaptação pendente à nova base macOS 27.
Este relatório complementa a [revisão inicial de 29/09](developer-report-2026-09-29.md) e não certifica uma distribuição de produção.

## Resultado e decisão de continuidade

O caminho Windows → Mac já teve vídeo real, controle remoto e encoding NVENC comprovados nas campanhas anteriores.
O incremento atual acrescenta recuperação limitada da captura, menu de sessão, preferências por host e ampliação do mapa de teclado Windows.
Dez perdas injetadas da duplicação DXGI recuperaram na mesma sessão em 30/09.
Em 01/10, duas inicializações autenticaram sem entregar o primeiro frame, e a falha persistente terminou dentro do prazo previsto.
A atualização seguinte restabeleceu vídeo e entrada pelo backend explícito Windows Graphics Capture, acrescentou a janela Computadores e validou três recriações WGC após corrigir o ciclo de vida COM.
A campanha 4K com alvo de 90 FPS registrou 80–90 FPS decodificados, com origem/Samsung a 60 Hz; estabilidade e apresentação física continuam abertas.
O [relatório de conexão e captura WGC](connection-capture-progress-2026-10-01.md) contém a evidência mais recente, inclusive a falha nativa encontrada antes da correção.

A interface segue a referência funcional do Parsec para ações sobre o stream, com nome Lightray, acento ciano e controles nativos do Mac.
Não foi executado benchmark do aplicativo Parsec; a [investigação de referência](../reviews/parsec-reference-2026-09-29.md) usa documentação oficial.
O [plano atualizado](product-validation-plan-2026-10-01.md) organiza implementação, testes e critérios de aceite por dependência.

## Ambiente e limites de comparação

| Componente | Ambiente observado |
| --- | --- |
| Host | Windows 11 Home x64, build 26200, execução nativa; nenhum teste desta captura usou WSL |
| GPU e encoder | NVIDIA RTX 4090, driver 591.86; NVENC HEVC por API nativa no host |
| CPU e memória | Intel Core i7-12700KF e aproximadamente 64 GB RAM |
| Build Windows | Swift 6.4 x64 para o core; MSVC 14.44 com `/W4 /WX /O2` para os componentes nativos |
| Transporte das campanhas | LAN, sessão autenticada, UDP, alvos de 20/80 Mbps, FEC desligado |
| Captura inventariada em 01/10 | 3840×2160 a 60 Hz; o inventário também listou modo de 160 Hz disponível |
| Monitor reservado do cliente | Samsung U28E590, ID 4 no inventário Mac de 01/10, máximo reportado de 60 FPS |
| Alternativa do cliente | Tela integrada do Mac, ID 1, máximo reportado de 120 FPS |

Os IDs de monitor devem ser inventariados novamente antes de outra execução.
Não alteramos modo de tela, driver ou frequência nesta rodada.
O Samsung permite validar interface, vídeo recebido e fluidez até sua cadência reportada; ele não permite certificar 90 apresentações por segundo com a configuração observada.
Testes de apresentação a 90 FPS devem usar uma tela com frequência adequada, como a integrada, mantendo separadas as medições de recepção, decode e apresentação.
FFmpeg aparece em evidências anteriores como ferramenta de laboratório para inspeção/decode; ele não implementa o encoder deste host Windows.

## Alterações para revisão

| Área | Mudança | Fonte principal |
| --- | --- | --- |
| Política de recuperação | Prazo de cinco segundos, até oito recriações, watchdog inicial de um segundo e backoff limitado | `tools/windows/src/capture_recovery.hpp` |
| Captura DXGI | Cache deixa de estar pronto após perda; recria duplicação no mesmo device e valida geometria/formato | `tools/windows/src/desktop_capture.hpp` |
| Host nativo | Bloqueio/liberação de input durante perda, época de captura, primeiro frame IDR e diagnóstico de falha | `tools/windows/src/windows_host.cpp` |
| Teclado Windows | ISO, tecla de menu e F13–F20; preserva lados dos modificadores | `tools/windows/src/windows_input.hpp` |
| Menu da sessão | Métricas, Command/Control, cursor local, tela cheia, Alt+Tab, Windows, retomada e reset | `macos/Sources/lightray-client/SessionControls.swift` |
| Preferências | Registro versionado pelo identificador público de pareamento; CLI prevalece; laboratório pode desativar persistência | `macos/Sources/LightrayMac/SessionPreferences.swift` |
| Estado do vídeo | Observação de progresso do decode, espera/interrupção e proteção da entrada | `macos/Sources/LightrayMac/StreamActivity.swift` e `VideoView.swift` |

O menu libera a entrada remota ao abrir; fechá-lo conserva a liberação até retomada explícita ou primeiro clique de retomada consumido localmente.
Os botões remotos do painel retomam a entrada explicitamente, fecham o painel e enviam a sequência completa somente com vídeo ativo.
A ausência de progresso de decode por dois segundos pausa o encaminhamento e libera teclas/botões mantidos pelo cliente.
O cursor local permanece visível enquanto a entrada não pode ser encaminhada.
O estado no cliente descreve observação de decode e não identifica a causa de captura, rede ou processamento.

A recuperação cobre somente o mesmo adapter/device, geometria, orientação e formato.
Mudança dessas condições encerra o host com erro, pois reconstrução do pipeline e renegociação ainda não foram implementadas.
O cliente pode conservar a última imagem acompanhada do estado de interrupção; a continuação do vídeo depende de frame novo.

## Testes e evidências

| Verificação | Resultado | Interpretação |
| --- | --- | --- |
| Baseline Mac | 106 Swift e 31 Python aprovados | Estado antes deste incremento |
| Resultado Mac final | 116 Swift: 83 core e 33 Mac; 31 Python aprovados | Inclui catálogo público, parser/limites, proteção de caminhos e incrementos anteriores |
| Build Mac | Release e assinatura ad hoc aprovados | Aplicativo de laboratório; não é notarização/distribuição |
| Build Windows final | MSVC nativo aprovado; 19 casos de input, 12 de recuperação e 8 de display | Inclui WGC opcional e metadados reais do output |
| Interface no Samsung | Computadores, validação de porta, prazo de conexão, desconexão/segunda sessão e painel com vídeo real | Texto, clique, scroll e Command→Ctrl+C/V confirmados na janela Windows |
| Atalho novo do menu | Reconhecimento automatizado aprovado | A integração visual retornou timeout; teste físico pendente |
| Captura `desktop-024` em 30/09 | 10 de 10 recuperações; 11 de 11 épocas iniciaram com IDR; uma sessão autenticada | Perda injetada do objeto DXGI real, sem transição real do desktop |
| Captura `desktop-025/026` em 01/10 | Autenticação com zero frames e encerramento por prazo | Impedimento real cuja causa permanece aberta |
| Falha persistente `desktop-027` | Encerramento esperado com código 1 em 5.022 ms externos | Começou sem primeiro frame; não comprova falha após vídeo ativo |
| WGC `desktop-028` | Vídeo/input/reconexão positivos; perda injetada causou `0xc0000005` | Evidência negativa preservada, sem relatório final normal |
| WGC `desktop-029` | Apartamento COM mantido; três recriações em 165–199 ms, quatro épocas/IDRs e 2.823 frames | Encerramento normal; não cobre transições reais de desktop |
| WGC `desktop-030` | 4K com alvo 90; 3.579 frames; 80–90 FPS decodificados; primeiro decode após auth 124,040 ms | Três descartes de decode; fonte/tela a 60 Hz; não certifica 90 apresentações |
| Limpeza final | Zero processos de laboratório Mac/Windows, tarefas temporárias, endpoint UDP e regras temporárias Windows | Sessões de teste encerradas |

Os resultados Windows Debug/Release de 92 casos por configuração da etapa de telemetria permanecem evidência anterior; eles não foram repetidos nesta alteração de UI e backend nativo.
As evidências de [recuperação](evidence/capture-recovery-initial/README.md), [controles da sessão](evidence/session-controls-initial/README.md) e [conexão/captura WGC](evidence/connection-wgc-initial/README.md) preservam logs, CSV, conciliação, screenshots e hashes.
Os testes Windows Debug/Release do core não foram repetidos porque o contrato/ABI do core não mudou neste incremento nativo/UI.

## Desempenho já medido, sem extrapolação

A campanha exploratória anterior usou quatro rodadas de 45 segundos, ordem painel ligado/oculto/oculto/ligado, excluindo dez segundos de aquecimento em cada rodada.
As medianas de decode foram 89, 90, 88 e 89 FPS; encode p50 entre 5,476 e 5,808 ms e p99 entre 15,037 e 15,547 ms.
A RTT mediana por rodada ficou entre 4,6 e 5,4 ms; decode entre 2,20 e 2,40 ms, e fila entre 0,04 e 0,05 ms.
A origem Windows e o monitor Mac reportaram 60 Hz nessa campanha, com 33,7% de superfícies reutilizadas pelo host.
Input permaneceu ativo, portanto a comparação não isola causalmente o custo do painel.
Esses dados não certificam 90 FPS apresentados, latência física de mouse até imagem ou equivalência ao Parsec.
Os recortes, clocks e limitações estão no [relatório de telemetria](host-telemetry-progress.md).

Na recuperação de 30/09, o host registrou 109,926–122,153 ms até nova aquisição; esse intervalo termina antes do encode e da apresentação.
O polling externo observou 220–254 ms, incluindo seu próprio intervalo de consulta.
Dez ciclos com pequena variação de memória/handles não substituem soak de 8 ou 24 horas.

## Pendências prioritárias para o desenvolvedor

1. Concluir os gates de captura com WGC: partidas frias, sessão longa e transições reais; manter o diagnóstico DXGI aberto e não converter os três testes de perda injetada em homologação de produção.
2. Validar os controles novos com vídeo ativo, incluindo retomada consumida, Alt+Tab/Windows, foco no menu e perda de captura com tecla/botão mantidos.
3. Exercitar falhas reais de DXGI e separar perda recuperável, perda de device e alteração de geometria, com encerramento previsível onde ainda não houver suporte.
4. Completar teclado internacional ANSI/ISO/ABNT2, acentos, cedilha, AltGr e Caps Lock; os novos scancodes não certificam texto internacional.
5. Projetar clipboard Unicode por ação explícita, áudio, qualidade renegociável, cursor relativo e modo imersivo com permissão e saída local.
6. Executar campanhas de conexão/latência/desempenho/compatibilidade com cenas e clocks definidos, comparando Parsec somente sob configuração equivalente.
7. Completar onboarding/pareamento em perfil descartável, DNS assíncrono, acessibilidade/localização e empacotamento; a interface básica de computadores já está implementada.

## Reprodução e entrega

O pacote atualizado contém fontes, documentação, evidências selecionadas, apresentação de revisão e `MANIFEST.sha256`.
Ele é um snapshot das alterações locais sobre a base indicada, não um instalador e não um commit publicado.
Pareamento, chaves, configuração SSH, dependências de build e arquivos temporários não estão incluídos.
O operador deve fornecer um pareamento válido por arquivo privado no ambiente de teste.

No Mac, execute `swift test --package-path macos` e `swift build --package-path macos -c release --product lightray-client`.
Os testes Python usam `python3 -m unittest discover -s tools/windows/tests -v`.
O host deve ser construído pelo builder `tools/windows/build-desktop-host.ps1`, com os caminhos preparados do SDK NVENC e do core compatível; o runner desta campanha utiliza explicitamente `swift-core-003`.
A [descrição dos controles](session-controls-progress.md) e a [recuperação](capture-recovery-progress.md) detalham parâmetros e comportamento.
Não reutilize identificadores de monitor, endereços ou caminhos de laboratório sem conferir o ambiente.

Não houve mudança de refresh/topologia/driver nem encerramento de aplicativos alheios ao laboratório.
WGC está disponível por opção explícita no runner; a autorização de testes e o monitor reservado permanecem válidos para a continuidade.
