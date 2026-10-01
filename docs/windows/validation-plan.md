# Plano de validação do cliente Windows

Data: 28/09/2026.
Documento vinculado ao [plano de implementação](implementation-plan.md) e à [revisão da baseline](../reviews/2026-09-28/README.md).
Tudo neste documento é procedimento ou meta proposta, exceto o estado inicial explicitamente registrado ao final.
Nenhuma linha da matriz representa um resultado Windows já obtido.

## Princípios de medição

O sistema completo é `captura Mac → encode → transporte → reassembly → decode Windows → apresentação → display`.
Uma RTX 4090 rápida não corrige um host que entrega menos frames, uma fila ilimitada ou uma rede congestionada.
Medir cada trecho e o resultado final, mantendo configuração e conteúdo iguais nas comparações.
Primeiro comprovar correção de bytes/frames, depois medir desempenho; FPS alto com imagem incorreta ou teclas presas reprova o cenário.

Usar três modalidades distintas:

1. **Determinística:** core sem rede/GPU, relógio e eventos controlados, perda com seed e limites de memória observáveis.
2. **Pipeline isolado:** bitstream conhecido entregue localmente ao decoder/renderizador Windows, sem capturar/encodar no Mac durante a medida.
3. **Fim a fim:** host Mac real, rede identificada e cliente Windows com apresentação física; acrescentar ensaio óptico para input→photon.

Resultado em WSL ou runner sem display comprova somente os componentes ali exercitados.
Decode headless não homologa compositor, refresh físico, foco, input ou latência do monitor.

## Laboratório e condições controladas

| Item | Registrar antes da campanha | Por que influencia |
| --- | --- | --- |
| Host Mac | Modelo, SO, revisão, flags, telas, energia, temperatura e carga concorrente | Captura/encode e FPS entregue podem limitar a origem |
| Windows | Edition/build, CPU/RAM, sessão console/RDP, energia e serviços de carga relevantes | Scheduling, recursos de mídia e adapter ativo |
| GPU | Modelo/PCI ID ou identificação redigida, driver, VRAM, adapter LUID, backend real, Video Decode/3D/Copy | Evita confundir GPU selecionada, fallback e motor ocupado |
| Display local | Resolução, Hz, escala/DPI, HDR/SDR, VRR, conexão e quantidade | Define quantos frames podem ser mostrados e o custo da apresentação |
| Rede | Ethernet/Wi-Fi, velocidades, rota, IPv4/IPv6, MTU, Tailscale direto/DERP, RTT e carga | Um túnel ou relay muda o caminho e o orçamento de latência |
| Build | SHA host/cliente, dirty flag, perfil wire, release/debug, flags e dependências | Permite repetir exatamente o binário |
| Conteúdo | ID/hash do clip, resolução, FPS, GOP, perfil HEVC, bitrate, cores e frames esperados | Controle de carga e correção |
| Execução | Run ID, horário, seed, warm-up, duração, ferramenta/versão e motivo de interrupção | Comparação auditável |

Não registrar tokens, PSKs, texto digitado, screenshots do trabalho pessoal ou endereços identificáveis em relatórios versionados.
Usar IDs de máquinas e conteúdo sintético; guardar dumps/ETW potencialmente sensíveis em local restrito e revisar antes de compartilhar.
Testes de input, foco, hot-plug e cargas longas precisam de uma sessão de laboratório disponível, sem disputar o desktop usado por outra atividade.
Não alterar driver, firewall, plano de energia, clocks ou serviços silenciosamente para melhorar números.

A conexão de gerenciamento será Tailscale/SSH conforme o ambiente existente.
Testar o UDP real entre host e cliente; benchmark dentro de SSH não representa o transporte Lightray.
Para perda/jitter/banda/MTU, usar proxy de datagramas do harness ou equipamento de laboratório com perfil por fluxo, sem degradar globalmente a rede do usuário.

## Instrumentação e definições

| Métrica | Definição operacional | Cuidado necessário |
| --- | --- | --- |
| Capture/encode FPS | Frames capturados e bitstreams completos produzidos por segundo no host | Desktop estático pode não produzir um frame novo por refresh |
| Complete FPS | Frames remontados e aceitos pelo core receptor por segundo | Ainda não implica decode nem apresentação |
| Decode FPS | Frames decodificados com sucesso, por stream | O contador atual do Mac mede este estágio |
| Submitted FPS | Frames únicos submetidos à apresentação | Submissão não garante que o display os mostrou |
| Displayed FPS | Frames únicos efetivamente apresentados, correlacionados com frame ID e observação de apresentação | Separar refresh repetido, compositor e frames descartados |
| Frame pacing | Distribuição dos intervalos entre frames apresentados e distância ao intervalo esperado | Reportar p50/p95/p99, desvio e séries temporais, não só média |
| Drop rate | Fração descartada em cada estágio, com causa | Separar perda de rede, deadline, dependência, decoder e apresentação |
| Freeze | Intervalo sem frame novo maior que `max(100 ms, 3 × intervalo esperado)` enquanto a origem segue gerando | Não contar cena parada como congelamento |
| Latência local cliente | Último fragmento necessário recebido → decode pronto → submissão/apresentação observada | Medir no mesmo relógio; distinguir disponibilidade de frame e início de decode |
| Latência local host | Captura → encode concluído → envio | Spans do relógio do host |
| RTT | Ida/volta do protocolo, descontando hold time conforme contrato | RTT/2 não prova latência unidirecional nem input→photon |
| Input→photon | Evento físico/estímulo conhecido até alteração visível no display do cliente | Instrumento óptico ou correlação ponta a ponta validada |
| Conexão | Pedido do usuário → handshake → primeiro frame visível → input aceito | Separar conexão fria, encoder aquecido e reconexão |
| Banda | Bytes/s de payload de vídeo, FEC, retransmissão, controle e total de UDP | Informar também overhead IP/túnel quando medido; não misturar as bases |
| Recursos | CPU total e por thread, RAM privada/commit, VRAM, motores GPU, handles, threads, filas e cópias | Coletar média, pico, tendência e estado após teardown |
| Recuperação | Primeiro dano/interrupção e restabelecimento do caminho → primeiro frame íntegro + input funcional | Reportar os dois intervalos para não atribuir tempo sem rede ao decoder |

No Windows, usar QPC para intervalos locais conforme [orientação da Microsoft](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps).
Não subtrair diretamente timestamps de captura Mac de QPC Windows; clocks diferentes exigem sincronização com erro estimado ou um instrumento externo.
O campo de microssegundos de 32 bits dá a volta em aproximadamente 71,58 minutos; ensaios acelerados e soak devem atravessar esse limite.

Usar eventos internos e ETW/PresentMon para correlacionar frame ID, decode, GPU e apresentação; consultar as opções da [versão fixada do PresentMon](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md), incluindo rastreamento de vídeo quando disponível.
Métricas de input de uma ferramenta precisam ser associadas ao input remoto correto; uma coluna de latência local não demonstra por si só o percurso completo Windows→Mac→Windows.
Calibrar o custo da própria instrumentação comparando uma célula com logging mínimo versus detalhado.

## Metas iniciais de aceitação

Estas metas são propostas de engenharia para orientar E03 e serão congeladas depois do primeiro baseline confiável, com justificativa registrada para qualquer mudança.
Não são promessas nem resultados obtidos pela RTX.
Perfil de referência: um stream 1080p60 SDR, HEVC Main 8-bit, rede cabeada sem perda induzida, RTT até 2 ms, monitor de pelo menos 60 Hz e origem comprovadamente entregando 60 frames/s.
4K, múltiplos streams e WAN terão limites específicos aprovados antes do teste final.

| Dimensão | Meta proposta | Gate |
| --- | --- | --- |
| Correção/protocolo | Todos os vetores e invariantes obrigatórios passam, sem divergência de bytes nem estado | M1/M2 |
| FPS em conteúdo dinâmico | Pelo menos 99% dos frames produzidos pela origem na janela medida são exibidos; drops de apresentação abaixo de 1% | M3, sob capacidade verificada da origem/display |
| Atraso local do cliente | p95 do último fragmento ao frame pronto para apresentação ≤ 1 intervalo de frame; p99 ≤ 2 intervalos | M3; medir apresentação separadamente |
| Fila de vídeo | Sem tendência crescente; limite inicial de idade de 2 intervalos antes de ressincronizar, ajustado por dependências | M2/M3 |
| Input→photon LAN | p95 ≤ 80 ms em 60 Hz, com instrumento e incerteza descritos | Meta inicial de M3; não derivada de RTT |
| Conexão | p95 ≤ 3 s fria e ≤ 1 s com host aquecido, em 30 tentativas por modalidade | M3 |
| Reconexão | p95 ≤ 8 s após restabelecimento do caminho no perfil atual, incluindo silêncio/novo handshake | M3; reduzir se a implementação evoluir |
| Recuperação de vídeo | p95 ≤ 1 s após fim de burst de até 100 ms ou após IDR necessário, em cenários de RTT até 60 ms | M4 |
| Congestionamento | Após queda de capacidade, fila volta ao orçamento e taxa se ajusta em até 5 s; subida gradual sem oscilação sustentada | M4, com controlador host implementado |
| Input/ciclo de vida | Zero teclas/botões presos e zero evento aplicado à sessão/display errado | M3/M5 |
| Estabilidade | Zero crash, hang, OOM, device leak ou reconnect não explicado em 8 h/24 h | M3/M5 |
| Memória sustentada | Após warm-up e caches estabilizados, crescimento ≤ 5% e ≤ 100 MiB em 8 h; nenhuma tendência monotônica sem platô | Meta de diagnóstico; budget absoluto definido em E02/E03 |
| Regressão | Aumento > 10% em p95 local ou CPU/VRAM do mesmo cenário exige análise e repetição antes de aceite | E11; tolerância calibrada com variância real |

Não somar p95 de spans diferentes para apresentar um suposto p95 fim a fim.
Correlacionar a contagem por frame ID, descontando somente warm-up e transições declaradas antes do ensaio; frames perdidos ou descartados por deadline continuam no denominador da entrega fim a fim.
CPU/GPU máximas absolutas e budget RAM/VRAM serão fixados após medir o custo por superfície e stream; registrar explicitamente a decisão em E03, sem inventar um limite universal.
Quando origem, link ou monitor não sustentam um perfil, classificar a limitação e medir o decoder isoladamente; isso não aprova o perfil fim a fim.

## Corpus e oráculos de correção

- C01 — Vetores do projeto para Noise, X25519, AEAD, chunks, frame headers e exemplos publicados, com hash e origem.
- C02 — Três bitstreams e manifests de `windows-validation` no SHA `d38aaade7936660f62bc4b52a230cbd7dc78f2af`: `videotoolbox-idr`, `videotoolbox-ltr-ack-every-frame` e `videotoolbox-ltr-ack-every-250ms`.
- C03 — Clips novos em 1080p, 1440p e 2160p, 60/120 FPS quando suportados, com frame ID visível, moving bars, checkerboard, gradientes e texto fino.
- C04 — Sequências de desktop controladas: scroll, terminal/texto, movimento amplo, alternância de janelas e cena estática, sem conteúdo pessoal.
- C05 — Bitstreams/pacotes inválidos: truncamento em cada offset, comprimento excessivo, parâmetros vazios, NAL inválido, shards inconsistentes e configurações que mudam entre frames.
- C06 — Traces sintéticos de input e rede com seeds fixadas, relógio virtual e resultado esperado.

Os streams LTR de C02 são probes de compatibilidade do decoder, não confirmação de suporte a LTR no cliente/host atual.
Repetir as perdas descritas no manifest/brief, preservando o ID original dos frames; no cenário que remove frames 40–45, conferir o resultado a partir do frame 46 conforme as dependências reais.
Não alinhar imagens apenas pela posição na lista, pois a sequência com perda tem menos frames.
Comparar decode completo versus com perdas no mesmo backend para verificar recuperação; comparar software versus hardware com uma tolerância previamente justificada quando a saída legítima não for bit a bit idêntica.
Normalizar stride, cropping e planos YUV antes de hash ou diferença, e não confundir diferenças de conversão RGB com erro de decode.

O IDR de 16×16 já existente serve ao teste atual Mac, mas não deve ser o único fixture Windows; o [MFT HEVC documenta restrições de dimensões e formato](https://learn.microsoft.com/en-us/windows/win32/medfound/h-265---hevc-video-decoder).
Gerar fixtures maiores compatíveis e manter o pequeno como teste de recusa controlada onde não for suportado.

## Testes de protocolo, segurança e limites

| ID | Ensaio | Resultado obrigatório |
| --- | --- | --- |
| P01 | Parse/encode de todos os campos, limites, endianness e truncamento em cada byte | Igualdade com vetores; erro controlado; nenhum acesso fora de bounds |
| P02 | Noise com PSK correta/incorreta, transcript alterado, timestamp fora da janela, INIT duplicado e RESPONSE perdida | Autenticação/derivação corretas; resposta cacheada conforme contrato; nenhuma credencial em log |
| P03 | AEAD inválido, replay, janela 2048, packet number truncado e wrap por relógio/contador virtual | Não atualizar estado de peer/replay antes da autenticação; aceitar/rejeitar exatamente o contrato |
| P04 | Negociação, early buffer cheio, streams desconhecidos, direção/classe inválidas e chunks must-ignore | Recursos limitados e descarte correto sem derrubar streams válidos |
| P05 | Reliable com ACK atrasado/perdido, mensagens fora de ordem, segmentos duplicados/inconsistentes, fila 1024 e key-up subsequente | Ordem e entrega corretas; backpressure explícito; release/reset garantido |
| P06 | FEC sem perda e até/acima da capacidade; parity-first; `lastLength` 0/stride/stride+1; contagens e padding inválidos | Recuperação exata quando possível; rejeição ou fallback sem trap quando impossível |
| P07 | NACK disperso, muitos ranges, reliable e feedback com MTU 256/512/1200/9000 no simulador | Todo datagrama respeita o limite; ranges divididos e nenhum frame esquecido |
| P08 | PREVIOUS/IDR, frame antigo, configuração vazia, resolução alterada, NAL truncado e callback de geração velha | Sem decode indevido; pedir recovery com rate limit; ignorar resultado obsoleto |
| P09 | Muitos streams/frames/segmentos e slow consumer com budgets pequenos no harness | Uso limitado por bytes e metadados; descarte documentado, sem OOM e sem starvation |
| P10 | Peer muda IP/porta, pacote antigo de outro endereço, nova IP sem feedback e SESSION_UNKNOWN inválido | Migração só quando válida; limite de amplificação preservado; envio usa peer efetivo |
| P11 | Fuzz de parser/máquina de estado com ASan/UBSan ou ferramentas equivalentes suportadas | Nenhum crash/UB/loop infinito; seed de qualquer falha vira regressão |
| P12 | Pairing malformado, truncado, revogado, arquivo local corrompido e acesso de outro usuário | Erro claro, proteção por usuário, nenhuma perda silenciosa do pairing anterior |

Fuzz inicial: até 30 minutos por alvo em desenvolvimento e campanha de 8 horas no candidato, com limite de CPU/memória e corpus persistido.
Não usar ausência de falha em um período de fuzz como prova de ausência de vulnerabilidades.
Auditar tamanho antes de alocar e autenticidade antes de aceitar estado, mas também testar peers autenticados com dados inválidos: R01 foi exatamente esse tipo de lacuna.

## Integração, input e ciclo de vida

| ID | Cenários | Evidência de aprovação |
| --- | --- | --- |
| L01 | Connect/cancel/reconnect, host encerrado/reiniciado, silêncio 2/5/60 s e cache aquecido | Estados e timers esperados; nenhum callback na geração errada |
| L02 | Alt-Tab, focus loss, minimize, close, fullscreen, key repeat e saturação reliable | Teclas/botões liberados; só janela ativa envia input |
| L03 | Mudança de resolução/configuração com decoder ocupado e frames pendentes | Troca atômica por geração, superfícies liberadas, imagem válida após recovery |
| L04 | 1/2/4 streams, mesmo display em duas janelas, remoção do primário e hot-plug | Bindings corretos, fallback explícito, budgets respeitados e teardown completo |
| L05 | ABNT2/US, modificadores, acentos dentro do recurso suportado, teclas estendidas, scroll e cinco botões | Host recebe usos/flags/unidades corretos; limites de IME/texto documentados |
| L06 | DPI 100/125/150/200%, letterbox, janela entre monitores e coordenadas nas bordas | Ponteiro remoto acerta alvos conhecidos; sem offset ou display errado |
| L07 | Lock/unlock, suspend/resume e console↔RDP em ensaio reservado | Recuperação ou erro explícito; liberação de input e recursos |
| L08 | Device removed/reset simulado no adapter, decoder indisponível e software lento | Timeout/cancelamento, fila limitada, fallback identificado ou erro orientado |
| L09 | 100 ciclos de conexão e 100 ciclos de janela/display em harness | Sem crescimento de handles/threads/memória após estabilização |
| L10 | Instalar, atualizar, rollback, desinstalar, paths Unicode/espaços e usuário comum | Binário inicia, dados corretos, remoção/preservação conforme escolha e sem admin em uso normal |

Device reset deve ser preferencialmente injetado por mock ou falha controlada do processo.
Não reiniciar o driver de toda a máquina compartilhada como primeiro mecanismo de teste.

## Campanha inicial de desempenho: até 48 células

Para evitar uma explosão de combinações, a primeira campanha usa no máximo 48 células nomeadas: 12 baseline + 8 decoder + 16 rede + 12 compatibilidade.
Um gerador de casos deve aplicar explicitamente o teto e informar os casos omitidos; não expandir automaticamente o produto cartesiano de todas as dimensões.
Casos exploratórios sem hardware/origem adequados ficam pendentes, sem substituição silenciosa por cenário mais fácil.
Depois da campanha, ampliar apenas as combinações que mostrem interação problemática ou sejam necessárias para a plataforma prometida.

Procedimento padrão por célula de desempenho: 30 s de warm-up, 120 s de coleta e três repetições com ordem alternada.
São até 6 horas de coleta incluindo warm-up para 48 células, mais preparação, mudanças de cenário, análise e ensaios funcionais; soak, fuzz e medições ópticas têm orçamento separado.
Para diferenças pequenas ou resultados instáveis, fazer cinco repetições de 300 s nas células finalistas, sem repetir a matriz inteira.
Não juntar todas as execuções em um único histograma sem preservar variação entre runs.

### Baseline B01–B12

Bitrates abaixo são configurações iniciais por stream, não garantias de qualidade nem equivalência entre cenas.
Registrar payload efetivo e overhead: o parâmetro do host pretende incluir paridade, mas mínimos de shards, cabeçalhos e retransmissões mudam o total real.
Manter o mesmo host e backend aprovado para B01–B12, variando apenas o que a linha descreve.

| ID | Resolução/FPS de origem | Taxa inicial / FEC | Propósito |
| --- | --- | --- | --- |
| B01 | 1920×1080 / 60 | 20 Mb/s / 0% | Base mínima sem recuperação por paridade |
| B02 | 1920×1080 / 60 | 20 Mb/s / 10% | Perfil principal LAN |
| B03 | 1920×1080 / 120 | 40 Mb/s / 10% | Refresh alto, se origem/display sustentarem |
| B04 | 2560×1440 / 60 | 40 Mb/s / 10% | Desktop de maior resolução |
| B05 | 2560×1440 / 120 | 60 Mb/s / 10% | Exploratório de alta taxa |
| B06 | 3840×2160 / 60 | 80 Mb/s / 10% | Perfil 4K principal |
| B07 | 3840×2160 / 120 | 120 Mb/s / 10% | Exploratório; separar decoder isolado de fim a fim |
| B08 | 2 × 1080p60 | 20 Mb/s por stream / 10% | Escala e independência entre janelas |
| B09 | 4 × 1080p60 | 20 Mb/s por stream / 10% | Limite inicial de quatro streams |
| B10 | 1080p60 + 1440p60 | 40 Mb/s por stream / 10% | Resoluções distintas sem supor bitrate individual já disponível |
| B11 | 1440p, cena estática | 40 Mb/s / 10% | Ociosidade, CPU/GPU, ausência de falsos freezes |
| B12 | 4K60, scroll/texto | 80 Mb/s / 10% | Legibilidade, cores e carga de desktop |

Para 120 FPS, confirmar que o host realmente entrega essa taxa e que o display pode mostrá-la.
Se não puder, executar o clip local a 120 FPS para medir decode, mas marcar a célula fim a fim como não avaliada.
O histórico de outro Mac em `notes/` não substitui a medida da origem usada nesta campanha.

### Decoder D01–D08

Executar quatro condições em cada um de dois backends candidatos, totalizando oito células: 1080p60, 1440p60, 4K60 e recuperação no corpus C02.
Usar exatamente os mesmos bytes e framing adaptado corretamente; habilitar modo de baixa latência onde suportado e registrar a configuração aplicada.
Coletar tempo de submissão→saída, profundidade de superfícies, custo de conversão/cópias, consumo e resultado visual.
O decode software é o oráculo adicional e o teste de fallback funcional; não incluí-lo como terceiro protótipo de produção completo.
NVDEC direto só entra numa segunda rodada caso os dados indiquem problema ou vantagem relevante que MF/D3D11VA não resolvam.

Para apresentação, comparar máximo de 1 versus 2 frames em uma célula finalista e reportar tearing/VRR/vsync; essas repetições adicionais devem constar do orçamento.
A API de espera e seus requisitos estão em [GetFrameLatencyWaitableObject](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_3/nf-dxgi1_3-idxgiswapchain2-getframelatencywaitableobject).

### Rede N01–N16

Base: B02, seed fixada, bitrate real monitorado e apenas o fluxo de teste afetado.
Delay indicado é RTT alvo total; aplicar metade em cada sentido quando a ferramenta modelar delay unidirecional, e registrar assimetria quando diferente.
Os valores de perda são de datagramas, sem pressupor equivalência com perda de frames.

| ID | Condição | O que observar |
| --- | --- | --- |
| N01 | LAN cabeada sem impairment | Controle de comparação |
| N02 | RTT 20 ms, jitter 5 ms, perda 0,1% | Rede moderada |
| N03 | RTT 60 ms, jitter 10 ms, perda 0,5% | Rede remota típica do ensaio |
| N04 | RTT 100 ms, jitter 20 ms, perda 1% | Deadline/recuperação sob atraso |
| N05 | RTT 200 ms, jitter 50 ms, perda 3% | Degradação severa com limite de recursos |
| N06 | Perda 5% somente host→cliente | Recuperação de mídia e qualidade reduzida |
| N07 | Perda 5% somente cliente→host | ACK/NACK/input e risco de tecla presa |
| N08 | Reordenação 5% + duplicação 1%, RTT 20 ms | Janela, deduplicação e entrega ordenada |
| N09 | Bursts de 100 ms a cada 10 s, FEC 10% | Freeze, IDR e recovery |
| N10 | Mesmo trace N09, FEC 20% | Benefício versus overhead, mesma banda total |
| N11 | Interrupção completa de 10 s e retorno | Silêncio, novo handshake e ausência de input antigo |
| N12 | Capacidade 80→12→80 Mb/s em patamares de 30 s | Adaptação abaixo da demanda e recuperação sem fila crescente |
| N13 | Caminho aceita 1200, cai para 1000 bytes e volta | Blackhole de MTU, erro/renegociação/reconexão explícita |
| N14 | IPv6 e mudança de porta/IP autenticada durante stream | Peer efetivo, anti-replay e limite de amplificação |
| N15 | Tailscale com caminho direto confirmado | Overhead real do túnel |
| N16 | Tailscale via DERP confirmado, quando reproduzível | Relay identificado e capacidade real; não rotular como direto |

P07 cobre limites extremos de MTU em simulação; na rede real só testar tamanhos suportados pelo caminho.
Não assumir que a baseline tem PMTU dinâmico: N13 pode exigir reconnect com novo tamanho, e isso deve aparecer no resultado.
Expandir posteriormente bursts de 10/50/250 ms, perdas correlacionadas, mudança Wi-Fi↔Ethernet e coexistência com tráfego concorrente, conforme os problemas encontrados.
Congestionamento N12 só aprova M4 depois de E10; antes disso registra-se a limitação da taxa fixa.

### Compatibilidade X01–X12

As células X são ensaios funcionais com trecho de desempenho quando aplicável; hardware ausente significa pendência.
Escolher as builds e drivers exatos após inventário e verificar o suporte publicado pelos fornecedores na data de execução.

| ID | Plataforma/condição | Critério |
| --- | --- | --- |
| X01 | RTX 4090, Windows 11 x64, driver instalado | Referência inicial identificada |
| X02 | RTX 4090, segunda versão de driver compatível em janela reservada | Regressão de codec/apresentação; sem alteração durante trabalho compartilhado |
| X03 | Segunda build Windows 11 suportada, em máquina/imagem de teste | Build/install/codec/input |
| X04 | Windows N sem componentes de mídia necessários | Diagnóstico correto ou backend alternativo aprovado |
| X05 | HEVC ausente/indisponível | Fluxo legível de disponibilidade/fallback, sem tela preta |
| X06 | GPU Intel integrada | Decode hardware real, budget e apresentação |
| X07 | GPU AMD | Interoperabilidade D3D11 e qualidade |
| X08 | NVIDIA de menor capacidade ou modo software controlado | Degradação limitada e sem filas ilimitadas |
| X09 | Notebook com GPU híbrida/adapters distintos | Seleção/mudança e custo de cópia entre GPUs |
| X10 | Monitores mistos 60/120/144 Hz e DPI distinto | Frame pacing e coordenadas corretas |
| X11 | Desktop HDR ligado e stream SDR | Cor consistente; não significa suporte HDR do protocolo |
| X12 | Sessão console/RDP, lock e suspend/resume | Recuperação conforme política e backend identificado |

HEVC pode depender de componentes opcionais conforme a [lista de codecs Microsoft](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/supported-codecs), e edições N exigem tratamento específico de [recursos de mídia](https://support.microsoft.com/en-us/windows/media-feature-pack-for-windows-10-11-n-february-2023-2aaf89b8-f9d3-4322-98d0-612c9bea9c01).
Uma instalação bem-sucedida na RTX não resolve essas diferenças de distribuição.

## Latência óptica, conexão e comparações justas

Para input→photon, usar uma aplicação de teste no host que altera uma área de cor e registra um ID ao receber o evento.
Filmar o estímulo físico identificável e a resposta na tela do cliente no mesmo quadro, ou usar um dispositivo que registre ambos com relógio comum.
Com câmera de 240 FPS, a granularidade é aproximadamente 4,17 ms por frame; registrar também exposição, scanout, rolling shutter e incerteza de identificar o evento inicial.
Não usar apenas o frame em que a mão parece começar a mover como timestamp preciso de clique.
Obter ao menos 100 eventos por condição para exploração e 500 para confirmar p95; usar dados suficientes ou intervalo de confiança antes de divulgar p99.
Comparar janela/fullscreen e backend somente mantendo conteúdo, monitor, FPS, rede e estímulo iguais.

Para conexão, fazer 30 tentativas frias e 30 aquecidas, registrar mediana/p95/máximo e falhas.
Não interpretar p99 de 30 observações como uma medida robusta de cauda.
Não apagar pairings ou reiniciar a máquina para simular conexão fria: distinguir processo frio, encoder frio e pareamento novo como condições diferentes.

Comparações obrigatórias: cliente Mac atual versus Windows no mesmo host/perfil; decoder hardware versus software em corpus conhecido; MF versus D3D11VA; FEC e parâmetros de apresentação em traces iguais; LAN versus túnel com rota documentada.
Cliente Mac e Windows têm hardwares/monitores distintos, portanto a comparação ponta a ponta mostra o sistema completo, não uma atribuição causal isolada ao SO.
Ferramentas/produtos externos podem servir de referência posterior, desde que codec, bitrate, resolução, conteúdo e forma de medir sejam declarados; não são oráculo de compatibilidade Lightray.

## Estabilidade, soak e falhas longas

| Duração | Momento | Carga e eventos | Aprovação |
| --- | --- | --- | --- |
| 30 min | M2 | Um stream dinâmico, sem impairment | Sem crash, backlog crescente ou imagem corrompida |
| 8 h | M3 | Dois streams, mudanças de janela/resolução e ciclos de input sintético | Sem vazamento, teclas presas ou recursos órfãos; atravessa wrap de timestamp |
| 24 h | M5 | Perfis aprovados, pequenas perdas e reconexões programadas | Estabilidade e recuperação consistentes, logs/armazenamento limitados |
| 72 h | Candidato de release, laboratório reservado | Mix representativo com intervalos estáticos/dinâmicos | Confiança adicional; não substitui compatibilidade nem testes determinísticos |

Coletar contadores de recursos a cada segundo e snapshots agregados a cada minuto, sem salvar uma imagem de cada frame.
Comparar estado após 15 minutos de warm-up, no meio, no fim e depois de fechar todas as sessões.
Investigar crescimento por cache versus vazamento por inclinação/platô e ciclos repetidos; registrar o critério antes de selecionar trechos convenientes.
Incluir passagem acelerada dos limites de clock/packet/frame IDs em testes unitários, além do tempo real.
Se ocorrer falha, preservar últimos eventos e minidump redigido, interromper a célula afetada e reproduzir com a menor sequência possível.
Retestar a correção e os cenários dependentes; não repetir todas as 72 horas a cada mudança documental.

## Automação, CI e formato dos resultados

| Frequência/ambiente | Checks | Limitação |
| --- | --- | --- |
| Cada mudança de core | Unitários, vetores, simulador, casos R01–R08 e budgets | Sem apresentação real |
| Cada mudança Windows | Build x64, unitários, adapters com mocks, smoke de pacote | Runner comum pode não ter HEVC/GPU/display |
| Integração em laboratório | Corpus hardware, Mac↔Windows, input sintético e ciclo de vida | Registrar sessão e carga concorrente |
| Candidato de versão | Matriz obrigatória, compatibilidade, fuzz longo, soak e instalação | Exige equipamentos e janela de laboratório |

Não presumir disponibilidade contínua da RTX como runner público ou executar código não confiável de PRs no computador pessoal.
Jobs de hardware devem usar checkout/artefato aprovado, conta apropriada e escopo de execução definido.
Este plano não cria automações ou agendamentos; a execução será registrada item a item.

Formato proposto para cada run:

```text
results/<campaign>/<case-id>/<run-id>/
  manifest.json
  metrics.csv
  events.jsonl
  summary.json
  report.md
  traces/
```

Campos mínimos do manifest: `schema_version`, `run_id`, `case_id`, `host_sha`, `client_sha`, `dirty`, `wire_profile`, `fixture_sha256`, `os_build`, `gpu`, `driver`, `decoder_backend`, `adapter_id`, `display_hz`, `resolution`, `source_fps`, `bitrate_config`, `fec_config`, `mtu`, `network_profile`, `seed`, `warmup_seconds`, `measurement_seconds`, `tool_versions` e `clock_uncertainty_ms` quando aplicável.
Campos mínimos por amostra: timestamp monotônico relativo ao run, stream ID, geração, frame ID, estágio, duração, queue depth/age, bytes por classe, drop reason e uso de recursos.
O resumo registra amostras, falhas, dados ausentes, percentis, variância entre runs, alvo aplicado e conclusão `aprovado`, `reprovado`, `inconclusivo` ou `não executado`.
Guardar dados brutos suficientes para recalcular métricas; arredondar apenas na apresentação do relatório.

## Regras de decisão

- Um crash, OOM, corrupção persistente ou tecla presa reprova o caso, mesmo quando as médias de FPS são boas.
- Meta não medida, ambiente ausente ou teste interrompido não é aprovação.
- p99 sem amostra suficiente deve ser omitido ou marcado exploratório com sua incerteza.
- Perda induzida deve ter taxa observada, não apenas configurada; registrar descartes do próprio gerador e do kernel.
- Regressão exige investigação com a mesma revisão/configuração de referência; não comparar Debug com Release.
- Ao alterar objetivo, escopo ou tolerância, registrar a decisão antes da homologação e preservar o resultado anterior.
- Nenhum gate Windows fica verde apenas porque os testes Mac passaram.

## Estado inicial verificado

Em 28/09/2026, a [baseline Mac](../reviews/2026-09-28/evidence/README.md) passou em 64 testes de produto (59 core + 5 adaptadores), 11 testes do gerador, 15 blocos documentais e build release.
Cinco comportamentos defeituosos foram reproduzidos por probes; o crash de FEC foi isolado em subprocesso.
A presença da RTX no Tailscale foi confirmada, mas a identidade SSH ainda aguarda confirmação e o inventário nativo não foi coletado.
Todos os cenários Windows deste documento permanecem não executados.

A execução posterior das correções locais e seus novos resultados estão no [registro de execução](foundation-progress.md); as células Windows continuam não executadas.
