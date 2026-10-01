# Robustez e preparação do laboratório — 28/09/2026

Atualização posterior: o bloqueio SSH foi resolvido e os primeiros ensaios nativos passaram; consultar a [validação Windows](native-validation-progress.md).

Estado histórico deste incremento: segundo incremento local da referência concluído; E02 fechado no escopo de protocolo/adaptadores exercitado pelos testes.
E01 continua pendente no acesso nativo; E03 ainda não tem decisão de arquitetura ou medição Windows.
Checkout: `/Users/vhccruz/Dev/lightray`, branch `codex/windows-foundation`, base `5002116872492da705aa6252f26482b02e3df5b5`.
Alterações locais, sem commit ou publicação; o [primeiro incremento](foundation-progress.md) preserva o histórico anterior.

## Alterações e evidências

| Item | Resultado | Evidência |
| --- | --- | --- |
| E02.9 / R06 | Orçamento agregado de buffers/metadata, limites por stream e propriedade das reservas até liberação dos frames | `MemoryTests`: concorrência/rollback, fragmentos incompletos, segmentos inválidos, saturação entre streams, entrega fora de ordem e liberação após ACK |
| E02.10 / R07 | Mailbox de decode limitado a 3 frames incluindo o ativo, 32 MiB codificados e idade de espera de 100 ms | `DecodeQueueTests`: saturação por 1.000 frames, limite de bytes, expiração e recuperação por IDR |
| E02.10 / R08 | Epoch de configuração/cancelamento e revisão de sessão nos callbacks; cancelamento imediato do trabalho pendente | Tests de ticket/epoch e worker real com decode bloqueado, 500 submissões e cancelamento sem callback obsoleto |
| E02.11 / R05 | Outbox com destino por datagrama; adapter envia ao peer autenticado atual e preserva destino de CLOSE após teardown | Simulação de mudança de porta e IP, replay do endereço anterior e envio de encerramento |
| E02.11 / R09 | Contadores reiniciados na reconexão e troca de decoder; UI identifica `decoded fps` e `connection Mb/s` | Build integral e inspeção dos pontos de reset; FPS efetivamente apresentado continua pendente |
| E02.11 / R11 | Opções recusadas/buffers efetivos observáveis; nonblocking obrigatório; erros de send/receive, lote de leitura limitado e close idempotente | UDP IPv4/IPv6 real em loopback, datagrama excessivo, envio após close, reutilização de descriptor e close dentro do callback |
| E02.12 | Política de sessão nova e descarte de input antigo explicitada, sem implementar PARK/RESUME | [Perfil atualizado](compatibility-profile.md) e regressões de overflow/reconexão já existentes |
| Preparação E01/E03/E04 | Runner de corpus, inventário SSH somente de leitura e referência FFmpeg com hashes | [Ferramentas](../../tools/windows/README.md), seis testes Python e 360 frames decodificados |

## Limites de memória e propriedade

`Connection.memoryBudget` limita a 256 MiB a contabilidade compartilhada pelos senders/receivers reliable e pelos receivers de vídeo do cliente.
Cada receiver de vídeo possui orçamento de 64 MiB; cada sender/receiver reliable possui orçamento de 4 MiB.
O limite por mensagem reliable permanece 1 MiB e passa a incluir no máximo 8.192 segmentos; mensagens futuras preservam espaço local para preencher o gap de ordenação.
Reservas de vídeo cobrem duas vezes os buffers de dados/paridade e uma estimativa de metadados, antes de alocar; acompanham `DeliveredFrame` durante a passagem para outra fila.
O cache de coeficientes RS possui limite separado de 1 MiB de coeficientes por instância.
O limite de 32 MiB por frame continua sendo teto de entrada, não garantia de aceitação: overhead e memória já ocupada podem fazer o orçamento recusar um frame menor.

Esses números são limites de contabilidade de buffers retidos, não de RSS/commit do processo.
Alocador, overhead de objetos, buffers temporários de criptografia, filas de eventos/outbox já entregues ao chamador, cache RS, surfaces do codec e GPU têm custos adicionais.
O chamador sans-I/O precisa continuar drenando eventos e outbox; os aplicativos existentes fazem isso em cada pump.
Medir RSS/commit/VRAM e high-water no Windows continua obrigatório nos ensaios longos.
A saturação do vídeo é contabilizada em `memoryLimitDrops`; o transporte não cria um buffer de espera ilimitado para contornar o limite.

## Decoder e ciclo de vida

O core/endpoint continua pertencendo à fila de rede; janela e estado da UI pertencem à main; cada decoder tem uma fila serial.
A mailbox usa lock próprio e o worker mantém somente uma tarefa de drain agendada, cedendo a fila entre frames para anexação/cancelamento.
Um IDR substitui referências pendentes; overflow, expiração, mudança de configuração sem IDR e falha de decode descartam dependentes e exigem keyframe.
O frame que já está em uma chamada de decoder não pode ser interrompido à força: permanece contabilizado até retornar, mas o resultado de epoch cancelada é ignorado.
O cancelamento não segura o lock enquanto chama callbacks de aplicação.
A UI também verifica revisão/epoch antes de aplicar tamanho, criar janela atrasada ou reservar snapshot.

Os 100 ms limitam a idade antes do início de decode; não são um SLA de latência de decoder ou apresentação.
Nenhum teste deste incremento comprova cancelamento de chamada nativa travada, render em monitor real ou ausência de diferenças visuais sob reconexão.
A fila da apresentação e as surfaces de VideoToolbox/D3D são estágios distintos, a validar em E07/E08/E10.

## Verificações executadas

- Baseline antes deste incremento: 75 testes Swift, dos quais 68 core e 7 Mac.
- Suíte final: 90 testes Swift, dos quais 80 core e 10 Mac; casos parametrizados incluem mudança de porta e IP, perda, reordenação, stall, FEC e reconexão.
- Build release completo de host e cliente Mac aprovado.
- Nove testes direcionados de concorrência/cancelamento/socket passaram com Thread Sanitizer, sem diagnóstico de data race nos caminhos exercitados.
- Checker documental: 15 blocos e zero problemas; fixture FEC independente conferida; 73 arquivos da baseline original preservados.
- Seis testes Python do laboratório aprovados, incluindo checksums, paths inválidos, SSH estrito, timeout, falhas de autenticação, JSON inválido e inventário parcial.
- Três clips auditados decodificados por FFmpeg 8.0.1 em software: 120 frames por clip, 360 no total, HEVC Main 1920×1080 yuv420p, sem erro reportado pelo decoder.
- Hashes SHA-256 por frame preservados para comparação; não houve comparação visual independente ou simulação de perda nesses clips.

Logs e resultados: [índice de evidências](evidence/robustness/README.md).
As execuções têm timestamps UTC; parte aparece como 29/09/2026 UTC e corresponde à noite de 28/09/2026 em São Paulo.

## Bloqueio e sequência seguinte

O acesso por `rtx4090`, identidades antigas documentadas e SSH via Tailscale não conseguiu estabelecer uma identidade SSH já confiável neste Mac.
O runner registrou `ssh_host_identity_unverified` antes de executar o inventário; não houve acesso ao Windows ou alteração remota.
A impressão pública apresentada anteriormente foi `SHA256:6MxQ4n1D/xVkqrLd1SN0FT5xdcS7XWwaR7R81qPqAgU`, ainda pendente de confirmação por canal confiável.

Quando a identidade estiver estabelecida, executar o inventário e validar o próprio script PowerShell, completar toolchain/rota/sessão gráfica em E01, então executar os experimentos E03 A/B/C/D com o corpus já verificado.
A referência de software não decide entre Swift/C++, Media Foundation/FFmpeg ou apresentação D3D11.
E04–E12 dependem dessas decisões e dos gates nativos; não foram marcados completos com resultados locais.
Compatibilidade Windows N, fallback, 1440p/4K, FPS físico, latência, foco/input e estabilidade 8/24/72 h continuam sem medição.
