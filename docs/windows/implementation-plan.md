# Plano de desenvolvimento do cliente Windows

Prioridade de execução atualizada em 29/09/2026: o usuário autorizou avançar primeiro no [host Windows/NVENC](host-implementation-plan.md).
Este plano do cliente permanece preservado; o [relatório NVENC](host-nvenc-progress.md) documenta os resultados do novo escopo separadamente.

Data e baseline: 28/09/2026, `main` em `5002116872492da705aa6252f26482b02e3df5b5`.
Este plano parte da [revisão do projeto](../reviews/2026-09-28/README.md) e deve ser executado junto ao [plano de validação](validation-plan.md).
As caixas marcadas representam trabalho comprovado na revisão e nos incrementos; consultar [fundação](foundation-progress.md), [decode nativo](native-validation-progress.md), [1440p/4K](resolution-validation-progress.md) e [core Swift x64](swift-core-progress.md).
Nenhum marco de produto Windows está aprovado; os experimentos nativos já incluem correção de decode, core Swift x64 e tempos de submissão de apresentação sintética, sem qualificar desempenho fim a fim.
O [relatório consolidado para o desenvolvedor](developer-report-2026-09-29.md) registra resultados, limites, problemas encontrados e a sequência de execução restante.

## Resultado pretendido e limites de cada entrega

O primeiro produto é um cliente desktop nativo Windows x64 que recebe vídeo de um host Mac, apresenta com baixa latência e envia teclado e mouse, preservando a compatibilidade com a implementação existente.
A RTX 4090 é a primeira máquina de laboratório, com validação posterior em outras GPUs para evitar que sua capacidade esconda problemas.
O sistema operacional mínimo será fixado após inventário; a proposta inicial é Windows 11 x64 em builds explicitamente homologadas.
Windows 10, Windows ARM64 e Windows Server não entram por inferência na lista de plataformas suportadas.

| Marco | O que demonstra | O que deve estar concluído |
| --- | --- | --- |
| M0 — revisão e laboratório | Baseline, riscos, acesso e corpus reproduzíveis | E00–E01 |
| M1 — referência confiável | Perfil documentado, correções críticas e decisão de arquitetura | E02–E04 |
| M2 — primeira imagem | Host Mac → cliente Windows, HEVC e apresentação real | E05–E07; primeiro em rede local controlada |
| M3 — alfa desktop LAN | Input, múltiplas janelas, reconexão e diagnóstico utilizáveis | E08–E09; gates LAN da matriz |
| M4 — beta de rede | Recuperação e adaptação verificadas em rede variável | E10 e ensaios de rede/estabilidade de E11 |
| M5 — versão distribuível | Compatibilidade declarada, instalação e evidências completas | E11–E12 |
| M6 — expansão do protocolo | Áudio e outros recursos que exigem mudanças coordenadas no host | E13, em incrementos independentes |

Áudio, microfone, PARK/RESUME, controle por mouse relativo, gamepad, clipboard, transferência de arquivos, HDR e host Windows não são recursos presentes na baseline.
Precisam de trabalho explícito de protocolo, host e cliente; não devem aparecer na interface como capacidades já disponíveis.
M3 pode ser usado como alfa com limitações declaradas, mas não substitui M4/M5 para uso em redes e equipamentos variados.

## Ordem, responsabilidades e disciplina de execução

Fluxo principal: `E00 → E01 → E02 → E03 → E04 → E05 → E06 → E07 → E08 → E09 → E10 → E11 → E12`.
A documentação do perfil e as correções do core podem avançar durante a preparação do laboratório; os ensaios de decoder dependem do Windows nativo.
Cada etapa tem um responsável de implementação e uma evidência de QA, ainda que a mesma pessoa execute ambos em momentos diferentes.
Os papéis abaixo indicam a competência necessária, sem pressupor contratação ou agentes em paralelo.

- Protocolo/core: bytes, estados, criptografia, limites, interoperabilidade e correções da referência Mac.
- Plataforma Windows: build, Winsock, decoder, D3D11/DXGI, input, armazenamento e ciclo de vida.
- Host Mac: captura/encode, instrumentação, input recebido e adaptação de bitrate.
- QA/laboratório: cenários, execução reproduzível, dados brutos, análise de regressão e compatibilidade.
- Produto/entrega: política de suporte, experiência de conexão, distribuição e documentação.

Executar um item por vez, registrar o resultado e só marcar uma caixa quando o critério de saída tiver evidência.
Cada mudança funcional deve ter uma revisão pequena, testes antes/depois e um caminho de reversão por commit ou seleção de backend.
Não misturar mudança de wire format, atualização de dependência e otimização de render no mesmo experimento.
Não há estimativa confiável de prazo total antes dos experimentos E03; depois deles, estimar cada item restante por esforço, dependências e disponibilidade do laboratório.

## E00 — auditoria inicial e baseline

**Entrada:** cópia local e origem Git informada pelo usuário.
**Responsáveis:** protocolo/core e QA.

- [x] E00.1 — Inventariar código, documentação, testes, plataformas e dependências sem ler arquivos de credenciais.
- [x] E00.2 — Conferir os 73 arquivos inventariados contra a origem e fixar o SHA de referência.
- [x] E00.3 — Ler a pesquisa `windows-validation`, identificar fixtures reutilizáveis e separar trabalho de host de trabalho de cliente.
- [x] E00.4 — Executar os 64 testes Mac (59 core e 5 adaptadores), os 11 testes do gerador, o checker de 15 blocos e o build release.
- [x] E00.5 — Reproduzir R01–R05 em diagnóstico isolado e registrar R06–R14 com seus limites de evidência.
- [x] E00.6 — Criar este plano e a matriz de validação com gates por marco.

**Saída:** [relatório](../reviews/2026-09-28/README.md), [logs e probes](../reviews/2026-09-28/evidence/README.md), manifesto e plano.
**Limite:** a auditoria inicial está concluída para a base disponível; homologação Windows e avaliação dinâmica do desktop real permanecem pendentes.

## E01 — checkout rastreável e laboratório

**Entrada:** E00; acesso Windows informado pelo usuário.
**Responsáveis:** plataforma Windows e QA.

- [x] E01.1 — Localizar os aliases de acesso nos documentos do Next GoLev e confirmar a RTX online no Tailscale.
- [x] E01.2 — Confirmar por canal confiável a impressão digital SSH apresentada pelo servidor e autenticar com a configuração existente; não desativar a checagem de identidade.
- [x] E01.3 — Preparar um checkout Git completo de desenvolvimento a partir do SHA auditado, preservando a pasta recebida e seus artefatos de revisão; conferir os diffs antes de incorporar os documentos.
- [ ] E01.4 — Inventariar Windows edition/build, CPU, RAM, GPU/adapters, VRAM, driver, monitores, resoluções/Hz, HDR/VRR, modo de energia, rede e sessão gráfica ativa.
- [x] E01.5 — Inventariar Visual Studio Build Tools, Windows SDK, CMake, Ninja, Git, SDKs de codec e runners existentes; registrar versões e caminhos de ferramentas, sem copiar configurações pessoais.
- [ ] E01.6 — Identificar a rota de dados Mac↔Windows, Ethernet/Wi-Fi, link efetivo, Tailscale direto/DERP e MTU observada; SSH é gerenciamento, não medição do transporte UDP de mídia.
- [x] E01.7 — Separar execução de testes headless via SSH da execução de apresentação/input em sessão Windows interativa; RDP pode alterar o adapter e a topologia, portanto registrar o modo de sessão em cada run.
- [ ] E01.8 — Preparar diretórios de build, fixtures e resultados, com permissões limitadas e rotação dos logs; usar pairings sintéticos nos testes automatizados.
- [ ] E01.9 — Definir uma janela para cargas de GPU e testes que alteram foco/display, evitando interferência em trabalho concorrente; não parar serviços existentes nem mudar driver, energia ou firewall global sem necessidade acordada.

**Entregáveis:** inventário redigido, versões fixadas, instrução de acesso sem segredos, checkout verificável e um smoke de CPU/GPU/decoder.
**Gate:** comando remoto de leitura funciona, build nativo mínimo executa, GPU e sessão gráfica são identificadas e os resultados têm diretório de coleta.
**Situação atual:** identidade SSH confirmada pelo usuário, inventário nativo coletado, decode comparado em 1080p/1440p/4K, core Swift x64 validado e duas rodadas de apresentação sintética concluídas; qualificação do display físico, métricas de mídia integrada e demais gates continuam pendentes, conforme o [relatório consolidado](developer-report-2026-09-29.md).

## E02 — contrato de interoperabilidade e correções da referência

**Entrada:** E00 e checkout E01.3.
**Responsáveis:** protocolo/core, host Mac e QA.

- [x] E02.1 — Escrever o perfil de implementação com SHA da referência, endianness, tipos/tamanhos, enumerações, feature bits, limites, mensagens provisórias e resposta a campos desconhecidos.
- [x] E02.2 — Fixar Noise NNpsk0, transcript, PSK, derivação, nonces, números de pacote/replay, timestamp do handshake, early data, cache/reenvio da RESPONSE e autenticação antes de alterar estado/alocar recursos relevantes.
- [x] E02.3 — Fixar stream 0 de controle, stream 1 de vídeo, 4/5 de input e streams adicionais a partir de 16, incluindo negociação, direção/classe e limites aceitos pela referência.
- [x] E02.4 — Documentar HEVC Main 8-bit 4:2:0, ausência de B frames/reordenação, NALs com prefixo de comprimento de 4 bytes big-endian, VPS/SPS/PPS, frame IDs e regra PREVIOUS/IDR.
- [x] E02.5 — Especificar exatamente o esquema RS, campo finito, matriz, padding, último shard e formato FEC provisório; anexar vetores produzidos independentemente e casos de recuperação impossível.
- [x] E02.6 — Corrigir R01/R02 validando FEC, configuração e NALs antes do decode; transformar os probes em testes de rejeição sem trap.
- [x] E02.7 — Corrigir R03 fazendo todo emissor respeitar o máximo negociado, inclusive NACK/reliable/feedback, e testar unidades e datagramas finais.
- [x] E02.8 — Corrigir R04 com contrato explícito de backpressure, prioridade/garantia de liberação e reset de input; impedir que callbacks ou coalescing apaguem eventos não aceitos.
- [x] E02.9 — Corrigir R06 com orçamento agregado por stream/sessão e limite de metadados/segmentos, sem depender somente de tamanho máximo por frame ou mensagem.
- [x] E02.10 — Corrigir R07/R08 com filas limitadas, geração de sessão/configuração e descarte compatível com referências de vídeo; definir propriedade das filas e callbacks.
- [x] E02.11 — Resolver R05 e as regras de migração de peer, além de melhorar erros de socket e contadores de R09/R11 conforme os ensaios forem introduzidos.
- [x] E02.12 — Separar comportamento hoje executável de PARK/RESUME ainda proposto; resolver preservação versus descarte de reliable input por classe de mensagem, sem anunciar retomada de um RTT inexistente.

**Entregáveis:** perfil versionado, correções pequenas no core/adapter Mac e corpus de regressão compartilhável.
**Testes:** P01–P10 e L01–L04 da matriz, suíte existente integral e encode/decode de referência sem regressão.
**Gate:** R01/R03/R04/R06/R07 resolvidos para os caminhos usados no porte; R02/R08 resolvidos antes do decoder assíncrono; novos testes reproduzem as falhas antes e passam depois.
**Reversão:** correções que alteram o wire exigem perfil/negociação e teste misto; não introduzir incompatibilidade silenciosa para corrigir um problema local de fila ou bounds.

Execução de E02.9–E02.12: [robustez e laboratório](robustness-progress.md), com limites explícitos de memória, apresentação e validação nativa.

## E03 — experimentos de arquitetura com decisão registrada

**Entrada:** acesso nativo e corpus E01; contrato inicial E02.
**Responsáveis:** plataforma Windows e protocolo/core.

Cada experimento deve produzir código descartável pequeno, build reproduzível e resultado medido.
Usar inicialmente até dois dias de engenharia por pergunta; ao atingir o limite sem resposta, registrar a incerteza e decidir a alternativa, sem manter três implementações completas em paralelo.
O limite é de investigação, não uma promessa de prazo de entrega.

| Experimento | Pergunta e trabalho | Critério de decisão |
| --- | --- | --- |
| A — core Swift | Compilar o core em Windows x64, substituir a fronteira CryptoKit de modo controlado, executar vetores e provar chamada a partir do shell nativo | Reutilizar se toolchain/crypto/interop empacotam de forma sustentável e preservam o modelo sans-I/O |
| B — core C++20 | Pequeno parser/handshake com biblioteca criptográfica mantida, confronto de vetores e simulador Swift | Adotar se A falhar ou impuser manutenção maior; não reimplementar primitivas criptográficas |
| C — decoder | Mesmo corpus em Media Foundation e FFmpeg/D3D11VA, mais software como referência | Escolher um padrão e um fallback pelos resultados de correção, disponibilidade, latência, cópias, distribuição e manutenção |
| D — apresentação | D3D11 e swapchain flip, waitable object, máximo de 1 versus 2 frames | Escolher configuração com melhor p95/p99 e regularidade, sem inferir latência só de FPS |

O shell nativo C++20 com Win32, Winsock e D3D11/DXGI é a proposta inicial, sujeita à decisão A/B.
Se A passar, manter um core Swift comum e uma fronteira C/C++ estreita; se B vencer, manter o core C++ como implementação Windows, com testes diferenciais permanentes contra a referência Swift.
Não reescrever o host Mac apenas para uniformizar a linguagem nesta etapa.

O suporte geral de Swift a Windows não prova a combinação de dependências deste projeto: conferir a [plataforma](https://www.swift.org/platform-support/), o [Swift Crypto](https://github.com/apple/swift-crypto) e as [restrições do C++ interop](https://www.swift.org/documentation/cxx-interop/status/), incluindo toolchain compatível com os headers gerados.
Para o decoder, verificar o [MFT HEVC](https://learn.microsoft.com/en-us/windows/win32/medfound/h-265---hevc-video-decoder), a [integração D3D11](https://learn.microsoft.com/en-us/windows/win32/medfound/supporting-direct3d-11-video-decoding-in-media-foundation) e o [backend D3D11VA do FFmpeg](https://www.ffmpeg.org/doxygen/8.1/hwcontext__d3d11va_8c.html).
NVDEC direto fica como experimento posterior, condicionado a ganho relevante; é específico NVIDIA e exige consultar capacidades em runtime conforme o [guia NVDEC](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/nvdec-video-decoder-api-prog-guide/index.html).

- [ ] E03.1 — Executar A e a parte mínima de B necessária para comparar risco, sem portar toda a sessão antecipadamente.
- [ ] E03.2 — Executar C/D em 1080p60, 1440p60 e 4K60, com instrumentação e adaptação correta do bitstream.
- [ ] E03.3 — Validar HEVC indisponível, Windows N e ausência de aceleração; escolher fallback ou erro orientado, sem tela preta silenciosa.
- [ ] E03.4 — Registrar decisão de arquitetura com evidências, custos de distribuição, dependências/versões, limites e gatilhos para reconsiderá-la.

**Gate:** uma escolha de core, um decoder padrão, uma estratégia de fallback e uma configuração inicial de apresentação, todas com smoke nativo aprovado.
**Importante:** a presença de NVENC na RTX não é requisito para o cliente; o caminho relevante é decode e apresentação.

Preparação/execução parcial de C: [três backends de decode 1080p](native-validation-progress.md) e [ampliação para 1440p/4K](resolution-validation-progress.md), com igualdade de pixels nas três resoluções, sem encerrar E03.2 porque apresentação e instrumentação equivalente continuam pendentes.

Experimento A: [80 testes do core e seis casos C++→Swift aprovados nativamente em Windows x64](swift-core-progress.md), usando Swift Crypto em cópia isolada; pacote de runtimes locais também passou, com a DLL mantida durante toda a vida do processo.
ABI completa, teste de distribuição em máquina limpa e decisão final ainda precisam fechar o gate.

Experimento D iniciou: [duas rodadas de apresentação D3D11 concluídas](presentation-probe-progress.md), com 600 submissões por fila e p99 próximo de 17 ms nas duas configurações.
É um smoke sintético em janela, sem medição independente de frames exibidos; integração do decoder, demais resoluções, repetição/ordem alternada e latência continuam pendentes, portanto E03.2 não está encerrado.

## E04 — esqueleto, build, CI e observabilidade

**Entrada:** decisão E03.
**Responsáveis:** plataforma Windows e QA.

- [ ] E04.1 — Criar `windows/` seguindo o padrão de separação por plataforma do repositório; manter core, adaptação Windows, aplicativo e testes separados.
- [ ] E04.2 — Fixar compilador, Windows SDK, dependências e triplet x64; usar CMake presets se C++ for escolhido e um gerenciador com revisões fixadas, sem downloads não verificados em runtime.
- [ ] E04.3 — Criar Debug/Release, símbolos, warnings tratados no código próprio e CTest ou integração equivalente para o core escolhido.
- [ ] E04.4 — Criar CI macOS para referência/vetores e Windows para build, unitários, integração sem GPU e pacote smoke; jobs de hardware ficam identificados à parte.
- [ ] E04.5 — Instrumentar desde o início relógio monotônico, run ID, sessão/geração, stream/frame/packet ID, filas, bytes por classe, drops por causa e motivos de reconexão.
- [ ] E04.6 — Criar saída JSON/CSV com schema versionado, limites de volume, amostragem para eventos de alta frequência e remoção de payloads, PSK, teclas digitadas e endereços pessoais.
- [ ] E04.7 — Criar runner de fixtures e resultados com códigos de saída, timeouts e limpeza de recursos; fixar checksum do corpus da branch de pesquisa.
- [ ] E04.8 — Criar telas/estados mínimos de desconectado, conectando, reproduzindo, recuperando e erro, sem adicionar funcionalidades ainda não suportadas.

**Entregáveis:** build de uma máquina limpa, executável versionado, CI mínima e esquema de resultados descrito no plano de testes.
**Gate:** clone novo compila sem arquivos pessoais; testes retornam falha corretamente; logs identificam a revisão e não contêm dados sensíveis.

## E05 — protocolo e estado independentes da plataforma

**Entrada:** E02/E04.
**Responsáveis:** protocolo/core.

- [ ] E05.1 — Reutilizar ou implementar leitura/escrita limitada por tamanho, com aritmética checada e validação de ranges antes de conversão/alocação.
- [ ] E05.2 — Implementar/reutilizar Noise, transporte AEAD, replay e reconstrução de packet number; usar RNG do sistema e dependência criptográfica verificada.
- [ ] E05.3 — Implementar/reutilizar reliable sender/receiver, segmentação, ACK, timers, feedback, RTT corrigido pelo hold time e mensagens de controle.
- [ ] E05.4 — Implementar/reutilizar reassembly de vídeo, FEC, NACK, dependências PREVIOUS, rate limit de REFRESH e ressincronização em IDR.
- [ ] E05.5 — Aplicar limites agregados e backpressure em todas as filas; separar reset de sessão, reset de stream e troca de configuração.
- [ ] E05.6 — Rodar simulação determinística Mac↔Windows com perda/reordenação/replay/MTU e relógio injetado; comparar eventos e bytes, não apenas retorno de funções.
- [ ] E05.7 — Executar fuzz de parsers e máquinas de estado, corpus de regressão e sanitizers disponíveis para a toolchain escolhida.

**Gate:** 100% dos vetores aplicáveis, casos negativos e simulações selecionadas passam; nenhum datagrama excede o contrato; nenhum input confiável some sem sinalização; consumo permanece limitado sob entradas adversas.
**Dependência crítica:** não usar duas implementações que compartilham o mesmo bug como única prova; manter vetores externos e propriedades independentes.

## E06 — rede Windows, handshake e pairing

**Entrada:** core E05 e esqueleto E04.
**Responsáveis:** plataforma Windows e protocolo/core.

- [ ] E06.1 — Adaptar Winsock UDP com I/O assíncrono, cancelamento e propriedade explícita do socket; observar tamanho aplicado de buffers, erros de envio, mensagens grandes e datagramas truncados.
- [ ] E06.2 — Resolver DNS sem bloquear GUI, tratar IPv4/IPv6 e endereço com porta, mudança de interface, timeout e erro legível; suportar scope de IPv6 quando aplicável.
- [ ] E06.3 — Alimentar os timers do core com relógio monotônico e o handshake com a fonte de tempo exigida pelo contrato; testar saltos de relógio civil separadamente.
- [ ] E06.4 — Importar/validar pairing por entrada protegida, armazenar com proteção por usuário e permitir remover/substituir; nunca exigir token em argumento de processo como único fluxo.
- [ ] E06.5 — Conectar ao host Mac e negociar streams/MTU; registrar capabilities e recusar perfil incompatível com explicação.
- [ ] E06.6 — Aplicar migração de peer validada ao destino de cada envio, preservar anti-replay/limite de amplificação e exercitar reinício do host/SESSION_UNKNOWN.
- [ ] E06.7 — Distinguir erro de rede, credencial, protocolo, ausência de codec e falta de frame; não tratar toda interrupção como problema de GPU.

A proposta de armazenamento é DPAPI no escopo do usuário, sem flag de máquina, respeitando ACL e ciclo de vida do segredo; as garantias e restrições estão em [CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata).
Para I/O, avaliar o modelo de completions conforme [Winsock overlapped I/O](https://learn.microsoft.com/en-us/windows/win32/winsock/overlapped-i-o-and-event-objects-2).

**Gate:** 100 conexões/desconexões sintéticas sem vazamento, autenticação inválida rejeitada, input ainda desabilitado no smoke e pelo menos um stream remontado corretamente entre plataformas.
**Recuperação:** falha de pairing não apaga o token anterior sem confirmação da substituição; falha de rede tem retry limitado/cancelável e estado observável.

## E07 — decode e apresentação de um stream

**Entrada:** E03/E06.
**Responsáveis:** plataforma Windows e QA.

- [ ] E07.1 — Adaptar NAL length-prefixed ao contrato do decoder escolhido, validar comprimentos e associar VPS/SPS/PPS à geração correta; injetar configuração em IDR/reconfiguração conforme necessário.
- [ ] E07.2 — Selecionar adapter/dispositivo explicitamente e confirmar o backend real; expor fallback de software e seu motivo.
- [ ] E07.3 — Compartilhar dispositivo/superfícies com renderizador quando suportado, preservando NV12 na GPU; usar shader de conversão YUV→RGB com range/matriz documentados.
- [ ] E07.4 — Criar swapchain flip e sincronização de apresentação, respeitando latência máxima de frames, refresh, resize, minimização e perda do dispositivo.
- [ ] E07.5 — Limitar fila por bytes, frames e idade; descartar trabalho obsoleto com regra de referência, solicitar IDR quando a cadeia de decode deixa de ser válida e não bloquear a thread de rede.
- [ ] E07.6 — Reportar separadamente complete/decode/submit/display, duração e descartes; nunca chamar decode FPS de FPS exibido.
- [ ] E07.7 — Validar cores, proporção, letterboxing, bordas, textos, mudança de resolução e recovery com fixtures antes de desktop real.
- [ ] E07.8 — Executar pipeline ao vivo Mac→Windows em test pattern, depois conteúdo desktop conhecido, comparando com cliente Mac no mesmo perfil.

**Gate M2:** imagem real estável em 1080p60 por 30 minutos, referência visual correta, memória/filas limitadas, nenhuma exceção de GPU, teardown limpo e logs completos.
**Gate de evolução:** aprovar 1440p60 e 4K60 somente com o orçamento do pipeline medido; 120/144 Hz são capacidades posteriores, não pressupostos da RTX.
**Reversão:** manter seleção explícita do backend aprovado anterior; não fazer fallback silencioso que altera os dados do benchmark.

## E08 — teclado, mouse e interface de conexão

**Entrada:** E02.8/E06/E07.
**Responsáveis:** plataforma Windows, host Mac e QA.

- [ ] E08.1 — Mapear teclado Windows para HID 0x07, incluindo modificadores, teclas estendidas, repetição, Caps Lock, ABNT2/US e diferenças de atalhos Mac/Windows.
- [ ] E08.2 — Definir uma fonte de eventos por dispositivo para evitar duplicação entre mensagens legadas e Raw Input; respeitar foco e atalhos reservados do sistema.
- [ ] E08.3 — Transformar coordenadas físicas/DPI da área efetiva de vídeo em 0–65535 no display remoto correto, incluindo escala, letterbox e bordas.
- [ ] E08.4 — Implementar cinco botões e scroll horizontal/vertical com sinal/unidade compatíveis, sem misturar scroll por pixel com notch.
- [ ] E08.5 — Garantir release/reset em perda de foco, Alt-Tab, minimização, fechamento, captura encerrada e desconexão, inclusive com fila reliable saturada.
- [ ] E08.6 — Oferecer conexão/cancelamento, seleção de display, fullscreen, estatísticas opcionais e forma evidente de liberar o input local.
- [ ] E08.7 — Validar navegação por teclado, escala de fonte e mensagens acessíveis; não capturar teclas fora da sessão ativa.
- [ ] E08.8 — Testar primeiro com host `--log-input` ou coletor sintético, depois numa sessão interativa acordada para não injetar comandos no trabalho do usuário.

Raw Input é uma API candidata, com semântica e registro descritos pela [Microsoft](https://learn.microsoft.com/en-us/windows/win32/inputdev/about-raw-input); scan codes não são automaticamente USB HID usages.
IME/texto Unicode e mouse relativo precisam de especificação adicional, portanto devem ter limitação explícita na primeira versão.

**Gate:** sequência registrada no host corresponde à entrada, nenhum botão/tecla fica preso em 100 ciclos de foco/conexão, coordenadas corretas em todas as escalas testadas e ação de sair da captura funciona.

## E09 — múltiplos displays, reconexão e ciclo de vida

**Entrada:** E07/E08.
**Responsáveis:** plataforma Windows, host Mac e QA.

- [ ] E09.1 — Suportar lista de displays, seleção por janela, dois streams do mesmo display, abertura/fechamento e limite negociado.
- [ ] E09.2 — Isolar budgets e estado de decoder por stream, com teto global de RAM/VRAM e justiça de agendamento; um stream lento não deve bloquear os demais.
- [ ] E09.3 — Testar resolução/Hz/DPI distintos, mover janela entre monitores/adapters, hot-plug remoto/local e fechamento da última janela.
- [ ] E09.4 — Cancelar trabalho e ignorar callbacks de sessão/configuração antiga por geração; não reutilizar superfícies liberadas nem aplicar ACK de decode ao endpoint errado.
- [ ] E09.5 — Exercitar silêncio/reconexão com os tempos da baseline, reaproveitamento do host aquecido, reboot do processo host, pairing revogado e mudança de rede.
- [ ] E09.6 — Tratar suspend/resume, bloqueio/desbloqueio, sessão RDP/console, device removed/reset e indisponibilidade de codec com recuperação limitada e erro verificável.
- [ ] E09.7 — Reiniciar contadores de sessão sem deltas negativos; manter métricas por stream e conexão separadas.

**Gate M3:** dois streams aprovados e quatro condicionados à capacidade declarada, 100 ciclos de reconfiguração, soak LAN de 8 horas, todos os testes de input e nenhuma falha P1 aberta nesse escopo.
**Limite:** reconectar após handshake novo continua diferente de implementar PARK/RESUME.

## E10 — rede variável, congestionamento e recuperação

**Entrada:** M3 e instrumentação de host/cliente.
**Responsáveis:** protocolo/core, host Mac e QA.

- [ ] E10.1 — Medir baseline de perda/RTT/jitter/limites de enlace e comportamento atual de FEC/NACK/IDR, sem chamar taxa fixa de adaptação.
- [ ] E10.2 — Definir feedback necessário para controle e o contrato entre receptor/controlador/encoder, preservando compatibilidade ou negociando capacidade nova.
- [ ] E10.3 — Implementar orçamento agregado por conexão para mídia, paridade e retransmissão, mais prioridades/pesos dos streams; evitar multiplicar a taxa pela quantidade de janelas sem limite global.
- [ ] E10.4 — Implementar adaptação conservadora de bitrate, pacing e circuit breaker com tempo máximo de fila; evitar que backlog cause aceleração ilimitada.
- [ ] E10.5 — Limitar retransmissão pela utilidade/deadline do frame e recuperação por IDR por rate limit; avaliar FEC fixo versus adaptativo sob bursts e overhead real.
- [ ] E10.6 — Testar oscilação de banda, perda assimétrica, ACK retido, mudança de porta/IP, MTU reduzida, blackhole e rota Tailscale direta/DERP.
- [ ] E10.7 — Verificar fairness entre streams, consumo do link e recuperação após congestionamento, mantendo input utilizável.

**Gate M4:** convergência e recovery dentro das metas provisórias da matriz, sem crescimento ilimitado de latência/memória, sem tempestade de retransmissão e com qualidade reduzida de maneira observável quando o link não sustenta o perfil.
**Dependência:** esta etapa exige mudanças no host; não pode ser concluída apenas no cliente Windows.

## E11 — desempenho, segurança, estabilidade e compatibilidade

**Entrada:** M3 para campanha LAN; M4 para campanha de rede final.
**Responsáveis:** QA com suporte dos implementadores.

- [ ] E11.1 — Executar a campanha limitada da matriz, coletando resultados brutos e mediana/p95/p99 adequados ao tamanho de amostra.
- [ ] E11.2 — Comparar client Mac e Windows com a mesma origem/configuração, identificando custo do host, rede e endpoint em vez de atribuir tudo à GPU.
- [ ] E11.3 — Medir latência óptica/input→photon e comparar com spans locais; registrar incerteza e instrumento.
- [ ] E11.4 — Perfilar CPU/GPU/VRAM/cópias/filas/frame pacing e corrigir apenas gargalos demonstrados; repetir células afetadas após a mudança.
- [ ] E11.5 — Rodar soak de 8 h e 24 h, estendendo a 72 h no candidato de release com ambiente reservado; incluir wrap de timestamp e muitos ciclos de sessão.
- [ ] E11.6 — Fazer fuzz/ASan e ensaios de budgets, autenticação/replay, metadados corrompidos, dependências e proteção do pairing; dumps e capturas de rede usam dados sintéticos.
- [ ] E11.7 — Validar Intel/AMD e equipamento de menor capacidade, além da RTX; hardware indisponível permanece como lacuna, sem selo de compatibilidade por extrapolação.
- [ ] E11.8 — Fixar builds Windows, drivers e perfis aprovados, limites conhecidos e resultados não aprovados; regressões devem apontar o primeiro commit e a célula afetada.

**Gate:** matriz obrigatória aprovada, zero crashes/hangs/OOM/teclas presas, nenhuma falha P1/P2 relevante ao escopo declarado sem resolução, relatórios reproduzíveis e exceções de recursos explicitamente fora da versão.
**Reversão:** restaurar a implementação/backend anterior se a correção aumentar latência ou quebrar compatibilidade; atualizar o relatório ao reduzir escopo, sem transformar falha em aprovação.

## E12 — empacotamento, piloto e entrega

**Entrada:** candidato M5 tecnicamente aprovado em E11.
**Responsáveis:** plataforma Windows, QA e produto/entrega.

- [ ] E12.1 — Definir portable/instalador, runtime dependencies, escopo por usuário, versão e diretórios, sem exigir administrador para operar o cliente.
- [ ] E12.2 — Revisar licenças da origem e das dependências e condições de redistribuição de codecs; a árvore original sem LICENSE exige esclarecimento antes de publicar binários.
- [ ] E12.3 — Gerar checksums, símbolos privados, inventário de dependências e artefatos reproduzíveis; integrar assinatura quando certificado/fluxo estiver disponível.
- [ ] E12.4 — Testar instalação limpa, usuário sem privilégios, atualização N−1→N, rollback, desinstalação, paths Unicode/espaços e preservação/remoção explícita dos pairings.
- [ ] E12.5 — Documentar pareamento, diagnóstico de rede/codec, estatísticas, suporte, limites e como exportar relatório sem dados sensíveis.
- [ ] E12.6 — Executar piloto em máquina limpa e uso real com aceite baseado na matriz; registrar bugs com run ID e revisão.
- [ ] E12.7 — Preparar notas da versão e pacote final para revisão; publicação externa é uma ação separada do preparo do artefato.

**Gate M5:** instalação/rollback verificados, documentação reproduzível por outra pessoa, política de suporte explícita, artefato identificado por hash e matriz assinada com evidência.
**Entrega não inclui:** atualização automática ainda não projetada, telemetria enviada sem acordo ou alegação de compatibilidade universal.

## E13 — evolução após a primeira versão validada

**Entrada:** M5 ou incremento especificamente priorizado; host e wire format precisam acompanhar.

| Incremento | Trabalho coordenado | Validação adicional |
| --- | --- | --- |
| Áudio de saída | Captura host, formato/Opus, transporte, jitter buffer, WASAPI, volume e mute | Latência, drift, lip-sync, troca de dispositivo, underruns, 8 h de A/V |
| Microfone | Consentimento e estado visível, captura cliente, transporte e dispositivo/entrega no host | Echo, mute real, hot-plug, desconexão e recursos liberados |
| PARK/RESUME | Identidade/chaves, reliable state por classe, input reset e takeover | Suspensão longa, expiração, replay, reenvio e ausência de input antigo |
| Mouse relativo/gamepad/texto | Novas mensagens/capabilities e injeção correspondente no host | Jogos, IME, Unicode, layouts, alto polling e hot-plug |
| HDR/10-bit/novos codecs | Negociação, metadata, encode/decode, superfícies e output | Cores, tone mapping, monitores SDR/HDR e capacidade real por adapter |
| Host Windows | Captura, NVENC ou outro encoder, injeção e ciclo de vida | Plano próprio; aproveitar o brief `windows-validation` sem confundi-lo com cliente |

## Registro de decisão e execução

Para cada item, registrar `ID`, status (`pendente`, `em execução`, `aprovado`, `reprovado`, `bloqueado externamente`), SHA, comando/cenário, ambiente, resultado, evidência e próximo passo.
Status atual: E00, E01.1/E01.3 e E02.1–E02.8 concluídos no escopo local; corpus local de E01.8 preparado; E01.2 ainda depende da identidade SSH, e E02.9 em diante permanece pendente.
Enquanto o acesso é concluído, os próximos trabalhos locais independentes são os budgets de E02.9, o ciclo de vida de E02.10 e a integração de peer/diagnóstico de E02.11.
O primeiro trabalho dependente da RTX será o inventário E01.4–E01.7 e o smoke de decoder de E03, sem carga longa ou mudanças globais na máquina.
