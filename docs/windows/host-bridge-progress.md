# Host Windows: ponte C do core e transporte autenticado

Data: 29/09/2026.
Esta etapa implementa parte de H02 do [plano do host](host-implementation-plan.md), usando o `HostEndpoint` existente na base `5002116872492da705aa6252f26482b02e3df5b5` com as correções locais já documentadas.
A ponte é experimental e vive no laboratório; não altera o pacote Swift de produção nem entrega um host instalável.
O [ensaio NVENC anterior](host-nvenc-progress.md) permanece a evidência de encoding real na RTX 4090.

## Implementação

A [ponte Swift](../../tools/windows/src/host_bridge.swift) expõe uma [ABI C v1](../../tools/windows/src/host_bridge.h) para criação/destruição de host, recepção com endereço de origem, relógio/timers, submissão de HEVC e drenagem de eventos/datagramas.
Handshake, criptografia, fragmentação, retransmissão e recuperação continuam no core existente.
O preparador copia os fontes para um pacote isolado, adapta os cinco imports de CryptoKit para Swift Crypto e fixa as dependências por revisão, como no experimento anterior.

- Os handles são inteiros monotônicos, não ponteiros Swift, com limite de 16 hosts e sem reutilização de identificadores.
- Um lock global serializa as chamadas ao host; ele é uma solução inicial de correção, sem alegação de escalabilidade ou latência adequada ao produto.
- Buffers pertencem ao chamador e são emprestados somente durante a chamada; a saída é copiada para o buffer fornecido.
- Consultar o tamanho ou fornecer um buffer pequeno não consome a saída pendente.
- A geração muda em nova sessão e pausa; frames de uma geração antiga, stream inexistente ou sessão inativa são recusados.
- O timestamp de captura precisa estar no mesmo relógio monotônico do host e ter idade máxima de 100 ms na submissão.
- A entrada de mídia aceita no máximo 4 MiB, exige NALs HEVC com comprimentos válidos e diferencia IDR de P; IDR exige VPS/SPS/PPS e P não aceita nova configuração.
- A fila de saída é limitada a 256 datagramas/512 KiB e 64 eventos; exceder o limite encerra o endpoint e torna o handle inutilizável até destruição.
- `close` permite drenar o CLOSE para o endereço autenticado mais recente; `destroy` libera o objeto sem prometer envio de tráfego pendente.

Overflow retorna erro terminal e limpa a fila, inclusive o CLOSE, se houver.
O futuro adapter deve destruir o host e liberar input local imediatamente; o peer remoto depende do próprio timeout quando não recebe CLOSE.
Nenhum teste desta etapa injeta input.

## Contrato dos eventos

Cada registro começa com `kind:u8` e `generation:u64` big-endian, seguidos pelo corpo abaixo.
O endereço usa `ip_bytes:u8`, 4 ou 16 bytes de IP e `port:u16` big-endian; os datagramas de saída usam esse mesmo prefixo antes do pacote original.

| Kind | Evento | Corpo |
| --- | --- | --- |
| 1 | Sessão iniciada | Session ID u32 e endereço do peer |
| 2 | Sessão encerrada | Session ID u32, comprimento u16 e até 256 bytes UTF-8 do motivo |
| 3 | IDR solicitado | Stream ID u8 |
| 4 | Display solicitado | Stream ID u8, display ID u32 e request ID u32 |
| 5 | Input recebido | `InputMessage.encoded` da referência |
| 6 | Pausa | Sem corpo; nova geração |
| 7 | Retomada | Sem corpo; geração atual |

Os retornos negativos são `-1` argumento inválido, `-2` handle inválido/destruído, `-3` capacidade insuficiente, `-4` geração/stream/sessão inválida e `-5` overflow terminal.
O retorno de `pop` é o número de bytes copiados ou zero para fila vazia; `next_wakeup` usa `UINT64_MAX` quando não há timer.
O chamador continua responsável por ponteiros acessíveis, ordenação temporal das chamadas e consumo limitado das filas.
O formato de endereço ainda não representa scope ID IPv6; suporte de socket IPv6, incluindo link-local, pertence a H03 e não está validado aqui.

## Método de validação

Os oito testes novos cobrem lifecycle/limites, handshake e saída não consumida por consulta, chave incorreta, entrega de mídia e geração antiga, CLOSE após rebinding, pausa/retomada e frames atrasados, overflow e entradas inválidas.
Os NALs pequenos dos testes unitários exercitam framing e transporte; não são uma prova de decodificação HEVC.

O [harness MSVC](../../tools/windows/src/host_abi_probe.cpp) carrega a DLL Swift nativa e chama os símbolos C reais.
Ele exercita 100 ciclos de criação/destruição por quatro threads, handles antigos, relógio regressivo e o limite de 16 hosts.
Em seguida reproduz os arquivos do ensaio `native-nvenc-003`: 120 frames em 1080p, 1440p e 4K, com IDRs nos índices 0 e 60.
Um peer de laboratório usa o `ClientEndpoint` para autenticar/remontar os datagramas e comparar cada payload recebido byte a byte com o original NVENC.
O relógio é simulado e os pacotes são transferidos em memória; não há Winsock, rede real, encoder ao vivo ou medição de FPS/latência nesta etapa.
O callback `decoded` do peer é somente uma confirmação de laboratório após remontagem, não execução de decoder.
O arquivo `host_probe_client.swift` contém chave pública fixa de fixture, existe somente no pacote experimental e não pode integrar distribuição de produto.

## Resultados observados

| Verificação | Resultado final |
| --- | --- |
| Suíte Swift no Mac, pacote isolado | 88 testes aprovados |
| Suíte Swift no Windows nativo x64, Debug | 88 testes aprovados |
| Suíte Swift no Windows nativo x64, Release | 88 testes aprovados, motor `native` |
| ABI C anterior, AES-GCM/vetores/erros | 6 casos aprovados |
| ABI C do host, chamador MSVC | 100 ciclos, quatro threads, limite de 16 hosts e três handshakes aprovados |
| Payloads NVENC autenticados/remontados | 360/360 idênticos ao original, nas três resoluções |
| Harness Python | 25 testes aprovados em cada sistema |
| Checker de documentação | 15 blocos, zero problemas |
| Encerramento | Exit codes zero e nenhum processo dos probes remanescente |

Os [logs e hashes](evidence/host-bridge-initial/README.md) identificam os fontes e o binário realmente executado.
O hash SHA-256 da DLL final é `5f71e68c6047c42df88f2faa9bfb640b1356eeb3532fcb668ae5aa09850aec8c`.
Os fontes do core, da ponte e do build coincidem entre Mac e Windows; o JSON dos vetores públicos tem CRLF no Windows e LF no Mac, com conteúdo JSON idêntico e ambos os hashes preservados.
A primeira compilação local falhou por um label ausente no fixture de ping; o erro foi corrigido e o log inicial permanece como histórico, separado do resultado final.
A primeira rodada Windows com sete testes adicionais aprovou 87 testes e 360 frames; a rodada final acrescentou a proteção de pausa/freshness e aprovou os 88 testes mais o mesmo harness MSVC.

## Limites e próximos gates

A DLL Swift permanece carregada até o processo terminar, preservando o contorno do bloqueio de `FreeLibrary` observado anteriormente.
Os ciclos de handles verificam término e rejeição de identificadores antigos; não são 100 ciclos de inicialização NVENC nem uma medição de vazamento de RAM/VRAM.
O motor `native` depreciado continua necessário para descobrir testes Release no Swift 6.4 deste laboratório; a alternativa sustentável de CI permanece pendente.
A API `@_cdecl` e o contrato v1 ainda precisam ser estabilizados antes de distribuição.

Próxima sequência: extrair o componente de encoder NVENC com lifecycle/reconfiguração (H01), conectar o adapter Winsock inicialmente em loopback (H03) e integrar a origem sintética ao vivo antes da campanha Windows→Mac (H04).
Captura de desktop e testes com foco/input continuam sujeitos à combinação de uso da sessão com o usuário.
