# Host Windows visível e controlável no Mac

Em 29/09/2026, o cliente Mac exibiu a captura real do Windows e enviou clique, teclado, Ctrl+A, seleção com Shift e rolagem com efeito verificado na janela de teste Windows.
O caminho usa Desktop Duplication e conversão BGRA→NV12 na GPU, encoder NVIDIA NVENC nativo, core Swift por ABI C, Winsock/UDP autenticado e decoder/apresentação do cliente Mac.
Não usa WSL, processo FFmpeg, encoder de software ou reprodução de arquivo como fonte da sessão.
Este é um marco funcional de laboratório; não representa a conclusão dos gates H03–H08 do plano de produto.

## Configuração e proteção da sessão

- Windows 11 Home x64 build 26200, RTX 4090, driver NVIDIA 591.86, MSVC 14.44 e Swift 6.4 x64 do laboratório.
- Primeiro output do adapter D3D11, desktop físico 3840×2160 convertido para stream SDR 1920×1080 a 30 FPS, HEVC Main 8-bit 4:2:0, P1/ultra-low-latency, alvo de 20 Mb/s e FEC desativado.
- Relógio `steady_clock`, timer Windows de alta resolução, socket IPv4 não bloqueante e fila de envio limitada; retry de `WSAEWOULDBLOCK` implementado, sem teste específico de saturação nesta rodada.
- Bind explícito na LAN, UDP 37373, filtro para o IP do Mac e regra temporária de firewall restrita ao programa/IP/porta; nenhuma liberação global.
- PSK aleatória em arquivo privado, sem token em argv/logs, com pareamento temporário do Mac via `--pair-file`, preservando o pareamento previamente salvo pelo usuário.
- Captura e input autorizados pelo usuário; teste em aplicativo próprio, com evidência visual contendo apenas o texto de teste.
- Processos de host e janela, endpoint UDP, tarefa temporária e regra de firewall removidos ao final; os arquivos privados de pareamento permanecem fora do Git e do pacote de entrega.

## Resultado da campanha final `desktop-005`

| Verificação | Evidência observada |
| --- | --- |
| Cliente principal | 90 segundos; 17 amostras de diagnóstico, emitidas aproximadamente a cada 5 segundos |
| FPS decodificados reportados | Mínimo 30, mediana 30, máximo 31; contagem em janela de tempo, alvo do host 30 FPS |
| RTT de transporte reportado | Mínimo 3,4 ms, mediana 5,3 ms, máximo 8,4 ms |
| Perda, descartes de decode, erros de socket | Zero nos contadores das 17 amostras; não houve perda artificial nesta rodada |
| Segunda conexão | Nova instância do cliente, 30 segundos; sessão estabelecida em 0,004 s com host já pronto |
| Host nas duas sessões | 3.505 frames, dois IDRs, dois pedidos de IDR, três ajustes/descartes de cadência, duas sessões |
| Input final | 66 eventos aplicados, zero usos não suportados, zero falhas de injeção e zero teclas/botões retidos ao encerrar |
| Aplicação Windows | Texto esperado confirmado, um clique de botão, uma rolagem e um Ctrl+A reconhecido pelo aplicativo |
| NVIDIA | Amostra `nvidia-smi`: encoder 2%; leitura agregada da GPU, sem atribuição exclusiva de toda a utilização ao host |
| Regressão local | 92 testes Swift no Mac (80 core + 12 Mac), 29 testes Python e dois casos de erro da CLI de pareamento |
| Build Windows | MSVC `/std:c++20 /W4 /WX /O2`; 15 casos de input com emissor falso, sem injeção no desktop |

O primeiro handshake levou 3,109 s desde a abertura do cliente, incluindo a inicialização concorrente do host; não deve ser apresentado como latência típica de conexão fria.
A RTT é um indicador do transporte reportado pelo cliente, não uma medição de latência input→photon, captura→display ou distribuição de latência por frame.
A cena tinha texto, botão e contador atualizado a 4 Hz; essa cadência de decode não qualifica movimento intenso, jogos ou carga sustentada de 20 Mb/s.
O contador `skipped` do host inclui correções de prazo e frames fora do orçamento de idade; não equivale ao contador de perda do cliente.

## Ajustes encontrados durante a integração

A primeira tentativa não recebeu pacotes pela rota Tailscale escolhida: o IP do Windows acessado por SSH não estava entre os pares visíveis no Tailscale deste Mac.
A validação passou pela LAN, preservando a identidade SSH previamente confirmada; acesso via Tailscale deste par continua pendente de alinhamento de rede.
O teste inicial de foco podia ficar atrás de outra janela; a janela de teste passou a cobrir o output e ficar temporariamente no topo, sem elevar o host.
O cliente recebeu suporte a cursor local e tratamento de eventos de modificadores sem bits específicos de lado ou sem `flagsChanged`, com testes que preservam a distinção esquerda/direita quando fornecida.
O controle Win32 `EDIT` da janela de teste recebeu tratamento explícito de Ctrl+A; a rodada final registrou o modificador e a substituição correta do texto.
As reconexões durante as rodadas anteriores também recuperaram imagem; os números da tabela se referem exclusivamente à rodada final, sem misturar estatísticas entre builds.

## Reprodução no laboratório

Usar MSVC, driver NVENC e a DLL `LightrayCoreProbe.dll` preparada pelo fluxo `swift-core-002`, conforme o README das ferramentas.
Manter os dois arquivos de pareamento privados iguais, existentes apenas nos endpoints autorizados; não copiar seu conteúdo para comandos, tickets ou documentos.
Coordenar a sessão antes de passar `-DesktopApproved`, porque o teste captura o output e coloca uma janela temporária no topo.
Criar a regra temporária `LightrayLab-DesktopTest-37373` somente para `windows_host.exe`, UDP 37373, IP local escolhido e IP do Mac.

```powershell
powershell -NoProfile -File tools/windows/build-desktop-host.ps1
powershell -NoProfile -File tools/windows/start-desktop-host-test.ps1 -DesktopApproved -Run desktop-006 -BindIPv4 192.168.15.5 -PeerIPv4 192.168.15.13 -PairFile tools/windows/results/desktop-pairing -Seconds 240
```

O runner resolve `-PairFile` para caminho absoluto antes de iniciar o worker, que tem diretório de trabalho próprio.
No Mac, da raiz do checkout:

```sh
swift build --package-path macos -c release --product lightray-client
macos/.build/release/lightray-client 192.168.15.5:37373 --pair-file tools/windows/results/desktop-pairing --streams 1 --no-fec --local-cursor --exit-after 180
```

Encerrar pelo runner e conferir o resultado:

```powershell
powershell -NoProfile -File tools/windows/stop-desktop-host-test.ps1 -Run desktop-006 -RemoveTestFirewall
```

Os IPs são os valores observados no laboratório, não padrões de distribuição; conferir a interface de destino antes de reproduzir.
O host nativo também pode ser iniciado diretamente na sessão interativa com os argumentos `CORE_DLL BIND_IPV4 PEER_IPV4 PAIR_FILE SECONDS NEW_OUTPUT_DIRECTORY`, duração máxima de uma hora e DLLs Swift disponíveis no PATH.

## Próximos gates

1. Recuperar `DXGI_ERROR_ACCESS_LOST`, troca/bloqueio de sessão, mudança de resolução e perda do device, com liberação de input e nova geração de mídia.
2. Qualificar cursor do host, DPI, escala, cores, layouts de teclado, teclas adicionais, integridade/UIPI e múltiplos outputs/adapters; a rodada atual cobre um output SDR sem rotação e input de usuário comum.
3. Medir 1080p60 por 30 minutos com cena dinâmica, custos locais por etapa, RAM/VRAM e latência input→photon instrumentada; depois ampliar para 1440p/4K e 8/24/72 horas.
4. Executar a matriz de autenticação negativa, perda, jitter, reordenação, MTU, backpressure, FEC, reconexões frias/aquecidas e caminho Tailscale/IPv6.
5. Preparar distribuição sem toolchain, dependências Swift, assinatura, armazenamento de pareamento e UX de autorização; áudio, clipboard e transferência de arquivos não foram implementados neste marco.

Evidências, logs, imagem decodificada e hashes: [índice da campanha](evidence/host-desktop-initial/README.md).
Referências de API: [Desktop Duplication](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api), [VideoProcessorBlt](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videocontext-videoprocessorblt) e [KEYBDINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput).
