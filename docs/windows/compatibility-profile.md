# Perfil de compatibilidade para o primeiro cliente Windows

Identificador documental: `macos-main-5002116-hardened-1`.
Referência original: commit `5002116872492da705aa6252f26482b02e3df5b5` de `diogoviannaaraujo/lightray`.
Este perfil inclui as correções R01–R04 registradas em [foundation-progress.md](foundation-progress.md), preservando os bytes de mensagens válidas.
O identificador acima não é um novo campo transmitido: a negociação existente continua usando versão 1 e capabilities, sem identificação desta revisão documental no wire.
O cliente deve ser testado contra binários com SHA conhecido, pois o número 1 sozinho não distingue todas as futuras revisões dos payloads provisórios.

Este documento fixa o subconjunto que será implementado primeiro; os layouts completos existentes continuam em [handshake](../handshake.md), [packets](../packets.md), [video](../video.md), [feedback](../feedback.md), [input](../input.md) e nas [extensões provisórias da implementação Mac](../../macos/README.md).
Os documentos que ainda descrevem v0 não significam que o handshake atual deva voltar à versão 0.

## Regras gerais e tipos

- Inteiros multibyte são big-endian; inteiros assinados usam complemento de dois.
- IDs e relógios de 32 bits usam aritmética modular, com diferença interpretada como `Int32`; não usar comparação ordinária ao atravessar wrap.
- Chunks de transporte e TLVs de handshake/controle/frame usam `type:u8, length:u16, value:length bytes`, exceto os TLVs internos do fragmento de mídia, cujo length é `u8`.
- O valor de `length` não inclui o cabeçalho do TLV/chunk.
- Nunca mapear bytes da rede diretamente para uma struct nativa com padding/alinhamento dependente de compilador.
- Autenticar antes de aceitar payload, alterar peer ou registrar packet number como recebido.
- Campos de comprimento precisam caber no buffer antes de ler, converter para tamanho de alocação ou entregar ao codec.
- Um erro no body de um chunk com comprimento válido descarta aquele chunk; comprimento que ultrapassa o pacote interrompe o parsing do restante.
- Tipos de chunk desconhecidos são ignorados pelo receptor atual; não representam capacidades implementadas.

Código de referência: [Bytes.swift](../../macos/Sources/LightrayCore/Wire/Bytes.swift), [Chunks.swift](../../macos/Sources/LightrayCore/Wire/Chunks.swift) e [Packet.swift](../../macos/Sources/LightrayCore/Wire/Packet.swift).

## Handshake e proteção do transporte

| Item | Contrato |
| --- | --- |
| Protocolo Noise | `Noise_NNpsk0_25519_AESGCM_SHA256`, PSK de 32 bytes, efêmeras X25519 de 32 bytes |
| INIT | `0x80, version:u8=1, reserved:u16=0, pairing_id:u64`, seguido de mensagem Noise A |
| Prologue | UTF-8 de `lightray-v1` concatenado com os 12 bytes do cabeçalho INIT |
| Mensagem A | Tokens `psk, e`; payload cifrado `params_length:u16, params, padding`, completando o tamanho proposto de datagrama |
| RESPONSE | `0x81, version:u8=1`, seguido de mensagem Noise B com tokens `e, ee` |
| Payload B | `session_id:u32` não zero, reset token de 16 bytes e TLVs aceitos |
| Derivação | MixHash/MixKey/MixKeyAndHash e HKDF-HMAC-SHA256 conforme o código e vetores Noise; Split produz primeiro client→host e depois host→client |
| AES-GCM | Chave de 256 bits e tag de 16 bytes; nonce de 12 bytes composto por quatro zeros e contador `u64` big-endian |
| DH inválido | Erro de X25519 ou shared value de 32 zeros rejeita a abertura |
| Retransmissão INIT | Mesmo datagrama byte a byte; 100 ms, backoff até 2 s, no máximo oito envios |
| Timestamp | Segundos Unix `u64`; desvio máximo de 30 s na validação de um INIT novo |
| Cache host | Digest do INIT autenticado; RESPONSE idêntica por até 60 s, com limite de 4096 entradas |
| Early packets | Cliente guarda no máximo 64 datagramas do endereço configurado enquanto aguarda RESPONSE, abrindo-os após obter as chaves |

As nonces do handshake pertencem ao estado Noise; as do transporte usam o packet number completo de cada direção, começando em zero após Split.
Nunca reutilizar chaves/contador de transporte entre sessões nem aceitar o valor reservado `2^64 − 1`.
As primitivas devem vir de biblioteca mantida; este perfil não autoriza implementar criptografia própria.

| TLV de handshake | Tipo | Valor e uso inicial |
| --- | --- | --- |
| SETTINGS | 1 | Não utilizado pelo aplicativo atual |
| TIMESTAMP | 2 | `u64`, obrigatório no INIT e proibido na RESPONSE |
| CAPABILITIES | 3 | `u8`; bit 2 (`0x04`) oferece FEC; bit 0 LTR existe no registry, mas não é habilitado pelo aplicativo |
| STREAM_TABLE | 4 | Entradas consecutivas de quatro bytes: `id, kind, direction, class`; obrigatório |
| MAX_DATAGRAM_SIZE | 5 | `u16`, 256–9000; proposta padrão 1200; host aceita o mínimo da proposta e seu limite |
| RESUME_SESSION_ID | 6 | Reconhecido pelo parser, mas não usado por este perfil |
| LIFECYCLE | 7 | Não implementado no caminho atual |

TLVs conhecidos 1–7 duplicados são erro; desconhecidos são ignorados dentro dos limites declarados.
O INIT deve ter exatamente o tamanho proposto, incluindo padding.
A RESPONSE não pode aumentar MTU, aceitar feature não oferecida ou introduzir/alterar entrada de stream proposta.
Os bytes de [vectors.json](../../tools/vectors/vectors.json) e os testes [VectorTests](../../macos/Tests/LightrayCoreTests/VectorTests.swift) são gates obrigatórios para a implementação Windows.

## Pacotes estabelecidos, replay e endereço

Cabeçalho autenticado de 16 bytes: `flags:u8, reserved:3 bytes, session_id:u32, transport_seq:u32, send_time_micros:u32`.
O emissor atual zera os três bytes reservados; o header completo é AAD do AES-GCM.
O datagrama é `header || encrypted_chunks || tag`, com overhead fixo de 32 bytes.
O bit alto de flags distingue esse formato dos pacotes de handshake.

O `transport_seq` são os 32 bits inferiores do packet number de 64 bits.
Reconstruir o número congruente mais próximo do esperado, escolhendo o maior em empate; aplicar janela de replay de 2048 pacotes.
Uma tentativa com autenticação inválida não pode avançar replay, clocks, peer ou estado da sessão.
Diferenças de microssegundos entre clocks de máquinas distintas não medem latência unidirecional.

Mudança de peer exige pacote autenticado estritamente mais novo que todos os aceitos; pacote antigo de outro endereço é descartado.
Porta nova no mesmo IP não ativa o limite adicional de validação; IP novo limita envio a três vezes os bytes recebidos até FEEDBACK reconhecer pacote enviado àquele endereço.
R05 foi corrigido na integração local: `takeOutboundDatagrams()` preserva o destino de cada datagrama, inclusive CLOSE após teardown; o adapter envia ao peer autenticado atual.
`takeOutbox()` permanece somente como compatibilidade para simuladores de rota fixa; novos adapters devem consumir a saída com endereço.
Há teste de mudança de porta/IP e replay; a validação com NAT/interfaces reais fica para o laboratório.

`SESSION_UNKNOWN` é `0x82, version=1, session_id:u32, reset_token:16 bytes`.
O token é `HMAC-SHA256(host_secret, UTF8("lightray-v1 reset") || session_id)[0..<16]`, comparado em tempo constante.
Reset não verificável é ignorado; o timeout normal continua disponível.

## Streams, reliable e feedback

| Stream | Kind | Direction | Class | Semântica |
| --- | --- | --- | --- | --- |
| 0 | DATA 6 | bidirecional 3 | RELIABLE 2 | Controle implícito, ausente da tabela negociada |
| 1 | VIDEO 1 | host→cliente 1 | MEDIA 0 | Primeiro display |
| 4 | INPUT 3 | cliente→host 2 | RELIABLE 2 | Teclado |
| 5 | INPUT 3 | cliente→host 2 | RELIABLE 2 | Ponteiro, botões e scroll |
| 16, 17, … | VIDEO 1 | host→cliente 1 | MEDIA 0 | Displays adicionais |

O cliente propõe quatro streams de vídeo por padrão, limitando a opção a 30; o host atual aceita entradas de vídeo/media e input/reliable, podendo omitir as demais.
IDs devem ser únicos e não zero na tabela negociada; o controle implícito não é uma proposta de stream extra.

| Chunk | Tipo | Observação |
| --- | --- | --- |
| PADDING | `0x00` | Ignorado |
| MEDIA_FRAGMENT | `0x01` | Vídeo remontado conforme a próxima seção |
| RELIABLE | `0x02` | `stream:u8, msg_seq:u32, seg_index:u16, seg_count:u16, payload` |
| DATAGRAM | `0x03` | Somente para classe unreliable negociada; não usado no perfil desktop inicial |
| FEEDBACK | `0x10` | Bitmap de pacotes, deltas de chegada e ACKs de mensagens |
| NACK | `0x11` | `stream:u8`, seguido de ranges de oito bytes |
| FRAME_ACK | `0x12` | Parser existe, mas o transporte atual ignora o conteúdo; não contar como LTR implementado |
| REFRESH_REQUEST | `0x13` | Pedido de recuperação; preferência inicial IDR |
| PING / PONG | `0x30 / 0x31` | ID e, no PONG, hold time para medir RTT |
| CLOSE | `0x34` | Código `u16`; encerra sessão |

Reliable começa em `msg_seq=0`, entrega mensagens completas em ordem, remove duplicatas e retransmite até ACK.
A segmentação usa no máximo `MDS − 32 − 3 − 9` bytes de payload por datagrama.
ACKs são pares `stream:u8, msg_seq:u32` no FEEDBACK, com no máximo 256 entradas por chunk aceito pelo parser.
O emissor atual mantém no máximo 1024 mensagens não confirmadas por stream; recusa deve ser tratada pelo chamador.

FEEDBACK usa bitmap MSB-first e deltas encadeados em unidades de 4 μs; consultar o layout e vetores existentes para cálculo exato e arredondamento.
O agendamento padrão é 20 ms para tráfego que exige feedback, 200 ms no caso ocioso, ACK em até 2 ms e keepalive após 250 ms sem envio.
RTT desconta o hold time informado pelo outro lado; não usar atraso entre clocks independentes como RTT.

Cada range NACK é `frame_id:u32, first:u16, count:u16`; count zero pede o frame inteiro.
Na correção R03, o transporte divide ranges em chunks de no máximo `floor((MDS − 32 − 4) / 8)` entradas e rejeita saída que ultrapasse MDS.
O receptor limita uma consulta a 128 ranges sem marcar os ranges omitidos como enviados; os restantes continuam devidos.

## Vídeo, frame header e configuração

Codec inicial: HEVC Main, 8-bit, 4:2:0, sem B frames/reordenação, SDR.
O payload do frame usa NALs com prefixo de comprimento big-endian de quatro bytes; não contém start codes Annex B.
Uma adaptação para decoder que exige Annex B deve ocorrer na fronteira de mídia, sem alterar o payload do protocolo.

Frame header: `frame_type:u8, ref_kind:u8, flags:u8, config_generation:u32, capture_time_micros:u32`, seguido de `ref_frame_id:u32` somente para LTR, depois `ext_length:u16` e TLVs.
Tipos definidos: IDR=0, predicted=1, audio=2; este perfil implementa os dois primeiros.
Referências definidas: NONE=0, PREVIOUS=1, LTR=2, LTR_ANY=3; este perfil usa NONE para IDR e PREVIOUS para previstos.
CODEC_CONFIG é TLV tipo 1, contendo VPS/SPS/PPS, cada um como `nal_length:u32 + NAL sem start code`.
Um IDR sem configuração é inválido; R02 também rejeita conjuntos vazios.
O adapter Mac agora valida cabeçalhos HEVC de dois bytes e framing antes de chamar VideoToolbox, deixando a validação semântica completa do bitstream para o codec.
Os fixtures pequenos e artificiais dos testes de core não representam bitstreams decodificáveis.

MEDIA_FRAGMENT contém `stream:u8, flags:u8, frame_id:u32, fragment_index:u16, fragment_count:u16, stride:u16, ext_length:u8`, TLVs internos e payload.
Flags são KEYFRAME bit 0, RETRANSMISSION bit 1, FRAME_START bit 2 e PARITY bit 3.
Sem FEC, a extensão é `01 01 00` e o stride é `MDS − 51`.
Count e stride devem ser positivos; dados não finais têm exatamente stride bytes e o último é não vazio com no máximo stride bytes.
O frame só é entregue quando completo e quando sua referência é válida; interromper a cadeia exige recuperação, sem mostrar um previsto sem referência.

## FEC provisório fixado para interoperabilidade

Esquema 1 é Reed–Solomon sistemático sobre GF(256), polinômio `0x11d`, elemento primitivo 2.
A matriz é `G = inverse(V[k,k]) × V[k,k+p]`, com `V[i,j] = α^(i*j)`; as primeiras k colunas são sistemáticas.
Codificar cada offset de byte separadamente; somas são XOR e multiplicações são no campo, não inteiros módulo 256.

Para N fragmentos de dados, usar B=`ceil(N/kMax)` blocos, distribuídos com tamanhos que diferem em no máximo um, os maiores primeiro.
Cada bloco tem p shards de paridade e satisfaz `k+p≤255`.
O último fragmento de dados é preenchido com zeros somente para o cálculo de paridade; seu tamanho original continua no cabeçalho FEC.
Todos os fragmentos daquele frame carregam a mesma extensão `01 05 01 kMax:u8 p:u8 lastLength:u16`, resultando em stride=`MDS−55`.
Exigir `1≤lastLength≤stride` tanto em dados quanto em paridade; valores inconsistentes com o primeiro fragmento do frame são descartados.
Para paridade, fragment_count continua sendo N, fragment_index é `block_index*p + parity_index`, e o payload tem exatamente stride bytes.
Para dados, o último payload deve ter exatamente lastLength bytes.

O envio ordena dados de um bloco antes da sua paridade; a numeração de paridade é separada da numeração de dados.
NACK solicita somente dados, nunca paridade.
Qualquer conjunto de k shards distintos de um bloco permite recuperação; com menos de k, aguardar, retransmitir ou pedir IDR conforme deadline, sem tentar inverter uma matriz insuficiente.
Depois da recuperação, remover somente o padding do último fragmento e aplicar novamente as verificações do frame/codec.

O corpus [fec-reference.json](../../macos/Tests/LightrayCoreTests/Fixtures/fec-reference.json) inclui coeficientes, dados, paridade e último shard preenchido, para códigos (1,1), (3,2) e (7,4).
Foi gerado por [fec_reference.py](../../tools/vectors/fec_reference.py), que usa multiplicação bit a bit e inversão de Vandermonde sem importar o core Swift.
O teste `fecMatchesIndependentFixture` compara coeficientes, encode e recuperação com esses bytes; os testes existentes cobrem padrões de perdas recuperáveis e pedido de retransmissão acima da capacidade.

## Input e controle de displays

Cada input é uma mensagem reliable cujo primeiro byte é o tipo:

| Tipo | Body | Semântica |
| --- | --- | --- |
| KEY `0x01` | `usage:u16, flags:u8` | HID page 0x07; bit 0 down, bit 1 autorepeat |
| POINTER `0x10` | `x:u16, y:u16, display:u32` | Absoluto normalizado 0–65535; display 0 significa primário |
| BUTTON `0x11` | `button:u8, down:u8` | 1 esquerdo, 2 direito, 3 meio, 4 back, 5 forward |
| SCROLL `0x12` | `dx:i16, dy:i16, units:u8` | 0 = 1/120 de notch, 1 = pixels; dy positivo sobe |

O parser mantém compatibilidade com POINTER antigo sem display, interpretando-o como zero; emissor novo sempre deve incluir display.
Motion absoluto pode ser agrupado por até 1 ms; botão/scroll deve respeitar a posição pendente que o antecede.
A correção R04 conserva a posição mais recente sob backpressure e tenta novamente sem busy loop.
Se teclado, botão ou scroll não couberem na fila reliable, a sessão é encerrada com motivo explícito, descarta input local antigo e tenta avisar o host por CLOSE; depois tenta novo handshake.
Se CLOSE for perdido, substituição da sessão ou timeout de silêncio no host aciona reset de teclas/botões; não existe garantia de liberação instantânea quando não há caminho de rede.

Controle usa `msg_type:u8, req_id:u32, scope_stream:u8`, seguido de TLVs.
Tipos são seleção de display=1, resposta=2, estado=3 e lista de displays=`0xF0`; TLV DISPLAY=`0xF0` contém `display_id:u32` e DISPLAY_INFO=`0xF1` contém geometria/nome conforme a referência Mac.
Display IDs pertencem ao host e não são índices de monitor Windows.
O cliente deve usar os pixels da área efetiva do vídeo e DPI local para normalizar coordenadas, sem remapear o ID para um monitor local.

## Limites atuais e recursos que não podem ser anunciados

O host pausa após 2 s de silêncio e expira sessão após 60 s; o cliente reinicia handshake após 5 s sem host e usa retry delay de 1 s.
O encoder aquecido por 300 s é política de recurso do host, não duração garantida da sessão criptográfica.
Novo handshake substitui a sessão existente; PARK/RESUME e retomada de reliable state ainda não estão implementados.
Por isso, a aparente divergência entre preservar reliable state e descartar input ao retomar fica fora deste perfil: não implementar nenhuma das duas como se RESUME já estivesse homologado.

R06 recebeu orçamentos de contabilidade de 256 MiB compartilhados, 64 MiB por receiver de vídeo e 4 MiB por sender/receiver reliable, incluindo estimativa de metadados e no máximo 8.192 segmentos por mensagem.
Reservas acompanham frames entregues; o cache RS tem teto adicional de 1 MiB de coeficientes por instância.
Isso não limita RSS/VRAM; consultar os [limites e evidências](robustness-progress.md).
R07/R08 receberam mailbox de 3 frames/32 MiB/100 ms antes do decode, invalidação de dependentes, epochs e revisão de sessão nos callbacks.
Configuração muda com IDR; callback de decoder cancelado não atualiza a sessão nova.
O input pendente/reliable da sessão anterior é descartado ao encerrar/recomeçar; movimentos absolutos só são coalescidos dentro da sessão ativa.
Key/button/scroll recusados provocam reset de sessão, sem replay desses eventos na sessão seguinte.
O host libera estados pressionados por CLOSE, substituição de sessão ou timeout; isso não é PARK/RESUME.
Bitrate/FEC são fixos por stream; este perfil não promete adaptação WAN, áudio, microfone, LTR ativo, HDR, mouse relativo, texto/IME ou gamepad.
Essas capacidades precisam de contrato e testes próprios antes de serem negociadas ou expostas pela UI.

## Gates de conformidade

1. Compilar e executar vetores e regressões do core sem GUI.
2. Comparar handshake e datagramas válidos byte a byte com a referência.
3. Comparar RS com corpus independente e cenários de perda, inclusive último shard.
4. Decodificar os [streams HEVC de pesquisa](../../tools/windows/reference/) com hashes conferidos pelo [manifesto](evidence/foundation/hevc-corpus.json).
5. Demonstrar input ordenado, reset por saturação e tamanho de datagrama respeitado.
6. Preservar as correções R05–R08 e executar os cenários de migração, limites e ciclo de vida no adapter Windows; testes locais não substituem essa homologação.

O corpus HEVC foi trazido do commit `d38aaade7936660f62bc4b52a230cbd7dc78f2af`; seus streams LTR servem à pesquisa de decoder e não ativam LTR no perfil de produção.
Windows ainda precisa provar estes gates em execução nativa; aprovação no Mac é a referência de interoperabilidade, não sua homologação.
