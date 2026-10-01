# Host Windows: plano de implementação e gates

Prioridade atualizada em 29/09/2026: desenvolver o host Windows nativo com encoder NVIDIA NVENC, usando a `main` como referência.
O trabalho do cliente permanece preservado; seu plano e o PDF entregue antes desta mudança continuam sendo registros da campanha do cliente.
Marco funcional posterior em 29/09/2026: [desktop Windows visível e controlável pelo cliente Mac](host-desktop-progress.md), com NVENC nativo, relógio real, clique, teclado, modificadores e rolagem confirmados na LAN.
Este marco antecipa partes de H03–H06, sem concluir os gates de qualificação dessas etapas.
A consulta remota da `main` nesta etapa retornou `5002116872492da705aa6252f26482b02e3df5b5`, sem diferença em relação à base auditada.
As correções locais de robustez continuam aplicáveis e não devem ser perdidas ao criar o adapter host.

## Arquitetura candidata

- Captura e conversão: D3D11 por display, inicialmente SDR, mantendo superfícies na GPU e registrando a correspondência entre adapter e output físico.
- Encoder: API NVENC nativa da NVIDIA, HEVC Main 8-bit 4:2:0, sem B frames/lookahead, IDR no começo e sob solicitação de recuperação; não depender de processo FFmpeg para encoding.
- Core: reutilizar `HostEndpoint`, `VideoSender`, criptografia e transporte sans-I/O do projeto por uma ABI C explícita; a experiência Swift x64 anterior é uma candidata, ainda sujeita aos gates de toolchain/ownership.
- Transporte: adapter Winsock com endereço por datagrama, relógio monotônico, timers, limites e erros explícitos, seguindo a referência Mac.
- Input: adapter Windows separado, inicialmente desativado no laboratório; habilitação e testes somente na sessão de uso combinada.
- FFmpeg/ffprobe: ferramentas de validação offline e oráculo de decode, sem responsabilidade de encoder ou captura do host.

O header NVENC fixado em `tools/windows/vendor/nv-codec-headers/` é a interface C da NVIDIA com aviso de licença preservado; a implementação do encoder vem do driver instalado, por `nvEncodeAPI64.dll` carregada de System32.
Não há fallback silencioso para software.
Quick Sync e outros encoders ficam para uma etapa de compatibilidade em hardware que os ofereça; não são pressupostos para a primeira entrega na RTX 4090.

## H00: referência, ambiente e teste mínimo do encoder

- [x] Conferir a revisão atual da `main`, preservar alterações locais e revisar `HostApp`, `Pipeline`, `VideoEncoder`, `HostEndpoint` e `VideoSender`.
- [x] Confirmar Windows nativo, RTX 4090, driver e presença da biblioteca NVENC, sem alterar drivers ou serviços.
- [x] Compilar probe C++20 com MSVC `/W4 /WX /O2`, abrir sessão NVENC/D3D11 sem fallback e codificar estímulo sintético nas três resoluções.
- [x] Exigir 120 frames por clip, timestamps em ordem, IDR nos índices 0/60, ausência de B frames e VPS/SPS/PPS nos IDRs.
- [x] Converter Annex B para NALs com comprimento big-endian de quatro bytes e conferir configuração de codec separada.
- [x] Comparar decode dos mesmos bitstreams no Mac e Windows; conferir que reconstruir Annex B a partir dos payloads preserva os pixels.
- [x] Recusar adapter inexistente, dimensões fora da matriz e sobrescrita de resultado; verificar término dos processos.

Resultado e limites: [primeira campanha NVENC](host-nvenc-progress.md).
H00 não entrega captura de desktop, socket, input ou cliente conectado.

## H01: fronteira de mídia e ciclo de vida do encoder

Transformar as partes verificadas do probe em um componente que recebe superfícies D3D11 e entrega `EncodedFrame`, separado de arquivos, CLI e padrões sintéticos.
Definir pool limitado de texturas/bitstreams, ownership das superfícies e sincronização de upload/captura/encode; medir waits antes de escolher execução síncrona ou assíncrona.
Modelar create, encode, requestIDR, pause, reconfigure, drain e destroy, com erros explícitos e sem callbacks após encerrar uma geração.
Repetir pelo menos 100 ciclos create/close e transições de resolução; usar contador de recursos antes/depois, sem supor que memória retida pelo driver seja vazamento.
Testar ausência de driver/API incompatível, rejeição de device e falhas de inicialização sem fallback disfarçado.
Gate: bitstreams corretos, IDR com nova configuração após mudanças, teardown determinístico e recursos limitados.
Implementação inicial concluída: [componente NVENC e campanha de lifecycle](host-live-progress.md), com textura própria, bitstream único, gerações, pausa/retomada e reconfiguração por recriação.
Duas rodadas de 100 ciclos medidos passaram após 30 ciclos completos de aquecimento, preservando o custo inicial de memória e as rodadas anteriores reprovadas.
Falhas de driver/device, profiling do aquecimento e estabilidade prolongada ainda impedem considerar H01 inteiramente qualificada.

## H02: ABI do core e ferramentas de build

Expor handles opacos de host/sessão, entrada de datagrama com peer, tick/nextWakeup, entrega de frame e drenagem de eventos/datagramas.
Buffers cruzam a fronteira com tamanho explícito; o chamador não libera memória alocada pelo outro runtime sem uma API própria.
Serializar mutações do endpoint em uma fila, identificar gerações para impedir retorno de frame/input à sessão substituída e traduzir falhas para códigos estáveis.
Manter a DLL Swift pelo tempo de vida do processo até resolver o bloqueio de unload observado; fechar sessões por APIs explícitas.
Resolver a descoberta vazia de testes Release no motor padrão ou fixar uma alternativa sustentável antes do CI de produto; o motor `native` depreciado permanece apenas contorno de laboratório.
Gate: vetores públicos, pelo menos os 80 testes atuais do core em Debug/Release, testes ABI de ponteiros/tamanhos/erros e create/close repetidos com processo encerrando normalmente.

Incremento implementado em 29/09/2026: [ponte C experimental e ensaio autenticado](host-bridge-progress.md), com oito testes adicionais e reprodução do corpus NVENC através da ABI real no Windows.
A API inclui geração de sessão/pausa, limites de buffers/filas e encerramento explícito; o motor Release sustentável e o contrato final de distribuição permanecem pendentes.
Essa integração antecipada de H02 não conclui H01: os ciclos de handles do core não equivalem a ciclos de criação/reconfiguração do encoder.

## H03: Winsock e sessão autenticada

Implementar socket não bloqueante, IPv4/IPv6, relógio monotônico, timers e drenagem limitada, sem reimplementar Noise ou criar um protocolo paralelo.
Inicialmente usar loopback e um peer de laboratório; depois exercitar Mac↔Windows no caminho Tailscale/LAN autorizado.
Preservar o destino fornecido pelo core, MTU negociada, autenticação antes de rebinding, replay e CLOSE após teardown.
PSK de uso real não pode ir em log ou argumento visível de processo; definir armazenamento/pairing antes do uso fora do laboratório.
Não alterar firewall global nem expor listeners de teste sem delimitar interface, porta e ciclo de vida.
Gate: conexão fria/aquecida em 30 tentativas cada, rejeição de autenticação inválida, perda/reenvio de handshake, MTU e reconnect medidos no caminho real.
Incremento funcional: sockets IPv4 loopback reais com bind exclusivo, sete casos de adapter e três sessões autenticadas por campanha, usando relógio do core ainda simulado.
O host de desktop acrescentou scheduler real, fila de saída limitada com retry de `WSAEWOULDBLOCK` e caminho Windows→Mac pela LAN; IPv6, campanhas negativas, perda/MTU e 30 tentativas frias/aquecidas permanecem pendentes.

## H04: host sintético integrado

Conectar padrão sintético→NVENC→EncodedFrame→HostEndpoint→Winsock→cliente Mac.
Reusar a seleção/lista de displays e `keyframeNeeded` da referência; introduzir display sintético explícito para separar a integração de rede das permissões de captura.
Respeitar a parcela de bitrate reservada ao FEC: `encoderBitrate = bitrate * 100 / (100 + fecPercent)`, como `HostOptions` na `main`.
O bitrate de 20/40 Mb/s no probe atual é apenas do encoder e não inclui proteção, cabeçalhos ou transporte.
Incremento funcional: NVENC ao vivo → ABI C → UDP loopback → peer autenticado entregou 360 frames íntegros em três resoluções, sem decoder/display, em relógio simulado.
A cadência real de 30 FPS e a resposta aos pedidos de IDR foram integradas no host de desktop; o gate sintético 1080p60/30 minutos continua pendente.
Gate: um stream 1080p60 por 30 minutos, integridade de configuração/frame IDs, queue age/bytes limitados, nenhum backlog crescente e recuperação por IDR; a apresentação visível exige combinar o uso da sessão.

## H05: captura real do desktop

Avaliar Desktop Duplication como primeiro caminho D3D11 e registrar um motivo verificável se Windows Graphics Capture for necessário.
Mapear output físico ao adapter de encoding, tratar rotação, cursor, DPI, resize, bloqueio de sessão, retorno ao desktop e perda do device.
A API Desktop Duplication entrega superfícies BGRA; converter para NV12 na GPU com range e matriz de cor explícitos, comparando com estímulos conhecidos antes de testar a área de trabalho do usuário.
Evitar readback de cada frame no caminho de produto; o hashing GPU→CPU pertence à validação.
Gate: capture timestamps coerentes, pixels/escala/cursor corretos e recuperação após mudança de display sem frame antigo reaparecer.
Combinar previamente a captura do desktop; não armazenar conteúdo pessoal nos artefatos de laboratório.

## H06: input, foco e múltiplos displays

Implementar o mapeamento do input recebido para Windows, incluindo teclas, botões, scroll, posição absoluta e display de origem; começar com modo de contagem sem injeção.
Tratar limites de integridade/UIPI e falha de `SendInput` explicitamente, sem elevar o processo como contorno automático.
Preservar liberação de teclas/botões em CLOSE, timeout, pause e substituição de sessão, sem replay de input antigo.
Gate: zero tecla/botão preso, nenhuma aplicação em sessão/display errado, posição correta sob DPI diferente e Alt-tab/reconnect; combinar foco/input antes dessas execuções.

## H07: desempenho, rede e estabilidade

Instrumentar captura, espera por textura, conversão, envio ao encoder, bitstream pronto, packetização, filas, rede, decode e display por frame ID.
Medir tempos locais com o mesmo relógio; medir input→photon separadamente com instrumento apropriado, sem somar percentis.
Comparar presets NVENC em ordem alternada, com mesma cena/bitrate/resolução, repetições, warm-up e avaliação de qualidade; P1/ULL atual é configuração inicial de laboratório, não vencedor comprovado.
Executar a matriz de FPS, latência, conexão, perda/jitter/reordenação, FEC, MTU, congestionamento, CPU/GPU/RAM/VRAM e estabilidade do [plano de validação](validation-plan.md), ajustando emissor/receptor para Windows→Mac.
Estabilidade progride em 30 min, 8 h, 24 h e 72 h reservadas; intercalar cena estática/dinâmica e ciclos de sessão/resolução.
Gate: critérios congelados antes da campanha, ausência de falhas/vazamentos e regressões investigadas; 4K60 só pode ser anunciado após captura/rede/display sustentados.

## H08: compatibilidade e distribuição

Qualificar outras GPUs NVIDIA e drivers antes de generalizar o resultado da 4090; documentar comportamento sem NVENC e em desktop remoto/sessão bloqueada.
Avaliar Intel Quick Sync como backend separado quando houver hardware e demanda, usando exatamente os mesmos oráculos de bytes, pixels e ciclo de vida.
Resolver licenças/runtime Swift, instalação sem toolchain, assinatura, configuração de acesso e atualização/remoção.
Gate: instalação limpa com usuário comum, diagnóstico acionável de dependências, pacote reproduzível e piloto com rollback.

## Fontes técnicas e estado da decisão

- [NVENC Programming Guide](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-video-encoder-api-prog-guide/): sessão DirectX, presets, encode/lock e gerenciamento de recursos.
- [Desktop Duplication API](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api): superfícies do desktop, alterações e tratamento do output.
- [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput): injeção e limites de integridade.

A prioridade NVENC foi adotada após autorização do usuário; nenhuma conclusão do relatório anterior é reclassificada retroativamente como teste de host.
A próxima unidade de implementação é trocar o relógio simulado por scheduler real, encaminhar eventos de recuperação ao encoder e validar o fluxo sintético contínuo; os gates pendentes de H01/H02/H03 permanecem explícitos, e captura real/input seguem os limites de uso combinados.
