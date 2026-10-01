# Lightray: relatório técnico do cliente Windows

## 1. Parecer executivo e estado da entrega

**Data de corte: 29/09/2026. Campanha: 28 e 29/09/2026. Destinatário: desenvolvimento.**

A implementação existente oferece uma base reutilizável para o cliente Windows, e os experimentos executados na RTX 4090 demonstraram viabilidade do core Swift x64, correção de decode HEVC até 4K e funcionamento inicial da apresentação D3D11.
Ainda não existe, neste trabalho, um cliente Windows integrado que receba vídeo do host Mac pela rede, apresente esse vídeo e envie input.
A recomendação é avançar para essa integração preservando os testes e limites já estabelecidos, sem encerrar a decisão de arquitetura com base somente nos probes.

| Área | Evidência obtida | Estado de qualificação |
| --- | --- | --- |
| Referência Mac | 90 testes Swift; build Release; 9 casos com Thread Sanitizer | Correções locais verificadas |
| Core Windows x64 | 80 testes Debug e 80 Release; 6 casos de ABI C | Viável, com contornos de toolchain e ciclo de vida |
| Decode Windows | 3 backends; 1080p, 1440p e 4K; zero divergência de pixels | Correção dos clips testados |
| Apresentação | 2 execuções de 600 submissões; cerca de 10 s cada | Smoke sintético aprovado |
| Rede e input reais | Sem sessão integrada Mac→Windows nesta campanha | Pendente |
| FPS exibido, latência e estabilidade longa | Não medidos no cliente integrado | Pendente |
| Distribuição e outras GPUs | Pacote experimental; sem máquina limpa | Pendente |

**Base de código:** repositório `https://github.com/diogoviannaaraujo/lightray.git`, commit `5002116872492da705aa6252f26482b02e3df5b5`, branch local `codex/windows-foundation`.
As correções, ferramentas e documentos desta campanha estão em alterações locais não commitadas; baixar somente esse commit do GitHub não reproduz o trabalho novo.
O pacote de repasse inclui um patch de código, os documentos/evidências e os clips sintéticos preservados; não é uma versão instalável.

Os números deste relatório são resultados observados quando identificados como tal.
As metas das seções 8 e 9 são critérios propostos para trabalho futuro e não devem ser apresentados como resultados alcançados.
Os logs antigos de bloqueio SSH e preparação de GUI foram preservados como histórico; o acesso e as duas execuções gráficas posteriores foram concluídos.

**Leitura sugerida:** seções 4 a 7 para analisar os resultados Windows; seções 8 a 10 para executar e reproduzir os próximos incrementos.

## 2. Ambiente, ferramentas e condições dos ensaios

| Componente | Ambiente observado |
| --- | --- |
| Sistema | Windows 11 Home x64, build 26200 |
| CPU e memória | Intel Core i7-12700KF, 12 núcleos/20 threads, aproximadamente 64 GiB RAM |
| GPU | NVIDIA GeForce RTX 4090; 24.564 MiB reportados pelo NVIDIA |
| Driver | NVIDIA 591.86 |
| Compilador nativo | VS Build Tools 2022 17.14.37614.0; MSVC 14.44.35207 |
| SDK | Windows SDK 10.0.26100.0 |
| Ferramentas de build | CMake 3.31.6-msvc6; Ninja 1.12.1; Swift 6.4.0 x64 |
| Shell | Windows PowerShell 5.1.26100.9444 |
| Decoder de laboratório | FFmpeg 8.1-essentials_build-www.gyan.dev no Windows; 8.0.1 no Mac |
| Rede observada | Ethernet Realtek 1 Gbps ativa; Tailscale disponível |

O acesso foi feito por SSH sobre Tailscale, com identidade do servidor conferida por impressão digital confirmada pelo proprietário e checagem estrita mantida.
Não se alteraram drivers, firewall, serviços ou plano de energia.
O Swift foi instalado em escopo de usuário, sem reinício; o instalador acrescentou Python 3.10.11 como dependência, coexistindo com Python 3.12 já disponível.
Os builds C++ usaram C++20, `/W4 /WX /O2` e seleção explícita de adapter.

O inventário encontrou também Parsec Virtual Display Adapter.
A enumeração DXGI mostrou duas entradas com nome RTX 4090 e uma de software; isso não comprova duas GPUs físicas.
Os ensaios GPU usaram o adapter 0 validado pelo probe.

Uma consulta de vídeo reportou 3840×2160 a 60 Hz, enquanto a sessão SSH observou uma área 1024×768 sem profundidade de cor útil.
Esses dados não qualificam a topologia física do console, HDR, VRR, DPI nem o caminho de scanout.
As duas execuções de apresentação foram iniciadas na sessão interativa por tarefa temporária, sem elevação e sem envio de teclado/mouse.
As tarefas foram removidas após o teste.

MTU de interface Tailscale 1280 e valores físicos 1492/1500 foram inventariados; MTU efetiva do tráfego UDP Lightray ainda precisa ser medida.
Os pings de descoberta do Tailscale não são RTT de mídia e não entram nas conclusões de latência.

**Evidências:** `docs/windows/evidence/native-initial/inventory.json`, `platform.json`, `network.json` e `presentation-initial/provenance.json`.

## 3. Revisão da referência e correções já verificadas

A auditoria separou o protocolo pretendido da implementação executável: parte da documentação está em transição de v0 para v1, e há mensagens provisórias na implementação Mac.
O perfil inicial fixa HEVC Main, 8-bit 4:2:0 SDR, sem B frames, cadeia PREVIOUS/IDR, protocolo autenticado existente e input reliable.
LTR ativo, PARK/RESUME, áudio, HDR, gamepad, mouse relativo, IME e adaptação WAN não podem ser anunciados como implementados por este cliente.

| Achado | Correção local e consequência |
| --- | --- |
| R01: comprimento FEC inválido | Validação de lastLength dentro de stride; rejeição antes de reconstruir frames |
| R02: configuração HEVC/framing | Rejeição de VPS/SPS/PPS vazios e NALs malformados antes do decoder |
| R03: datagramas acima do limite | NACK dividido conforme MTU negociada; saída excessiva recusada |
| R04: saturação de input | Backpressure explícito; movimento recente preservado; reset de sessão para eventos críticos recusados |
| R05: mudança de peer | Datagrama de saída conserva destino autenticado, inclusive CLOSE após teardown |
| R06: crescimento de buffers | Orçamentos agregados, limites de metadados/segmentos e reservas que acompanham frames entregues |
| R07/R08: backlog e callbacks antigos | Fila limitada, epochs e revisão de sessão; dependências inválidas exigem recuperação |
| R09/R11: diagnóstico e socket | FPS rotulado como decode; bitrate da conexão; falhas explícitas de socket e fechamento idempotente |

Limites atuais: 256 MiB de contabilidade compartilhada, 64 MiB por receiver de vídeo, 4 MiB por sender/receiver reliable, até 8.192 segmentos por mensagem e cache RS de 1 MiB por instância.
A fila de decode admite 3 frames incluindo o ativo, 32 MiB codificados e idade de espera de 100 ms.
Esses limites não representam teto de RSS/VRAM nem promessa de latência fim a fim.

A baseline auditada passou em 64 testes Swift (59 core e 5 Mac).
Após as correções, passaram 90 testes (80 core e 10 Mac), build Release de host/cliente Mac e 9 testes direcionados com Thread Sanitizer.
Passaram também 11 testes do gerador de vetores, 3 fixtures FEC independentes e o checker de 15 blocos documentais.
São suítes de escopos diferentes; seus totais não devem ser somados como uma única suíte Windows.

As correções preservam o formato de mensagens válidas, mas o adapter Windows ainda deverá provar esses comportamentos com sockets, concorrência e mídia reais.

**Referências:** `docs/reviews/2026-09-28/README.md`, `compatibility-profile.md`, `foundation-progress.md`, `robustness-progress.md` e evidências `foundation/` e `robustness/`.

## 4. Decode HEVC: método, cobertura e resultado

Foram comparados os pixels yuv420p por índice de frame e SHA-256 contra uma referência FFmpeg software no Mac.
O runner verificou integridade do corpus, perfil, dimensões, número de frames e integridade dos artefatos; frames omitidos, reordenados ou alterados fazem a comparação falhar.

| Backend Windows | 1080p: 3 clips × 120 | 1440p: 1 clip × 120 | 4K: 1 clip × 120 |
| --- | --- | --- | --- |
| FFmpeg software | 360/360; zero diferenças | 120/120; zero diferenças | 120/120; zero diferenças |
| FFmpeg D3D11VA | 360/360; zero diferenças | 120/120; zero diferenças | 120/120; zero diferenças |
| Media Foundation/D3D11 | 360/360; zero diferenças | 120/120; zero diferenças | 120/120; zero diferenças |

**Total: 1.800 decodificações de frame no Windows, sobre 600 frames codificados distintos em cinco clips.**
Cada clip declara 60 fps e contém apenas 120 frames; isso não é teste prolongado de 60 fps.

O corpus 1080p veio da pesquisa `windows-validation`, commit `d38aaade7936660f62bc4b52a230cbd7dc78f2af`, com clips IDR e duas variantes LTR.
Os clips foram lidos completos: a perda indicada nos metadados de pesquisa não foi injetada nesta campanha, e LTR não foi habilitado no protocolo do cliente.
Os clips 1440p/4K foram gerados de `testsrc2` no Mac com VideoToolbox hardware, perfil Main, I/P, sem B frames e sem fallback de encoder software; não houve captura do desktop.

No caminho Media Foundation, o runner remuxa HEVC para MP4 sem recodificação.
O probe exige `IMFDXGIBuffer`, copia a superfície NV12 para staging e aplica abertura visível e pitch antes do hash.
O caminho D3D11VA explicita download dos frames GPU para comparação.

**Problema corrigido:** o decoder MF entregou superfície 1920×1088 para conteúdo visível 1920×1080.
O recorte correto eliminou diferenças espúrias; oito casos nativos validaram geometrias e rejeições.
**Controle negativo:** o FFmpeg aceitou inicialmente adapter inexistente e usou o padrão; a enumeração/validação explícita agora rejeita o índice inválido antes do decode.

A equivalência de pixels sustenta a correção desses clips nesta máquina.
Não elege o backend mais rápido: os probes incluem download/hashing, MF aloca staging por frame e `ReadSample` inclui demux/espera.
Não qualifica streaming, cores no monitor, Main10/HDR, Windows N, ausência de extensão HEVC ou outra GPU.

**Evidências:** `native-initial/comparison-*/result.json`, `resolutions/comparison-*/result.json`, hashes por frame e `resolutions/corpus-manifest.json` sob `docs/windows/evidence/`.

## 5. Core Swift x64, fronteira C e runtimes

O experimento reutilizou uma cópia isolada dos fontes/testes do core, substituindo cinco imports de CryptoKit por Crypto apenas nessas cópias.
Foram fixados Swift Crypto 5.0.0 e Swift ASN.1 1.7.3 por revisão e lockfile.
O caminho Windows compilou BoringSSL; o resultado no Mac, sozinho, não validaria essa dependência no Windows.

| Execução | Resultado e limite |
| --- | --- |
| Core adaptado no Mac, Debug | 80 testes aprovados |
| Windows x64, Debug | 80 testes aprovados no motor padrão |
| Windows x64, Release | 80 testes aprovados com `--build-system native` |
| DLL Release chamada por C++ MSVC | 6 casos ABI aprovados; processo final terminou com exit 0 |
| Pacote com runtimes locais | Mesmos 6 casos aprovados com PATH restrito; exit 0 |

Os testes cobrem vetores criptográficos, replay, FEC, reassembly, limites, backpressure, retransmissão e sessões simuladas.
Perda, stalls, rebinding e reconexão nesses testes não equivalem a uma conexão UDP Mac→Windows em rede real.

A ABI experimental expõe uma função `@_cdecl` que abre pacote autenticado com buffers emprestados durante a chamada.
Os seis casos são: vetor válido, tag adulterada, ponteiro nulo, pacote truncado, chave curta e saída insuficiente.
Ainda faltam handles de sessão, ownership completo, política de threads, timers, callbacks, cancelamento e erros estáveis para um adapter de produto.

**Pendência de toolchain:** o motor padrão retornou exit 0 em Release com zero testes executados.
Desabilitar dead stripping não resolveu.
O gate agora exige exit 0 real e pelo menos 80 testes; rejeita a execução vazia.
O motor `native`, que executou os 80 testes, está depreciado: esse contorno precisa de solução sustentável antes de fechar CI/arquitetura.
A DLL Release e Debug continuaram sendo construídos pelo motor padrão.

**Pendência de ciclo de vida:** o chamador inicial passou nos casos, mas travou em `FreeLibrary`; o timeout de 30 s confirmou o bloqueio após as chamadas.
Manter a DLL carregada durante a vida do processo permitiu encerramento normal.
A recomendação provisória é teardown explícito de sessões sem descarregar o módulo; hot reload/unload não está homologado.

O pacote experimental reuniu 20 arquivos e 76.071.720 bytes (72,55 MiB), com dependências transitivas verificadas.
PATH restrito não substitui máquina limpa sem toolchain.
Licenças, assinatura, instalador e atualização permanecem abertos; esses binários não integram o pacote de repasse documental.

**Evidências:** `docs/windows/evidence/swift-core/`, especialmente gates Debug/Release, `abi-final.json`, `portable-manifest.json`, `portable-abi.json`, logs da execução vazia e do timeout de unload.

## 6. Apresentação D3D11: resultado e interpretação

Foram executadas duas rodadas autorizadas na sessão interativa do Windows, com janela Win32 1280×720, framebuffer 1920×1080, fundo cinza e barra sintética em movimento.
Não havia decoder, rede ou input conectados à cena.
A janela não usou fullscreen exclusivo nem solicitou ativação explicitamente.

A configuração usou adapter 0, D3D11.1, flip-discard com dois buffers, waitable object, `Present(1, 0)` e limite de fila 1 ou 2 via `SetMaximumFrameLatency`.
O executável foi conferido por SHA-256 antes de iniciar.
Havia limites de duração de 30 s no probe/tarefa e 40 s no controlador para observar término e limpeza.

| Medida | Fila máxima 1 | Fila máxima 2 |
| --- | --- | --- |
| Submissões concluídas | 600 | 600 |
| Duração | 9,976 s | 9,953 s |
| Chamadas Present por segundo | 60,144 | 60,282 |
| Intervalo de submissão p50 | 16,666 ms | 16,664 ms |
| Intervalo de submissão p95 | 16,896 ms | 16,840 ms |
| Intervalo de submissão p99 | 17,013 ms | 16,954 ms |
| Maior intervalo | 17,725 ms | 17,357 ms |
| Intervalos acima de 25 ms | 0/599 | 0/599 |
| Espera da fila p95 | 16,781 ms | 16,744 ms |
| Duração da chamada Present p95 | 0,118 ms | 0,110 ms |

Os percentis de intervalo excluem o primeiro valor, que não tem submissão anterior; restam 599 amostras por execução.
A fila 2 apresentou intervalo inicial de 0,279 ms, compatível com enchimento da fila.
A taxa levemente acima de 60 chamadas/s não demonstra monitor acima de 60 Hz.
A diferença de p99 foi de apenas 0,059 ms, em um par sequencial sem repetição/ordem alternada; não existe vencedor demonstrado.

Ambos os processos terminaram com exit 0, sem device error, timeout ou oclusão reportada que invalidasse o ensaio.
A limpeza confirmou zero tarefas do laboratório e zero processos do probe restantes.
Não houve captura de tela, inspeção visual dos pixels nem envio de teclado/mouse.

**O que foi medido:** submissão CPU, espera e tempo da chamada Present.
**O que falta medir:** FPS efetivamente exibido, scanout, cor/escala, latência de apresentação e input→photon.
Framebuffer 1080p escalado numa janela 720p não é qualificação física de display 1080p ou 4K.

O comparador recalculou métricas a partir dos CSVs no Mac e no Windows, validando sequência, quantidade, finitude, consistência de tempos e hashes.
Os 20 testes Python atuais passaram nos dois sistemas; o probe havia passado em 14 casos nativos sem GUI.
**Evidências:** `docs/windows/evidence/presentation-initial/` e `presentation-preparation/`.

## 7. Problemas encontrados e riscos que permanecem

| Situação | Tratamento aplicado | Consequência para o desenvolvimento |
| --- | --- | --- |
| Padding 1088→1080 no MF | Crop/aperture e pitch tratados; geometria testada | Preservar no adapter real, incluindo mudanças de formato |
| Adapter inválido aceito pelo FFmpeg | Validação DXGI e rejeição antecipada | Não inferir GPU usada somente por exit 0 |
| Release com zero testes e exit 0 | Gate de contagem; motor native no laboratório | Resolver toolchain/CI; não aceitar pipeline vazio |
| FreeLibrary bloqueia após ABI | Módulo retido até término; timeout no runner | Definir teardown de sessão sem unload |
| Layout de saída SwiftPM diferente | `swift build --show-bin-path` | Evitar caminhos de build presumidos |
| Processo destacado morre com SSH | Build/instalação em sessão mantida viva | Supervisão explícita e logs/código de saída |
| SSH em sessão sem desktop útil | Tarefa temporária interativa nos dois ensaios | Separar testes headless de GUI/foco autorizados |

**Risco de arquitetura:** sucesso local x64 não amplia automaticamente a matriz de suporte dos fornecedores.
Registrar versões, dependências, regressões de upgrade e gatilhos de migração; manter a comparação mínima com C++ focada nas incertezas restantes, sem reescrever o protocolo por antecipação.

**Risco de disponibilidade de codec:** MF/HEVC funcionou nesta instalação.
A ausência de extensão HEVC, Windows N e políticas de distribuição precisam de ensaios próprios e diagnóstico claro; fallback ainda não foi qualificado.
FFmpeg foi ferramenta de laboratório, sem escolha de build/licença para redistribuição.

**Risco de desempenho:** a RTX 4090 pode ocultar custos que apareçam em hardware de entrada.
Download GPU→CPU e staging por frame serviram ao oráculo de pixels, mas não devem definir o caminho final de baixa latência.
Não há evidência suficiente para escolher backend, fila padrão ou meta 4K60 de produto.

**Risco de ciclo de vida:** testes de estado simulados não demonstram ausência de vazamentos, callbacks tardios, input preso ou falhas de device numa sessão real.
A referência foi fortalecida, mas Windows ainda precisa exercer reset, reconnect, resize, múltiplos displays e suspensão.

**Risco de rastreabilidade:** o SHA base é comum a execuções com modificações locais diferentes.
Usar os manifests/digests de cada campanha, além do SHA de Git; não atribuir todos os resultados simplesmente ao checkout original.
O snapshot entregue deve ser revisado e commitado pelo fluxo normal antes de servir de baseline de CI.

## 8. Próximos incrementos, em ordem de execução

A sequência abaixo detalha a continuação do plano E00–E13, sem declarar concluídos os marcos de produto.
E00 foi concluída; E01 permanece parcial; E02.1–E02.12 têm verificações locais; E03 avançou com os experimentos, mas a decisão final está aberta.
E04 em diante ainda exigem implementação/integração e seus gates.

| Ordem e vínculo | Entrega concreta | Critério de saída |
| --- | --- | --- |
| 1. Consolidar baseline, E01/E03 | Revisar patch; fixar dependências; reproduzir suíte e resolver descoberta Release | Debug/Release com contagem real, ABI com término normal, fontes rastreáveis |
| 2. Fechar ABI e decisão, E03/E05 | Handles opacos; ownership; erros; threads/timers; cancelamento; comparação C++ mínima | Vetores idênticos; create/close repetidos; sem callback na sessão encerrada; decisão registrada |
| 3. Esqueleto e CI, E04 | Executável Windows x64; builds reproduzíveis; logs/JSON limitados e redigidos | Build limpo Debug/Release, gates obrigatórios, zero teste vazio aceito |
| 4. Transporte real, E06 | Winsock, relógio monotônico, timers e saída com endereço; handshake com host Mac | Autenticação/replay/MTU, 30 conexões por modalidade, rebinding e CLOSE reais |
| 5. Um stream integrado, E07 | NAL/config→decoder→NV12→D3D11; fila/superfícies limitadas | Pixels corretos, reset por IDR, sem backlog; spans por frame e smoke de 30 min |
| 6. Input e ciclo de vida, E08/E09 | Teclado/mouse, DPI, foco, seleção de display, reconnect e cancelamento | Sem tecla presa/evento em sessão errada; recuperação e recursos medidos |
| 7. Matriz e robustez, E10/E11 | FPS exibido, latência, perdas, outras GPUs, soak e segurança | Critérios da seção 9; falhas reproduzidas e regressões resolvidas |
| 8. Empacotamento, E12 | Instalação em Windows limpo; runtimes/licenças; assinatura e piloto | Instalar/atualizar/remover; dependências explícitas; gate de release documentado |

No incremento 5, tratar mudanças de resolução/configuração, stride/aperture/colorimetria, device lost e recuperação por IDR.
Correlacionar recepção do último fragmento, término de reassembly, início/fim de decode e apresentação por frame ID.
Separar drops na origem, rede, decode e display; não somar p95 de etapas para inventar latência fim a fim.

O trabalho de código, CI, testes de core e análise de evidências pode prosseguir em segundo plano.
Novas execuções que abram janelas ou exercitem foco/input devem ter janela de uso combinada com o proprietário da máquina.
Não é necessária senha ou chave privada para revisar este pacote.
A qualificação em outras GPUs e em instalação limpa exigirá ambientes adicionais; a RTX 4090 sozinha não fecha a matriz de compatibilidade.

## 9. Campanha de validação ainda a executar

**Metas propostas, não medidas:** perfil de referência com um stream 1080p60 SDR, rede cabeada sem perda induzida, RTT até 2 ms, origem sustentando 60 fps e monitor de pelo menos 60 Hz.
Congelar os critérios após o primeiro baseline confiável, registrando qualquer alteração; 4K, WAN e múltiplos streams precisam de metas próprias.

| Dimensão | Método e cobertura | Aceitação inicial proposta |
| --- | --- | --- |
| FPS exibido | Frame IDs e eventos de apresentação/PresentMon; conteúdo dinâmico | ≥99% dos frames da origem exibidos; drops <1% |
| Atraso local | Último fragmento até pronto para apresentar, sem confundir com scanout | p95 ≤1 intervalo de frame; p99 ≤2 |
| Input→photon | Medição óptica/instrumentada, com resolução temporal e incerteza declaradas | p95 ≤80 ms em LAN/60 Hz |
| Conexão | 30 tentativas frias e 30 com host aquecido | p95 ≤3 s fria e ≤1 s aquecida |
| Reconexão | Interrupção/restauração do caminho real, novo handshake no perfil atual | p95 ≤8 s após caminho restabelecido |
| Perda e recuperação | RTT/jitter/perda, duplicação/reordenação e bursts controlados | Vídeo recupera p95 ≤1 s após burst até 100 ms, RTT ≤60 ms |
| Recursos e estabilidade | CPU, GPU decode/render/copy, RAM, VRAM, handles, filas e erros | Sem crash/hang/OOM; após warm-up, memória cresce ≤5% e ≤100 MiB em 8 h |
| Input e sessão | Alt-tab, foco, close, reconnect, saturação e mudança de display | Zero teclas/botões presos ou eventos na sessão errada |
| Compatibilidade | NVIDIA/AMD/Intel, GPU integrada, Windows sem HEVC/N, DPI/HDR/VRR | Perfis aprovados ou recusa/fallback explícito e testado |
| Instalação | Máquina sem toolchain; usuário comum; instalar/atualizar/remover | Sem dependência oculta do ambiente de desenvolvimento |

O plano detalhado limita a campanha inicial a até 48 células: 12 de baseline, 8 de decoder, 16 de rede e 12 de compatibilidade.
Executar primeiro as células relevantes ao caminho implementado; comparar alternativas com mesmo corpus/configuração, warm-up declarado, ordem alternada e repetições suficientes para estimar variância.
Não selecionar apenas as melhores rodadas.

Estabilidade progride em 30 min (um stream), 8 h (dois streams e transições), 24 h (perdas/reconexões) e 72 h no candidato a release em laboratório reservado.
Coletar recursos a cada segundo, agregar por minuto e comparar após 15 min de warm-up, durante, ao final e após fechar as sessões.
Manter logs limitados e investigar crescimento sem platô.

RTT de rede, duração de `ReadSample`, tempo de `Present` e input→photon são métricas diferentes.
Resultados da apresentação sintética não preenchem nenhuma célula fim a fim acima.
Referência completa: `docs/windows/validation-plan.md`, com cenários, instrumentação, controles e formato dos resultados.

## 10. Reprodução, evidências e instruções de repasse

O ZIP acompanha este relatório em PDF/Markdown, o conjunto documental, as evidências preservadas, um patch binário das alterações de código/ferramentas e o corpus sintético exato de 1440p/4K.
O `README.md` do pacote explica aplicação e validação; `MANIFEST.sha256` registra integridade de cada arquivo distribuído.
O pacote não inclui credenciais, configuração SSH, toolchains, builds temporários nem os runtimes binários do experimento Swift.

**Reprodução do código:** clonar o repositório, fazer checkout do SHA base informado na seção 1, executar `git apply --check source/changes.patch` e então aplicar o patch num checkout separado.
Copiar `docs/` do pacote para esse checkout, preservando os demais documentos originais.
Copiar o corpus para o caminho indicado no README; não sobrescrever resultados de execuções anteriores.
Os seis arquivos 1080p e o lockfile Swift estão no patch de ferramentas.

**Verificações sem interface:** executar a suíte Python de `tools/windows/tests`, conferir o corpus com `lab.py verify-corpus`, compilar `build-platform-probe.ps1 -Decoder` e rodar os self-tests.
Para core, preparar a cópia com `prepare-swift-core.py` e executar `build-swift-core-probe.ps1` com as dependências fixadas.
Para apresentação, `build-platform-probe.ps1 -Presentation` compila e testa parâmetros/estatística sem abrir janela; o launcher interativo é uma etapa separada.
Os comandos completos, requisitos e limitações estão em `tools/windows/README.md` e nos relatórios de cada campanha.

| Pergunta de revisão | Onde conferir dentro de docs/windows/evidence/ |
| --- | --- |
| Quais regressões Mac passaram? | `foundation/` e `robustness/` |
| Qual Windows/GPU/toolchain foi usado? | `native-initial/inventory.json` e `platform.json` |
| Os pixels realmente coincidiram? | `native-initial/comparison-*/` e `resolutions/comparison-*/`, com framehashes dos runs |
| Release executou testes? | `swift-core/debug-final-gate.json`, `release-final-gate.json` e logs originais |
| Quais falhas foram preservadas? | `swift-core/windows-release-zero-tests.log`, `release-zero-test-gate.json`, `abi-unload-timeout.log` |
| Como o pacote Swift foi conferido? | `swift-core/portable-manifest.json`, `portable-abi.json`, `portable.exit` |
| De onde vêm os percentis D3D11? | `presentation-initial/queue-1/`, `queue-2/`, `comparison-mac.json`, `comparison-windows.json` |
| Houve limpeza das tarefas? | `presentation-initial/cleanup.json` |

Os bitstreams sintéticos foram conferidos contra os SHA-256 de `resolutions/corpus-manifest.json` antes do empacotamento.
Regenerar clips em outra combinação de hardware/OS pode alterar bytes codificados; para repetir a comparação exata, usar os arquivos entregues.

Os manifests de cada experimento registram o estado daquele momento, incluindo `dirty: true` e digest de entradas selecionadas; não são hashes de todo o pacote atual.
O manifesto de distribuição identifica o repasse atual sem substituir a proveniência histórica.
O desenvolvedor deve revisar primeiro os contornos da seção 5 e os critérios da seção 8 antes de transformar os probes em componentes permanentes.
