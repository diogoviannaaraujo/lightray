# Parsec como referência: métricas, teclado e experiência de sessão

## Decisão e escopo

Investigação em 29/09/2026 para orientar o caminho cliente Mac → host Windows do Lightray, com prioridade confirmada pelo usuário para copiar/colar, Alt+Tab e tecla Windows.
Foram confrontadas cinco páginas oficiais do Parsec, a documentação de `SendInput`, o código atual do Lightray e uma sessão real na RTX 4090.
Esta é uma comparação de recursos e decisões de implementação; não foi executado um benchmark A/B com o binário do Parsec.
O primeiro incremento já está implementado e testado: painel visível em tela cheia, RTT/decode/fila em milissegundos, troca opcional Command↔Control, atalhos explícitos no host e liberação da entrada remota.

## O que aproveitar da referência

### 1. Mostrar onde o tempo é gasto

O Parsec apresenta rede como RTT, separa encode e decode, e oferece gráficos com captura e intervalos entre frames.
Sua documentação distingue métricas por etapa e mostra avisos de dificuldades de rede ou processamento.
Essa separação permite investigar uma sessão lenta sem atribuir todo atraso à conexão. [Fonte: métricas e overlay do Parsec](https://support.parsec.app/hc/en-us/articles/32381603663636-Stream-Overlay-Stats-and-Logging).

No Lightray, a RTT já existia no título da janela, mas desaparecia visualmente em tela cheia; encode e captura estavam apenas no CSV Windows.
Agora o painel apresenta RTT suavizada, média de decode e média de espera entre a montagem completa do frame e o início do decode, além de FPS decodificados, tráfego da conexão, perdas e descartes da fila.
Os tempos locais usam exclusivamente o relógio monotônico do Mac; não subtraímos o timestamp do Windows do relógio do Mac.
Sem amostras válidas de decode, o painel mostra um traço; desconexões substituem as métricas pelo estado da sessão.

Decisão: não exibir uma soma chamada “latência total”, nem inventar encode a partir da RTT.
A próxima etapa deve transportar durações de captura e encode medidas no host, e instrumentar a apresentação separadamente.
O limite de 11,111 ms por frame a 90 FPS é um orçamento de cadência, não uma meta automática de latência completa.

### 2. Adaptar atalhos sem perder a tecla Windows

A documentação específica do Parsec descreve o mapeamento Control→Ctrl, Option→Alt e Command→Windows, e a opção que troca Command com Control para facilitar atalhos entre os sistemas. [Fonte: troca de Command/Control](https://support.parsec.app/hc/en-us/articles/32361367389972-Swap-Command-and-Ctrl-for-MacOS).

No Lightray, o perfil físico continua sendo o padrão, preservando o uso com outros hosts.
O perfil opcional Command↔Control envia ⌘C/⌘V como Ctrl+C/Ctrl+V ao Windows, enquanto Control passa a representar a tecla Windows.
Os lados esquerdo e direito continuam distintos; Option/Alt não é alterado.
Ao trocar o perfil, teclas já pressionadas são liberadas usando o mapeamento anterior, evitando um key-up para uma tecla diferente da que recebeu key-down.

Decisão: oferecer também ações explícitas “Send Alt+Tab”, “Send Windows Key” e “Send Ctrl+Esc” no menu.
Essas ações enviam sequências completas de pressão/liberação e não dependem do perfil físico selecionado.
Copiar/colar dentro do Windows já foi validado; sincronizar o clipboard entre Mac e Windows é outro recurso e permanece pendente.

### 3. Reservar uma saída local previsível

O Parsec documenta atalhos para menu, tela cheia, modo imersivo e liberação de entrada, permitindo personalização das combinações. [Fonte: Configure Hotkeys](https://support.parsec.app/hc/en-us/articles/32381778420372-Configure-Hotkeys).

Para este incremento, o Lightray mantém o prefixo local já usado para sair, Control+Option+Command, e o estende às novas ações.
Isso preserva combinações usuais como ⌘C/⌘V para o host.
O atalho de liberação solta teclas e botões, deixa de encaminhar teclado/mouse/rolagem e mostra um estado visível; o primeiro clique apenas retoma a entrada, sem clicar acidentalmente em um aplicativo remoto.
Perda de foco, desativação do app, fechamento e encerramento também liberam a entrada mantida pelo cliente.

Decisão: personalização de atalhos deve vir depois de uma política explícita de conflitos e de um comando de recuperação que sempre permaneça acessível.
O estado de teclado deve continuar separado de widgets, para que reconexão e troca de tela possam ser testadas sem injetar eventos reais no sistema.

### 4. Diferenciar atalhos recebidos de captura imersiva do sistema

No macOS, o Parsec associa o modo imersivo ao modo HID e à permissão de Acessibilidade, e documenta que a janela precisa estar ativa para encaminhar a entrada corretamente. [Fonte: aplicativo Parsec para macOS](https://support.parsec.app/hc/en-us/articles/32381394408596-Parsec-App-for-macOS).

O Lightray deste incremento usa monitor local de eventos AppKit e ações explícitas no menu.
Isso não implementa captura global de Command+Tab, atalhos do sistema ou um modo imersivo equivalente ao Parsec.
A alternativa implementada para Alt+Tab funciona sem interceptar o alternador de aplicativos do Mac.

Decisão: tratar captura HID/event tap como etapa própria, com ativação voluntária, foco estritamente delimitado, comportamento definido quando a permissão for negada e liberação garantida quando a sessão terminar.
Nenhuma nova permissão de Acessibilidade foi concedida automaticamente nesta rodada.

### 5. Medir a experiência, além dos números do painel

O guia do Parsec reconhece que a sensação de atraso pode exceder os tempos de encode, decode e rede mostrados, e considera diferenças de frequência entre host e cliente ao investigar fluidez. [Fonte: diagnóstico de latência](https://support.parsec.app/hc/en-us/articles/32381352822804-Troubleshooting-Lag-Latency-and-Quality-Issues).

No Lightray, a campanha anterior demonstrou a diferença entre frames enviados/decodificados e atualizações novas do desktop: mudar a origem de 60 para 160 Hz reduziu fortemente as reutilizações.
Por isso, o painel identifica “decoded FPS” e não “presented FPS”.
Também identifica o tráfego como sendo da conexão, porque o contador atual pode agregar mais de um stream.
O decode inclui o trabalho síncrono do backend, inclusive reconstrução da sessão quando necessária; não é uma consulta isolada ao tempo de execução da GPU.

Decisão: comparação de desempenho com Parsec deve usar o mesmo modo de tela, codec, cena, rede e duração, e registrar apresentação e resposta visual com instrumentação independente.

## Plano de execução

| Etapa | Entrega | Critério de aceite | Estado |
| --- | --- | --- | --- |
| UX01 — métricas e atalhos essenciais | Painel em tela cheia; RTT/decode/fila; Command↔Control; Alt+Tab/Windows; liberar/retomar | Testes de mapeamento e clocks aprovados, copiar/colar real, atalhos com efeito no Windows, nenhuma tecla retida | Implementada e validada no laboratório |
| UX02 — telemetria do host | Captura/conversão e encode em ms, janela de amostragem e indicação de dados ausentes | Durações do host conciliadas com CSV, compatibilidade com peers anteriores, amostras inválidas descartadas e custo do painel medido | Implementada e validada funcionalmente; custo exploratório medido em 30/09/2026 |
| UX02a — recuperação limitada DXGI | Recriar duplicação no mesmo device/geometria, prazo de falha, IDR e liberação de input | Primeiro frame, ciclos recuperáveis e falha persistente após vídeo ativo | Dez ciclos em 30/09; falha inicial em 01/10; falhas reais pendentes |
| UX03a — controles e preferências | Menu sobre o vídeo, estado da sessão, perfil persistente por host e scancodes ISO/menu/F13–F20 | Menu em janela/tela cheia, isolamento de input e perfil por host | Implementada; interface validada no Samsung sem vídeo; sessão ativa pendente |
| UX03b — teclado completo | Matriz ANSI/ISO/ABNT2, acentos, cedilha, AltGr, Caps Lock e funções | Casos de texto e teclas simultâneas nos dois perfis; troca de foco/configuração/reconexão sem teclas presas | Matriz real de texto pendente |
| UX04 — clipboard entre máquinas | Primeiro texto Unicode por ação explícita e direção definida | Limites de tamanho, cancelamento, reconexão, caracteres internacionais e ausência de conteúdo em logs | Planejada; não confundir com Ctrl+C/Ctrl+V remoto |
| UX05 — captura imersiva opcional | Captura de atalhos reservados e escape local acessível | Permissão negada/revogada, foco perdido, crash e desconexão tratados; nenhum encaminhamento fora da sessão ativa | Planejada |
| UX06 — comparação e estabilidade | Campanhas Lightray/Parsec em 1080p60, 1440p60, 4K60 e 4K90 | Mesma cena e hardware, p50/p95/p99, 30 minutos por cenário, depois 8/24 horas nos cenários aprovados | Planejada |

### Detalhamento da etapa de telemetria, concluída funcionalmente em 30/09

1. Definir a semântica de captura, conversão, encode e espera antes de definir nomes no painel; hoje o host já registra etapas locais no CSV.
2. Projetar um canal ou extensão de telemetria compatível com o protocolo, com identificação de stream/configuração, duração e idade da amostra; testar peers que não suportem o campo antes de ativá-lo por padrão.
3. Usar agregação limitada e atualização visual de baixa frequência; não criar filas de UI por frame nem arrays que cresçam durante a sessão.
4. Mostrar captura e encode separadamente, com estado indisponível quando o host não reportar, sem extrapolar a partir de clocks de máquinas diferentes.
5. Testar HUD ligado/desligado com a mesma cena, registrar custo de CPU/GPU e jitter, e impedir regressão na fila de decode ou na cadência de 4K90.
6. Só depois acrescentar alertas, baseados em duração e persistência do problema; um contador acumulado diferente de zero não deve manter um alerta de congestionamento ativo indefinidamente.

### Matriz de validação transversal

- Rede: LAN e Tailscale, RTT/jitter/perda controlados, reconexão e silêncio temporário; registrar rota e não misturar métricas de caminhos diferentes.
- Vídeo: janela/tela cheia, múltiplos streams, diferentes frequências de origem/apresentação, resolução variável e movimento em tela inteira.
- Entrada: pressionar/soltar/repetir, ambos os lados dos modificadores, atalhos locais conflitantes, foco em outra janela, mudança de perfil com teclas mantidas e fechamento durante um atalho.
- Clipboard: texto vazio, multilinha, Unicode, limites, interrupção e ausência de sincronização automática não solicitada.
- Falhas: permissão ausente, device perdido, sessão Windows bloqueada, cambio de resolução, timeout e encerramento abrupto.

O host atual usa `SendInput` no contexto do usuário, sujeito às restrições de integridade/UIPI do Windows; controle de aplicativos elevados exige projeto e validação próprios. [Fonte: Microsoft SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).
Ctrl+Alt+Del, tela segura, serviço Windows, áudio, clipboard compartilhado e equivalência completa ao Parsec não são entregas deste incremento.

## Evidência e limites

A comparação de produto se baseia na documentação oficial consultada, não em engenharia reversa ou acesso ao código do Parsec.
As recomendações e os critérios de aceite são decisões propostas para o Lightray, não alegações sobre a implementação interna do Parsec.
Os testes locais do Lightray e a rodada Windows `desktop-018` estão detalhados no [relatório de implementação](../windows/client-ux-progress.md).
A [campanha 4K90 anterior](../windows/host-4k90-progress.md) permanece separada: esta rodada de funcionalidades detectou a origem Windows a 60 Hz e não modificou sua frequência.

Atualização em 30/09/2026: [UX02 validada, comparação do painel e pendência de recuperação DXGI](../windows/host-telemetry-progress.md).
A recuperação limitada de captura (UX02a) passa a preceder a expansão de teclado UX03.

Atualização em 01/10/2026: [recuperação limitada e ausência de primeiro frame](../windows/capture-recovery-progress.md), [controles da sessão e preferências](../windows/session-controls-progress.md) e [plano detalhado com gates por fase](../windows/product-validation-plan-2026-10-01.md).
O monitor Samsung U28E590 fica reservado à interface; sua frequência reportada de 60 Hz exige separar validação de decode de certificação de 90 FPS apresentados.

Investigação complementar em 01/10/2026: [matriz de lacunas, detalhes de uso e ordem recomendada](parsec-parity-2026-10-01.md), com 18 incrementos e referências oficiais adicionais.
