# Host Windows: primeira validação NVENC nativa

Data: 29/09/2026.
Prioridade autorizada: host Windows com NVIDIA, preservando o trabalho anterior do cliente.
A `main` remota foi consultada novamente e permanece em `5002116872492da705aa6252f26482b02e3df5b5`.
O [plano do host](host-implementation-plan.md) detalha a sequência seguinte; esta entrega conclui o ensaio inicial H00, não o host completo.

## Resultado principal

O novo [probe C++](../../tools/windows/src/nvenc_encode_probe.cpp) usou a API NVENC diretamente no Windows 11/RTX 4090, driver 591.86, com device D3D11 no adapter 0.
O executável foi compilado com MSVC x64, C++20 e `/W4 /WX /O2`.
Não foi usado WSL nem encoder FFmpeg; o programa carrega `nvEncodeAPI64.dll` de System32 e recusa ausência de NVIDIA/driver/API, sem fallback software.
A origem foi um padrão NV12 sintético simples, em tons de cinza, produzido na CPU e enviado a uma textura GPU persistente; não houve captura de desktop, janela, rede ou input.

| Resolução | Frames codificados | IDRs solicitados | Inspeção independente | Decode Windows/Mac |
| --- | --- | --- | --- | --- |
| 1920×1080 | 120/120 | Índices 0 e 60 | Main, 8-bit 4:2:0, 2 I + 118 P | Zero diferenças de pixels |
| 2560×1440 | 120/120 | Índices 0 e 60 | Main, 8-bit 4:2:0, 2 I + 118 P | Zero diferenças de pixels |
| 3840×2160 | 120/120 | Índices 0 e 60 | Main, 8-bit 4:2:0, 2 I + 118 P | Zero diferenças de pixels |

São 360 frames codificados distintos.
Todos os timestamps de saída coincidiram com a submissão correspondente, sem B frames/reordenação, e todos os IDRs carregaram VPS/SPS/PPS.
`ffprobe` foi usado depois do encoding para inspecionar o bitstream; não participou da codificação.
O decoder nativo Media Foundation/D3D11 no Windows produziu os mesmos pixels que FFmpeg software no Mac em todos os frames.
Essa igualdade compara decoders do mesmo bitstream lossy; não significa que a imagem codificada seja idêntica ao input cru.

## Compatibilidade com a implementação Mac

O conversor [Annex B](../../tools/windows/src/hevc_annexb.hpp) produz NALs com prefixo big-endian de quatro bytes e a configuração VPS/SPS/PPS exigida por `EncodedFrame`/`CodecConfig` na referência.
São arquivos de registros para laboratório, não datagramas ou um novo formato de protocolo.
Um verificador Python independente conferiu comprimentos, headers, tipos de frame, configurações e CSVs; reconstruir Annex B a partir dos payloads preservou todos os pixels decodificados.

Também foi executada uma cópia isolada, sem alteração dos fontes de produção, de `VideoSender`, `VideoReceiver` e `VideoDecoder` do projeto no Mac.
Ela recebeu os payloads NVENC, fragmentou/remontou localmente com limite de datagrama 1200 e decodificou via VideoToolbox: 120 frames por resolução, novamente com hashes yuv420p idênticos à referência software.
Foram 325, 431 e 1.065 fragmentos de mídia, respectivamente, sem perdas induzidas e com FEC desligado nesse ensaio.
O sealing foi identidade para exercitar somente o corpo de mídia: não houve handshake, criptografia, UDP real ou exibição de janela.
A seleção de aceleração do VideoToolbox não foi forçada nem instrumentada; o resultado prova compatibilidade com o decoder Mac existente, sem afirmar um engine específico no Mac.

A primeira execução desse verificador em Debug foi encerrada por ser lenta na extração/hashing de pixels; a execução em Release terminou com exit 0, limitada externamente a 120 s.
Isso não foi classificado como falha de decode nem usado como benchmark.
Os hashes dos fontes originais copiados estão em [mac-reference/source-manifest.json](evidence/host-nvenc-initial/mac-reference/source-manifest.json).

## Configuração e tempos observados

Configuração inicial: HEVC Main, preset P1 com tuning Ultra Low Latency, CBR de 20 Mb/s em 1080p/1440p e 40 Mb/s em 4K, VBV de um intervalo de frame, sem lookahead e GOP infinito com IDRs explicitamente solicitados.
A taxa declarada é 60 fps, mas a alimentação do probe não foi cadenciada em tempo real; cada clip tem apenas 120 frames.
P1/ULL não foi comparado com outros presets e não representa escolha final de qualidade/desempenho.

| Resolução | Encode + espera do bitstream p50 | p95 | p99 |
| --- | --- | --- | --- |
| 1080p | 1,628 ms | 2,024 ms | 3,126 ms |
| 1440p | 2,600 ms | 2,887 ms | 4,163 ms |
| 4K | 3,622 ms | 5,207 ms | 5,726 ms |

O intervalo medido começa antes de `nvEncEncodePicture` e termina depois de `nvEncLockBitstream`.
Inclui submissão e espera da operação e pode incluir dependências GPU anteriores; exclui a chamada de geração/upload sintético, a escrita dos arquivos, rede e apresentação.
Uma execução curta por resolução, com cena simples, não qualifica FPS sustentado, qualidade em jogos/desktop ou latência fim a fim.
O caminho final de captura deve evitar a geração/upload CPU do estímulo atual.
O bitrate do probe é somente do encoder; o host integrado deve reservar o overhead FEC conforme a referência.

## Falhas e controles negativos

A primeira checagem tratou incorretamente `NV_ENC_LOCK_BITSTREAM.hwEncodeStatus` como se fosse o retorno `NVENCSTATUS` da API.
O driver retornou 2 nesse campo bruto, com retorno de API bem-sucedido, timestamp 0 e picture type IDR; o probe recusou a execução.
O diagnóstico foi corrigido para conferir o retorno de cada chamada, como no [exemplo NVIDIA](https://github.com/NVIDIA/video-sdk-samples/blob/master/Samples/NvCodec/NvEncoder/NvEncoder.cpp), e preservar o campo bruto em cada linha do CSV.
A execução só foi aceita após validação adicional de ordem/tipo/configuração e decodificação independente; o log anterior permanece em [initial-failure](evidence/host-nvenc-initial/initial-failure/1920x1080.log).

Os controles de adapter inexistente, dimensão fora da matriz e sobrescrita de diretório retornaram exit 1; os dois primeiros não criaram diretório de saída.
Os builds e testes finais retornaram zero, e a consulta de limpeza encontrou zero processos `nvenc_encode_probe` restantes.
O conversor C++ passou em 14 casos no Mac e Windows, incluindo entradas malformadas, configuração ausente/duplicada e prefixos mistos.
A suíte Python passou em 25 testes nos dois sistemas, incluindo rejeição de truncamento, metadados inconsistentes, NaN e corrupção de configuração, além da preservação dos fontes Mac no preparador.
Nenhum fonte Swift de produção foi alterado nesta etapa; as 90 regressões Swift anteriores permanecem como evidência dessa referência.

## Reprodução e próximos passos

No Windows, executar da raiz do checkout com MSVC/SDK e driver compatível, escolhendo diretório novo:

```powershell
powershell.exe -NoProfile -File tools/windows/build-nvenc-probe.ps1
python tools/windows/run-nvenc-probe.py --output tools/windows/results/native-nvenc-004
python tools/windows/lab.py decode-reference --corpus-manifest tools/windows/results/native-nvenc-004/corpus/manifest.json --backend media-foundation --output tools/windows/results/native-nvenc-windows-mf-002
```

O runner limita cada processo de encode a 45 s, o probe aplica 30 s entre frames e a inspeção de bitstream tem timeout próprio.
São três resoluções fixas e 120 frames por resolução, sem fan-out ilimitado.
O build não executa carga de encode; roda apenas os testes de framing.
O decoder MF deve estar compilado por `build-platform-probe.ps1 -Decoder`, e FFmpeg/ffprobe devem estar disponíveis para os oráculos de validação.

Para a referência Mac, transferir o diretório `native-nvenc-003` com os mesmos bytes e preparar o verificador isolado:

```sh
python3 tools/windows/prepare-nvenc-mac-interop.py --output tools/windows/results/nvenc-mac-interop-002
swift run -c release --package-path tools/windows/results/nvenc-mac-interop-002 Interop tools/windows/results/native-nvenc-003 tools/windows/results/nvenc-mac-interop-002/result.json
```

Usar timeout externo de 120 s e validar o código real de saída, como na execução registrada.
Preservar os hashes do corpus ao transferir; gerar novamente pode mudar bytes conforme driver/hardware.
Os bitstreams, payloads e configs do ensaio permanecem em `tools/windows/results/native-nvenc-003/` nos dois laboratórios; JSONs, logs, CSVs, hashes e comparações estão no [índice de evidências](evidence/host-nvenc-initial/README.md).

O passo seguinte é H01/H02: componente de encoder com ciclo de vida testado e ABI do `HostEndpoint`, depois Winsock e um host sintético integrado.
Captura real e input precisam da janela de uso já solicitada pelo proprietário; ainda há trabalho de implementação em segundo plano antes disso.
O PDF/ZIP anterior descreve somente o cliente e não inclui esta nova campanha NVENC.
