# Host Windows: componente NVENC e integração UDP local

Data: 29/09/2026.
Esta etapa continua H01/H03/H04 do [plano do host](host-implementation-plan.md), após a [ponte C autenticada](host-bridge-progress.md).
Os testes continuam nativos no Windows 11 x64/RTX 4090, com MSVC e driver NVIDIA 591.86, usando somente estímulos sintéticos.
Não houve captura de desktop, janela, mudança de foco ou input.

## Componente de encoder

A implementação foi extraída do probe para `tools/windows/src/nvenc_encoder.hpp` e `.cpp`.
O componente recebe uma textura D3D11 NV12 do mesmo device e devolve bytes próprios de HEVC Annex B, payload com NALs prefixados por comprimento, configuração VPS/SPS/PPS, geração e timestamp.
O programa de corpus anterior agora usa esse componente, preservando CLI, padrões e formato de resultados.

Há uma textura NV12 registrada e um buffer de bitstream por encoder, com encode/lock síncrono e sem callbacks ou frames pendentes ao retornar.
Uma cópia GPU→GPU para a textura própria permite devolver o controle ao chamador sem manter emprestada sua superfície; esse caminho ainda não é zero-copy.
O componente não faz readback do input; a origem sintética de laboratório ainda gera pixels na CPU e faz upload.
A saída mantém Annex B e payload simultaneamente para validação, com limite de 4 MiB por representação; o adapter de produto poderá evitar a cópia redundante.

- `request_idr` força IDR com configuração no próximo frame.
- `pause` invalida a geração anterior e rejeita encode até `resume`; a retomada exige IDR.
- `reconfigure` valida os argumentos antes de alterar o estado, fecha a sessão anterior e abre outra; ainda não usa reconfiguração in-place do driver.
- O estado de pausa é preservado ao trocar configuração, e a nova sessão começa com IDR/VPS/SPS/PPS.
- Device estrangeiro, textura de formato/dimensão incorretos, ponteiro nulo, timestamp repetido e geração antiga são recusados.
- Erros de driver/bitstream encerram a instância; o chamador recebe erro explícito e deve criar outra.
- `close` drena e libera recursos explicitamente; pode ser chamado novamente sem repetir operações do driver.

Uma única referência à DLL NVENC é mantida até o fim do processo para evitar carga/descarga a cada sessão; as sessões, registros de superfície e buffers continuam sendo liberados em `close`.
Chamadas e trabalho no immediate context devem ser serializados pelo proprietário.
Não há promessa de acesso multithread ao encoder nem avaliação de execução assíncrona nesta etapa.
Ausência de DLL e incompatibilidade de versão têm caminhos explícitos de erro, mas não foram simuladas alterando o driver da máquina.
O device WARP foi usado apenas como controle negativo de rejeição de fornecedor, sem encoding ou fallback software.

## Ensaio de ciclo de vida

`nvenc_lifecycle_probe.cpp` aquece 30 ciclos completos e executa outros 100 ciclos medidos com duas sessões cada: configuração inicial e troca para a resolução seguinte.
São 60 sessões/180 frames no aquecimento e 200 sessões/600 frames na medição; o bitstream auditado contém os 600 frames medidos.
São 100 reconfigurações, 600 frames registrados, 400 IDRs e 200 P, alternando 1080p, 1440p e 4K.
Cada ciclo verifica IDR inicial, P, IDR solicitado, pausa/retomada, rejeição de geração antiga, configuração inválida sem destruir a sessão válida, troca de resolução, preservação de pausa e fechamento idempotente.
`ffprobe` decodifica os 600 frames e confere dimensão, pixel format e tipo de cada frame contra a sequência esperada, incluindo as trocas de SPS.
A validação detecta erros de decode/estrutura; não é comparação de qualidade visual ou de pixels com a origem crua.

A campanha final coleta 131 amostras de memória privada, working set, memória GPU local/não local atribuída ao processo e handles do processo.
As 30 amostras iniciais e a amostra fria ficam registradas; a comparação de estabilidade usa somente a janela após aquecimento.
Os limites foram definidos antes da primeira execução e não foram ampliados: crescimento da mediana dos últimos 20 ciclos contra os primeiros 20 de até 32 MiB privados, 16 MiB por segmento GPU e oito handles.
Working set é diagnóstico, sem gate.
Esses limites são guardrails do ensaio curto, não prova de ausência de vazamento nem critério final de produto.

## Integração com o core e Winsock

O modo `--live-loopback` do `host_abi_probe.cpp` gera cada textura, codifica pelo componente NVENC e entrega o frame diretamente à ABI C do `HostEndpoint`.
Os arquivos de corpus servem como oráculo de bytes: o frame transmitido nesse modo vem do encoder ao vivo.
Host e peer de laboratório se comunicam por sockets UDP reais não bloqueantes, restritos a IPv4 loopback.
O peer usa `ClientEndpoint` para autenticar/remontar e comparar o payload recebido com aquele produzido pelo encoder.
Nenhum decoder ou apresentação é executado no receptor desse ensaio.

`udp_loopback.hpp` é um adapter de laboratório, não o adapter Winsock de produto.
Ele usa bind exclusivo em `127.0.0.1:7373` para o host e porta efêmera para o cliente; se a porta estiver ocupada, falha sem substituir o listener existente.
Não há mudança de firewall nem listener em LAN/Tailscale.
Recepção preserva o peer, rejeita datagramas vazios/acima de 1200 bytes e limita cada drenagem a 256 leituras; erros são explícitos.
Backpressure de envio faz o ensaio falhar; a fila/retry de produto ainda precisa ser implementada.
Os sete casos de socket cobrem fila vazia, exclusividade, limite de tamanho, envio vazio, payload de 1200 bytes/peer correto, drenagem completa e rebind após destruição.

O core mantém relógio simulado, mesmo no modo UDP real.
A geração dos frames não segue um scheduler de 60 Hz real: não interpretar tempo de execução, timestamps simulados ou contagens como FPS sustentado, jitter, latência de rede ou input→photon.
O FEC permanece desligado e o ensaio não injeta perda/reordenação.
Eventos de pedido de IDR do core são drenados pelo harness, mas ainda não comandam o encoder; a campanha sem perdas solicita IDR explicitamente nos índices 0/60.
A DLL Swift foi reutilizada sem alteração de bytes, com hash `5f71e68c6047c42df88f2faa9bfb640b1356eeb3532fcb668ae5aa09850aec8c`; os 88 testes por configuração pertencem à campanha anterior, não a uma nova execução nesta etapa.

## Falhas preservadas e interpretação de memória

A primeira versão de integração não compilou com `/WX` por uma conversão implícita de porta `int` para `uint16_t` em `make_unique`; a conversão foi tornada explícita, preservando o warning como erro.
As campanhas de lifecycle 002 e 003 produziram 600 frames válidos, mas falharam no gate de crescimento de memória privada com apenas cinco sessões simples de aquecimento.
Manter a DLL carregada não resolveu esse gate isoladamente: a campanha 003 também falhou.
Os logs por ciclo mostraram forte crescimento inicial seguido de estabilização; por isso, a metodologia final aquece o mesmo ciclo completo que será medido, incluindo pausa e reconfiguração.
Não foi aumentado o limite de 32 MiB nem apagada a fase fria.
O custo inicial continua visível no CSV e no campo `warmup_growth` do resultado, e não deve ser confundido com crescimento contínuo durante os 100 ciclos seguintes.
Memória privada comprometida e working set são métricas diferentes; não atribuir toda a reserva privada à RAM física residente, nem concluir qual biblioteca a reservou sem profiling adicional.

## Resultados finais e reprodução

| Campanha | Resultado |
| --- | --- |
| Corpus `native-nvenc-005` | 360 frames inspecionados; bitstreams, payloads e configs idênticos aos de `003` e `004` |
| Lifecycle `004` e `005` | Em cada execução: 100 ciclos medidos, 100 trocas de resolução, 600 frames decodificados; 30 ciclos prévios de aquecimento |
| Memória privada após aquecimento | Crescimento das medianas: 0,557 MiB e 2,896 MiB, abaixo de 32 MiB |
| Memória GPU local/não local e handles após aquecimento | Crescimento das medianas zero nas duas execuções |
| Custo de aquecimento | Memória privada +335,61 MiB e +345,29 MiB desde a amostra fria; não foi excluído dos dados |
| Integração final `host-loopback-003` | 360 frames NVENC ao vivo íntegros, três sessões, 2.179 datagramas enviados e 2.179 recebidos |
| Regressão em memória na mesma build | 360 payloads íntegros, três sessões e 100 ciclos de handles por quatro threads |
| Testes do adapter e harness | Sete casos Winsock, 14 casos de framing C++, 29 testes Python em cada sistema |
| Limpeza | Nenhum processo de probe nem endpoint de teste em `127.0.0.1:7373` remanescente |

O crescimento após aquecimento não inclui o custo de inicialização: no final das campanhas a memória privada estava próxima de 467–470 MiB, enquanto o working set estava próximo de 79 MiB.
Esses números são do processo inteiro do harness, incluindo devices auxiliares e driver; não são uma medição isolada da memória do encoder de produto.
Os [logs e hashes](evidence/host-live-initial/README.md) preservam resultados iniciais, falhas, CSVs completos e os binários identificados por hash.

Reprodução no Windows, a partir da raiz do checkout, com MSVC, Swift e ferramentas de mídia do laboratório disponíveis:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/windows/build-nvenc-probe.ps1
python tools/windows/run-nvenc-probe.py --output tools/windows/results/native-nvenc-004
python tools/windows/run-nvenc-lifecycle.py --output tools/windows/results/nvenc-lifecycle-001
powershell -NoProfile -ExecutionPolicy Bypass -File tools/windows/run-host-loopback.ps1 -CoreProbe swift-core-002 -Run host-loopback-001
```

Os nomes acima pressupõem diretórios novos; todos os runners recusam sobrescrita.
A DLL do core precisa ser previamente preparada e validada conforme `tools/windows/README.md`; o runner UDP usa `native-nvenc-004` como oráculo.
Este é um harness de laboratório com chave fixa de fixture, sem política de pairing de produto.

## Gates restantes

Atualização posterior: o [marco desktop Windows→Mac](host-desktop-progress.md) acrescentou relógio real, captura, apresentação e input na LAN.
Os resultados acima continuam sendo os ensaios de loopback com relógio simulado; não devem ser reinterpretados como testes de desktop.

H01 ainda depende de investigar/otimizar o custo de aquecimento, completar os controles de falha de driver/device e executar uma campanha mais longa.
H03 ainda depende de relógio real/timers, IPv6, retry/backpressure, autenticação negativa no socket, perda/MTU/reconexão e caminho Mac↔Windows.
H04 ainda depende de encaminhar eventos do core para o encoder, respeitar cadência/bitrate/FEC e completar 30 minutos em tempo real antes de ampliar a duração.
Captura, input e apresentação seguem as etapas posteriores e a combinação prévia de uso da sessão com o usuário.
