# Experimento de apresentação D3D11 — 29/09/2026

O [probe D3D11](../../tools/windows/src/present_probe.cpp) foi compilado nativamente com MSVC x64, C++20 e `/W4 /WX /O2`.
Os 11 casos de parâmetros e três casos estatísticos de `--self-test` passaram sem criar janela ou swapchain.
Os hashes do executável/fontes, os logs de build e os controles que recusam parâmetros inválidos e execução sem liberação estão em [evidence/presentation-preparation](evidence/presentation-preparation/presentation-readiness.json).
A execução visual foi autorizada pelo usuário em 29/09/2026 e concluída em duas rodadas, preservando o limite combinado de 30 segundos por rodada.
O executável usado correspondeu ao SHA-256 do artefato previamente compilado e testado; os dois processos terminaram com código zero.

## Resultado das duas rodadas

| Medida | Fila máxima 1 | Fila máxima 2 |
| --- | --- | --- |
| Submissões concluídas | 600 | 600 |
| Duração | 9,976 s | 9,953 s |
| Chamadas de apresentação/s | 60,144 | 60,282 |
| Intervalo de submissão p50 | 16,666 ms | 16,664 ms |
| Intervalo de submissão p95 | 16,896 ms | 16,840 ms |
| Intervalo de submissão p99 | 17,013 ms | 16,954 ms |
| Maior intervalo registrado | 17,725 ms | 17,357 ms |
| Intervalos acima de 25 ms | 0/599 | 0/599 |

Os resultados completos, CSVs por frame, códigos de saída, versão de driver e hashes estão em [evidence/presentation-initial](evidence/presentation-initial/README.md).
O primeiro intervalo de cada execução é excluído dos percentis porque não tem submissão anterior.
Na fila 2 houve um intervalo inicial de 0,279 ms, compatível com enchimento da fila; a taxa média levemente acima de 60 chamadas/s não comprova atualização física acima de 60 Hz.
A diferença de p99 entre filas foi de apenas 0,059 ms neste par de execuções, sem repetição ou ordem alternada; não há vencedor de desempenho demonstrado.

Não houve falha de device, timeout, fechamento antecipado ou oclusão reportada que invalidasse as execuções.
A aparência dos pixels na tela não foi inspecionada por captura, e este resultado não substitui validação visual de cor/escala.
Após as duas execuções, a checagem confirmou zero tarefas `LightrayLab-*` e zero processos `present_probe` restantes.
Não houve captura de tela ou envio de teclado/mouse.

O comparador `compare-presentation` recalcula os percentis a partir dos CSVs, confere sequência e quantidade de frames, rejeita medidas não finitas/negativas, tempos fisicamente inconsistentes, resultados parciais e resumos divergentes.
Ele exige cargas equivalentes e filas 1/2, registra hashes dos artefatos e deixa explicitamente `winner: null`.
Os 20 testes Python do laboratório passaram no Mac e no Windows, incluindo controles negativos desse comparador.

## Configuração executada

- Janela Win32 de 1280×720, não exclusiva, exibida sem solicitação explícita de ativação.
- Cena sintética de fundo cinza e barra de baixo contraste em movimento; sem captura de desktop, vídeo do host ou input.
- Adapter DXGI 0, D3D11.1, swapchain flip-discard com dois buffers e waitable object.
- Comparação de `SetMaximumFrameLatency(1)` e `(2)`, começando por framebuffer 1920×1080 e 600 chamadas de apresentação por run.
- `Present(1, 0)`, espera antes de cada frame inclusive o primeiro, timeout de espera, processamento de mensagens e interrupção ao fechar a janela.
- Limite interno de 30 segundos e limite do Task Scheduler de 30 segundos; timeout do controlador de 40 segundos para observar término e limpar a tarefa.
- JSON e CSV por execução, sem sobrescrever resultados existentes.

O uso de [GetFrameLatencyWaitableObject](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_3/nf-dxgi1_3-idxgiswapchain2-getframelatencywaitableobject) e [SetMaximumFrameLatency](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_3/nf-dxgi1_3-idxgiswapchain2-setmaximumframelatency) segue a documentação Microsoft.
O runner interativo cria uma tarefa temporária em contexto de usuário, sem senha e sem elevação, e a remove no bloco de limpeza.
Isso permite iniciar na sessão de desktop, pois o SSH deste laboratório usa sessão 0.
A criação, execução e remoção das tarefas interativas funcionaram nas duas rodadas.
Uma consulta de leitura confirmou usuário presente no console e identidade igual à do SSH, sem registrar nomes no artefato.
O console do launcher fica oculto; o probe mostra somente sua janela gráfica explícita.

## Medidas e limites

O CSV registra espera do limite de fila, tempo de submissão CPU, duração da chamada `Present` e intervalo entre conclusões de submissão.
O JSON agrega quantidade, duração total, chamadas por segundo e percentis p50/p95/p99 dos intervalos.
Essas são medidas de submissão e espera, não FPS efetivamente exibido nem input→photon.
O framebuffer pode ser maior que a janela e será escalado: uma configuração 4K não demonstra apresentação física 4K.
Fechamento antecipado, janela reportada como ocluída, falha de device, timeout ou gravação incompleta invalidam o run.
O primeiro par de runs é um smoke de apresentação; capturar eventos de exibição/PresentMon, integrar NV12 do decoder, medir a rede real e fazer testes prolongados continuam pendentes.
Nenhuma fila padrão foi escolhida apenas por este par de amostras.

## Comandos

Compilar e validar sem interface:

```powershell
powershell.exe -NoProfile -File tools/windows/build-platform-probe.ps1 -Presentation
```

Comandos usados após a combinação com o usuário; em novas execuções, usar diretórios novos e combinar outra janela de uso do desktop:

```powershell
powershell.exe -NoProfile -File tools/windows/run-presentation-probe.ps1 -DesktopApproved -Latency 1 -Run presentation-001
powershell.exe -NoProfile -File tools/windows/run-presentation-probe.ps1 -DesktopApproved -Latency 2 -Run presentation-002
```

Sem `-DesktopApproved`, o launcher falha antes de criar diretório de resultados ou registrar tarefa.
O switch registra uma decisão tomada na conversa; não substitui a autorização do usuário.
E03.2 permanece aberto até integrar o decoder e cumprir os demais critérios de comparação, resolução e instrumentação.
