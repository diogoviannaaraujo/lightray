# Laboratório do cliente Windows

> **Broken on main; Windows is to be ported to Rust.** The host below gets its whole protocol
> layer (handshake, encryption, packets, FEC) from the Swift core through a C bridge,
> `src/host_bridge.swift`, which `prepare-swift-core.py` builds from `macos/Sources/LightrayCore`.
> The Swift code now lives in [`apple/`](../../apple/README.md) and is for Apple platforms only,
> so that bridge no longer builds, and nothing here is maintained until the Rust port replaces it.
> The reports and evidence this README links to are not on main either: they are kept at commit
> 5ae52d6, which added this directory (pull request #3), and the links point there. The lab's
> corpus checks read their manifest from that evidence, so they fail on main too.

Começar pelo [guia de revisão do pull request](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/pull-request-review.md), que organiza implementação, evidências, reprodução e pendências de integração.
Campanha mais recente: [conexão gráfica e captura WGC Mac → Windows](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/connection-capture-progress-2026-10-01.md), após [menu da sessão](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/session-controls-progress.md) e [recuperação limitada DXGI](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/capture-recovery-progress.md).
Relatório atualizado: [revisão do desenvolvedor em 01/10/2026](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/developer-report-2026-10-01.md).
Campanha de desempenho: [tentativa 4K90, métricas e recuperação da captura](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/host-4k90-progress.md).
Marco funcional anterior: [host Windows visível e controlável no Mac em 1080p30](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/host-desktop-progress.md).
`build-desktop-host.ps1` compila o host, a janela de teste, os probes DXGI/WGC, 19 casos de input sem injeção no sistema, 12 de recuperação e 8 de metadados de display.
`start-desktop-host-test.ps1 -DesktopApproved` inicia uma sessão interativa com duração limitada; `stop-desktop-host-test.ps1` encerra e verifica a liberação dos recursos.
O cliente Mac aceita `--pair-file` para manter o token fora de argumentos/logs e `--local-cursor` para este host inicial.

O laboratório também inclui o [host Windows/NVENC](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/host-nvenc-progress.md), prioridade autorizada em 29/09/2026.
`build-nvenc-probe.ps1` compila o encoder nativo e testa o conversor de framing; `run-nvenc-probe.py --output tools/windows/results/native-nvenc-NNN` executa três clips sintéticos de 120 frames pela API NVIDIA, sem captura do desktop ou fallback software.
FFmpeg/ffprobe são usados somente na validação offline dos bitstreams; não codificam os clips NVENC.
O [plano do host](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/host-implementation-plan.md) e o [índice de evidências](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/evidence/host-nvenc-initial/README.md) distinguem o probe da implementação de produto.
O incremento da [ABI do host](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/host-bridge-progress.md) reaproveita esses payloads NVENC para verificar transporte autenticado, sem socket nem encoder ao vivo.

Ferramentas preparatórias para E01/E03/E04 do [plano](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/implementation-plan.md).
Não constituem ainda um cliente Windows ou um benchmark de GPU.
Requerem Python 3.9+; o decode de referência exige FFmpeg/ffprobe disponíveis no PATH ou informados por `--ffmpeg` e `--ffprobe`.
A execução registrada usou FFmpeg 8.0.1 no Mac; nenhuma dependência é baixada automaticamente.

## Comandos

Executar da raiz do checkout, escolhendo um diretório novo para cada execução:

```sh
python3 tools/windows/lab.py verify-corpus --output tools/windows/results/corpus-001
python3 tools/windows/lab.py decode-reference --output tools/windows/results/software-001
python3 tools/windows/lab.py inventory --ssh-alias rtx4090 --output tools/windows/results/inventory-001
python3 -m unittest discover -s tools/windows/tests -v
```

Os diretórios de resultados locais são ignorados pelo Git.
O runner recusa sobrescrever diretórios existentes e grava `result.json` com schema, run ID, data UTC, revisão Git, dirty flag e digest dos arquivos de implementação selecionados.
O digest não é um manifesto de distribuição: inclui Swift, manifest do pacote, scripts do laboratório e corpus; dependências/toolchains são registradas separadamente.
Código de saída 0 significa sucesso daquela ação; 2 significa bloqueio, inventário parcial ou falha, conforme `status` e `reason`.
Erros de uso do CLI e diretório já existente também retornam código diferente de zero.

## Corpus e decoder de referência

Os seis arquivos em `reference/` são verificados pelo [manifesto auditado](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/evidence/foundation/hevc-corpus.json), incluindo tamanho, SHA-256 e SHA de origem.
Antes de rodar um decoder, o runner exige todos os hashes corretos.
O FFmpeg usa explicitamente o decoder HEVC em software, exige Main/yuv420p e as dimensões do manifest, falha em erros de decode e confere a quantidade e o tamanho dos frames produzidos.
Cada `.framehash` contém hashes SHA-256 dos pixels yuv420p de cada frame, em ordem.
Comparar `bytes` e `sha256` por índice ao confrontar outro decoder; timestamps e headers do arquivo podem variar conforme a versão do FFmpeg.
Uma diferença de hashes exige investigar pixels, crop, colorimetria e conversão antes de atribuir erro ao codec.

Os manifests marcam perda dos frames 40–45 para experimentos de recuperação; esta ação decodifica o arquivo completo, sem aplicar essa perda.
Os clips LTR são material de pesquisa e não ampliam o perfil PREVIOUS/IDR do cliente atual.
O campo `wall_seconds` inclui criação do processo, conversão e hashing; não representa FPS visível, latência de decode isolada, input→photon ou desempenho Windows.
As comparações de decode MF/FFmpeg/D3D11VA passaram em 1080p, 1440p e 4K nesta RTX 4090; corrupção/perda e apresentação física permanecem em E03/E07/E10.

O [gerador sintético](generate-corpus.py) produz dois clips de 120 frames, 1440p/4K a 60 fps declarados, pelo VideoToolbox do Mac, sem capturar tela.
Usar `--corpus-manifest tools/windows/results/resolution-corpus-001/manifest.json` no runner para selecionar esse corpus, preservando a verificação obrigatória de hashes e pares HEVC/JSON.
Consultar [comandos, evidências e limites de reprodução](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/resolution-validation-progress.md).

## Inventário remoto somente de leitura

`inventory.ps1` consulta Windows, CPU/RAM, GPU/driver, rede/MTU de interfaces, ferramentas no PATH, versões do SDK, instalação Visual Studio, VRAM pelo `nvidia-smi` quando disponível e displays observáveis na sessão do processo.
Não modifica serviços, firewall, driver, plano de energia ou desktop, nem executa carga de GPU.
Não coleta hostname, usuário, IP, MAC, número de série, UUID de GPU ou configurações pessoais.
Erros de seções opcionais aparecem como `unavailable`, sem despejar mensagens potencialmente identificáveis.
O script foi executado com PowerShell 5.1 no Windows 11 do laboratório.
Os testes Python também validam falhas do runner com subprocessos simulados; disponibilidade de consultas opcionais precisa continuar sendo verificada em outros equipamentos.

`Win32_VideoController.AdapterRAM` é `uint32`, portanto não serve como fonte confiável de VRAM de uma RTX 4090; o script usa a consulta específica do NVIDIA quando disponível e deixa ausente quando não há fonte adequada ([Microsoft](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-videocontroller)).
Os valores de display via SSH não homologam a topologia física do console; HDR, VRR, DPI, caminho direto/DERP e MTU efetiva do UDP ficam explicitamente em `unmeasured`.

O runner usa SSH em batch com `StrictHostKeyChecking=yes`, timeout total de 45 segundos e alias restrito a caracteres de nome.
O script é enviado por stdin para evitar o limite de comprimento da linha de comando do Windows.
Falha de identidade retorna `ssh_host_identity_unverified`; falha de autenticação retorna `ssh_authentication_failed`.
A identidade precisa ser estabelecida por canal confiável antes de executar consultas na máquina.
Nenhum aceite automático de chave desconhecida é implementado.

Depois da liberação do acesso, executar primeiro o inventário, conferir os campos indisponíveis e concluir E01 antes dos experimentos A/B/C/D.
Não instalar ferramentas ou iniciar testes de foco/GPU/soak como efeito colateral de coletar inventário.

## Ensaios nativos em Windows

O inventário PowerShell e os probes abaixo foram executados em Windows 11 x64; consultar os [resultados nativos](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/native-validation-progress.md).
O SSH já foi validado com a impressão confirmada pelo usuário; para usar um arquivo exclusivo de chaves públicas confiáveis, informar `--known-hosts caminho/do/arquivo` ao inventário.
Esse arquivo fica em `results/`, fora do versionamento.

No checkout Windows, os scripts encontram o MSVC instalado via `vswhere`, sem alterar o PATH global:

```powershell
powershell.exe -NoProfile -File tools/windows/build-platform-probe.ps1
powershell.exe -NoProfile -File tools/windows/build-platform-probe.ps1 -Decoder
tools/windows/results/platform-build/mf_decode_probe.exe --self-test
python tools/windows/lab.py decode-reference --backend software --output tools/windows/results/software-001
python tools/windows/lab.py decode-reference --backend d3d11va --adapter-index 0 --output tools/windows/results/d3d11va-001
python tools/windows/lab.py decode-reference --backend media-foundation --output tools/windows/results/mf-001
python tools/windows/lab.py compare-reference --reference-run tools/windows/results/software-001 --candidate-run tools/windows/results/mf-001 --output tools/windows/results/compare-mf-001
```

`platform_probe.cpp` cria devices D3D11 e consulta profiles/configurações HEVC Main para 1080p, 1440p e 4K, além de enumerar e ativar MFTs HEVC.
Essas consultas são capacidades anunciadas; não são decode nem benchmark das três resoluções.
O runner exige um adapter DXGI enumerado, não software, com device criado e profile HEVC Main antes de executar um backend de hardware.
Essa validação é necessária porque o FFmpeg desta máquina aceitou um índice inexistente e usou o device padrão no controle negativo inicial.

`mf_decode_probe.cpp` é um experimento descartável C++20 de Media Foundation/Source Reader com device D3D11 no adapter 0.
O runner remuxa o HEVC para MP4 sem recodificar, e o probe exige samples com `IMFDXGIBuffer`, copia a superfície NV12 para staging, aplica a abertura visível e calcula SHA-256 em yuv420p com CNG.
Aberturas fracionárias/ímpares ou fora dos limites são rejeitadas; os oito casos de `--self-test` cobrem o recorte 1088→1080 e geometrias inválidas.
A aplicação da abertura segue [MF_MT_MINIMUM_DISPLAY_APERTURE](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-mt-minimum-display-aperture-attribute).
O FFmpeg/D3D11VA usa explicitamente `hwdownload` para que a comparação leia pixels na CPU, conforme as [opções de hardware do FFmpeg](https://ffmpeg.org/ffmpeg.html).

Os probes não abrem janelas, criam swapchains, capturam tela ou injetam input.
`read_sample_p50/p95/p99_ms` mede a duração das chamadas que produziram samples, incluindo demux e espera no decoder, e exclui download/hashing posteriores.
Não é latência pura de decode, apresentação ou input→photon, e não permite eleger o backend mais rápido sem um benchmark controlado equivalente.
Os executáveis são ferramentas de laboratório, não o cliente final ou sua API de decoder de rede.

`compare-reference` exige runs separados, status de sucesso, mesmos clips/inputs/formatos, hashes válidos dos artefatos e quantidade declarada consistente.
Diferenças de pixels, frames omitidos ou reordenados falham; a saída limita os índices de divergência aos primeiros 20 por clip, preservando a contagem total.

## Experimento de reutilização do core Swift

`prepare-swift-core.py --output tools/windows/results/swift-core-001` copia somente os fontes/testes/fixtures necessários e troca `import CryptoKit` por `import Crypto` nessas cópias.
O projeto de produção não é alterado pelo preparador.
Swift Crypto 5.0.0 é fixado por revisão, com `Package.resolved` também fixando Swift ASN.1 1.7.3; builds usam `--force-resolved-versions`.
O manifesto do experimento registra hashes dos fontes originais, cópias adaptadas e demais entradas.

O ambiente Windows requer Swift 6.4 x64, MSVC x64 e Windows SDK; seguir o [instalador oficial](https://www.swift.org/install/windows/).
O laboratório instalado usa o escopo do usuário e não reinicia a máquina.
Preparar a cópia e executar `powershell.exe -NoProfile -File tools/windows/build-swift-core-probe.ps1` mantém os logs/testes no laboratório.
Manter a sessão SSH viva durante build/instalação: processos filhos destacados podem ser encerrados pelo sshd quando a sessão termina.

O probe compila os testes do core em Debug e uma DLL em Release, depois compila um chamador MSVC que carrega o export C experimental.
São seis casos na fronteira: vetor AES-GCM válido, autenticação adulterada, ponteiro nulo, pacote truncado, chave curta e saída insuficiente.
Esse export baseado em `@_cdecl` serve para medir viabilidade; não estabelece ainda ABI estável, ownership de sessões, empacotamento dos runtimes ou escolha final da arquitetura.

`package-swift-core-probe.ps1 -Run portable-001` monta um pacote de laboratório com as dependências transitivas detectadas por `dumpbin`, limitado a 64 módulos, e repete o chamador com PATH restrito à pasta e ao Windows.
Não sobrescreve runs existentes e não publica um instalador.
O chamador tem timeout de 30 segundos e mantém a DLL até terminar o processo: `FreeLibrary` ficou preso no ensaio inicial, apesar de todos os casos terem passado antes do descarregamento.
Consultar os [resultados e restrições de arquitetura](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/swift-core-progress.md).

`verify-swift-tests --test-log caminho.log --test-exit-code 0 --output diretório-novo` exige ao menos 80 testes Swift aprovados, além do exit code real do processo.
O build do experimento aplica esse gate: uma execução vazia não pode passar por validação, mesmo quando o SwiftPM termina com sucesso.
No Swift 6.4 testado, a suíte Release usa `--build-system native` porque o motor padrão descobriu zero testes; Debug e a DLL do chamador C++ usam o motor padrão.

Para incluir a ponte experimental do host, preparar um diretório novo com `python3 tools/windows/prepare-swift-core.py --host-bridge --output tools/windows/results/swift-core-002` e executar `build-swift-core-probe.ps1 -Probe swift-core-002` no Windows.
O build exige 88 testes em Debug/Release e executa o harness MSVC com os registros NVENC de `results/native-nvenc-003`; esse corpus precisa ter sido produzido e validado pelo ensaio NVENC anterior.
O peer `host_probe_client.swift` exporta símbolos auxiliares com chave pública de fixture apenas para esse teste e nunca deve ser incluído em distribuição de produto.
Ao verificar o log manualmente, usar `verify-swift-tests --minimum-tests 88` e fornecer o exit code real; o mínimo padrão 80 continua atendendo ao experimento original sem a ponte.
O motor `native` é depreciado e esse contorno não encerra a avaliação de manutenção/CI.

## Apresentação com janela

`build-platform-probe.ps1 -Presentation` compila `present_probe.exe` e executa somente o self-test sem interface.
O [roteiro de apresentação](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/presentation-probe-progress.md) descreve as duas execuções propostas e os limites das métricas.
O launcher `run-presentation-probe.ps1` exige combinação prévia com o usuário e `-DesktopApproved`, pois a tarefa temporária abre uma janela na sessão interativa.
Não executar esse launcher como efeito colateral de build ou inventário.

As duas primeiras rodadas autorizadas passaram com 600 submissões por fila, e tarefas/processos temporários foram removidos.
`compare-presentation --reference-run caminho-da-fila-1 --candidate-run caminho-da-fila-2 --output diretório-novo` confere o JSON contra os CSVs, recalcula percentis, registra hashes e rejeita dados incompletos ou inconsistentes.
Uma comparação aprovada valida os artefatos do smoke; não elege a fila mais rápida nem comprova FPS exibido/latência de ponta a ponta.

## Componente NVENC e UDP loopback

A [campanha do host ao vivo](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/host-live-progress.md) extrai `NvencEncoder` e exercita create/close, pausa/retomada, IDR e reconfiguração com texturas sintéticas em 1080p/1440p/4K.
`build-nvenc-probe.ps1` compila o componente, o probe de corpus e `nvenc_lifecycle_probe`; `run-nvenc-lifecycle.py --output tools/windows/results/nvenc-lifecycle-001` exige 600 frames, 100 ciclos medidos após 30 ciclos completos de aquecimento, decode independente e gates de recursos.
`run-host-loopback.ps1 -CoreProbe swift-core-002 -Run host-loopback-001` usa uma DLL Swift já validada e o corpus `native-nvenc-004`, compila sete testes Winsock e o harness MSVC, e executa tanto reprodução em memória quanto NVENC ao vivo via UDP local.
O listener é exclusivamente `127.0.0.1:7373`, com bind exclusivo, fecha ao terminar e falha se a porta já estiver ocupada.
O relógio do core ainda é simulado; esta etapa não comprova FPS, latência, estabilidade prolongada, IPv6 ou conexão entre máquinas.
A chave fixa do peer é pública e de fixture; esses executáveis não são um host de produto.

## Host timing telemetry

The native host reports optional capture/convert and encode durations through `lr_host_submit_timed` and writes a `sample_id` column to its frame CSV.
The original `lr_host_submit` ABI remains available.
Select the matching prepared DLL with `start-desktop-host-test.ps1 -CoreProbe swift-core-003` (or another prepared probe ID).
Run `python3 tools/windows/verify-host-timings.py --host-csv frame-timings.csv --client-log client.log` to require exact agreement with sampled Mac log values.
See [semantics, compatibility and results](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/host-telemetry-progress.md).

## Explicit Windows Graphics Capture diagnostic and host

Build `capture_probe.exe` and `wgc_capture_probe.exe` with `build-desktop-host.ps1`; the latter uses the installed Windows SDK C++/WinRT headers and inbox Windows libraries.
`run-capture-probe.ps1 -DesktopApproved -Run capture-NNN -Motion -Backend wgc` runs a five-second bounded texture-count diagnostic in the interactive session, with optional animated lab window, no saved pixels and no injected input.
The default diagnostic backend is `dxgi`; never reuse an existing run directory.
`start-desktop-host-test.ps1 -CaptureBackend wgc -CoreProbe swift-core-003` selects the alternative capture path explicitly while preserving D3D11 conversion and native NVIDIA NVENC.
DXGI remains the default; the host does not switch capture backends silently.
WGC keeps a two-buffer frame pool, the platform capture indicator/cursor and a COM apartment alive across session recreation.
Rebuild the host before using the updated runner, which passes the explicit capture backend argument.
The [F01/F02 report](https://github.com/diogoviannaaraujo/lightray/blob/5ae52d6/docs/windows/connection-capture-progress-2026-10-01.md) preserves a native failure and the three subsequent successful recreation tests; production reliability remains pending.
