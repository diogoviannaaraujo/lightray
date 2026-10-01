# Plano de produto e validação — Mac → Windows

Atualizado em 01/10/2026 após os incrementos de controles, conexão gráfica e captura WGC explícita.
A [execução F01/F02](connection-capture-progress-2026-10-01.md) restabeleceu vídeo/input e validou três recriações WGC, mantendo os gates amplos abaixo abertos.
Este plano complementa o [plano inicial de implementação](implementation-plan.md), o [plano de host nativo](host-implementation-plan.md) e a [matriz de validação](validation-plan.md).
As fases seguem dependências técnicas; uma entrega implementada só recebe aceite funcional depois de comportamento real e evidência de falhas.
O objetivo é aproximar a experiência de sessão do Parsec com identidade Lightray, mantendo explícitas as capacidades disponíveis.
Complemento desta revisão: [matriz de 18 incrementos para aproximar funcionalidades e detalhes de uso do Parsec](../reviews/parsec-parity-2026-10-01.md), incluindo adaptação de rede, gamepad, host instalado, displays virtuais e cor avançada.

## Estado atual

| Etapa | Estado em 01/10 | Gate de continuidade |
| --- | --- | --- |
| UX01 — HUD e atalhos essenciais | Validada no laboratório anterior | Manter regressão de foco e liberação |
| UX02 — captura/encode em ms | Implementada e conciliada com CSV; custo exploratório medido | Medição longa e apresentação independente |
| UX02a — recuperação DXGI | Dez ciclos injetados aprovados; primeiro frame falhou na rodada mais recente | Primeiro frame estável e falhas reais |
| UX03a — menu e preferências | Implementada; UI verificada no Samsung sem vídeo ativo | Novo painel dentro de sessão ativa |
| UX03b — teclado internacional | Scancodes adicionais implementados; texto internacional pendente | Matriz ANSI/ISO/ABNT2 |
| UX04 — clipboard | Pendente | Especificação, compatibilidade e limites |
| UX05 — modo imersivo | Pendente | Permissão, foco e escape garantido |
| UX06 — comparação e soak | Campanhas curtas anteriores; certificação pendente | 30 minutos, depois 8/24 horas |
| UX07 — experiência completa e distribuição | Pendente | Qualidade, áudio, onboarding e pacote revisados |

## Fase 1 — estabilizar captura e controles já implementados

1. Registrar inventário de adapter/output, modo/frequência, sessão interativa e versões do build antes de iniciar; manter a configuração do usuário e selecionar Samsung no Mac, com tela integrada como alternativa.
2. Reproduzir a ausência de primeiro frame com prazo limitado, distinguindo timeout normal de DXGI, erro de recriação, captura de output incorreto e perda de device; preservar HRESULT e counters.
3. Obter pelo menos dez inicializações consecutivas com primeiro frame e uma sessão de dez minutos com janela animada; registrar tempo handshake→primeiro decode e excluir reconexão automática como sucesso silencioso.
4. Repetir dez perdas injetadas recuperáveis e uma perda persistente depois de vídeo ativo; conferir IDR/configuração por época, mesma sessão, ausência de textura antiga submetida e liberação de input.
5. Testar bloqueio/desbloqueio e transição real de desktop em janela coordenada; modo/resolução e perda de device continuam casos de encerramento explícito até a reconstrução estar implementada.
6. Validar novo menu em janela e tela cheia com vídeo: métricas/cursor/mapeamento, Alt+Tab/Windows, primeiro clique consumido, foco dos widgets, atalho local S e escape; reiniciar o cliente para conferir perfil por host real.

Aceite: nenhum evento remoto oriundo dos widgets, nenhuma tecla/botão retidos nos casos cobertos, diagnóstico delimitado para condição não suportada e evidência do primeiro frame antes de medir a recuperação.
Não considerar screenshots de menu sem vídeo como aceite de navegação remota.

## Fase 2 — teclado e clipboard previsíveis

1. Fixar a matriz de hardware/layout: ANSI e ISO no Mac, US/US International/ABNT2 no Windows, perfis físico e Command/Control, lados esquerdo/direito e Right Option/AltGr.
2. Testar copiar/colar dentro do Windows, Alt+Tab, Windows, Ctrl+Esc, F1–F20, menu/ISO, repetição, combinações simultâneas, dead keys, acentos, cedilha e Caps Lock divergente entre máquinas.
3. Trocar foco, perfil, tela e sessão durante tecla mantida; conferir estado no host após desconexão, perda de captura, fechamento e encerramento abrupto do cliente.
4. Definir clipboard de texto Unicode por ação explícita e direção selecionada, limite de bytes, validade da sessão, cancelamento e tratamento de reconexão; negociar capacidade e manter peers antigos funcionais.
5. Implementar transporte confiável com limite global de memória e mensagens, sem registrar conteúdo; testar vazio, multilinha, emoji, caracteres internacionais, limite exato, excesso, mensagem inválida e interrupção.
6. Acrescentar ações claras “enviar texto” e “obter texto” apenas quando suportadas, distinguindo clipboard compartilhado de Ctrl+C/Ctrl+V dentro do host.

Aceite: texto esperado em aplicativo de teste, scancodes/lados corretos, reset de estado comprovado, ausência de conteúdo em logs e compatibilidade com host/cliente sem suporte à extensão.
Sincronização automática do clipboard não faz parte do primeiro incremento.

## Fase 3 — sessão com identidade Lightray

1. Consolidar tela inicial com hosts pareados, nome, disponibilidade, monitor escolhido e ação de conexão; apresentar conexão/espera/atividade/interrupção/encerramento com ações úteis de diagnóstico.
2. Usar o menu já implementado como entrada principal de ajustes durante a sessão, com acento ciano, tipografia nativa, nomes consistentes, estados desabilitados explicados e navegação por teclado.
3. Acrescentar gráficos de janela limitada para FPS/cadência, RTT, encode/decode/fila e perdas, sem filas de UI por frame; exportar diagnóstico sem dados pessoais ou pareamento.
4. Especificar mudança de qualidade/resolução/FPS/bitrate/monitor, com confirmação de configuração aceita pelo host, sequência de IDR, descarte de resultados antigos e rollback após falha.
5. Implementar reconstrução de captura/encoder para mudança de geometria antes de expor esse controle; manter host antigo com opções compatíveis e explicar capacidades indisponíveis.
6. Implementar áudio do host e seleção de saída, com mute, volume e limites de buffer; testar ausência/troca do dispositivo, silêncio, canais, drift, rede degradada e retomada.
7. Tratar cursor remoto/relativo e sensibilidade como entrega própria, com teste de confinamento, tela cheia, múltiplos displays e retorno previsível ao mouse local.
8. Projetar modo imersivo voluntário e hotkeys configuráveis com política de conflito; tratar permissão negada/revogada, focus loss, desconexão/crash e acesso permanente ao comando de liberação.

Aceite: cada controle corresponde a comportamento aplicado e confirmado, UI não perde acesso em tela cheia ou sem vídeo, configurações sobrevivem ao restart e nenhum input é encaminhado fora da sessão/foco autorizados.
Captura de atalhos do sistema depende de implementação HID/event tap; o monitor local AppKit atual não certifica essa capacidade.

## Fase 4 — conexão, desempenho e comparação controlada

| Dimensão | Campanha | Registro obrigatório |
| --- | --- | --- |
| Vídeo | 1080p60, 1440p60, 4K60 e 4K90; depois frequências adicionais suportadas | Modo/frequência da origem e cliente, codec/perfil, bitrate, frames novos/reutilizados e IDR |
| Cena | Desktop estático, janela animada, scroll/texto, movimento em tela inteira e jogo de teste | Cena e sequência repetíveis, atividade de input e aquecimento |
| Rede | LAN, Wi-Fi e Tailscale em separado; jitter/perda/burst/banda limitada controlados | Rota, RTT, perda, tempo de reconexão e limites de filas |
| Latência | Captura/encode, RTT, fila/decode, apresentação e resposta visual de input | Clocks usados, p50/p95/p99, amostras, método e erro de medição |
| Recursos | CPU/RSS/handles, GPU encode/3D/decode e energia | Escopo por processo quando disponível, counters globais identificados, crescimento ao longo do tempo |
| Compatibilidade | Versões de peers com/sem extensões, versões do Windows/macOS e drivers-alvo | Resultado de handshake, vídeo/input e fallback explícito |

1. Executar 30 minutos por cenário com aquecimento definido; começar com LAN/1080p60 e progredir somente depois de captura e input aprovados.
2. Para 4K90, usar origem capaz de fornecer atualizações adequadas e tela cliente com pelo menos 90 Hz; Samsung a 60 Hz continua útil para UI e decode, com apresentação registrada como limitada.
3. Medir apresentação usando instrumentação do renderer/display e resposta visual por método independente, como câmera de alta velocidade; não chamar a soma de RTT e decode de latência total.
4. Comparar Lightray e Parsec com mesma máquina, cena, input, modo de tela, rede e configuração equivalente; usar rodadas alternadas, repetir pares e registrar diferenças que não possam ser igualadas.
5. Medir painel ligado/oculto mantendo coleta de telemetria constante e input idêntico, para separar custo de renderização de custo de transporte/coleta.
6. Definir os limites de aceite de p95/p99 após baseline controlado e documentar qualquer mudança; 11,111 ms a 90 FPS é orçamento de cadência, não garantia de latência ponta a ponta.
7. Executar perda e silêncio temporário com filas limitadas, ausência de keyframe storm, nenhuma tecla retida e retorno visual dentro da política escolhida.

Aceite: dados brutos e recortes reproduzíveis, ausência de crashes/filas crescentes nos cenários aprovados, estabilidade da sessão e distinção explícita entre FPS recebidos, decodificados e apresentados.
Os números exploratórios de 29/30 de setembro permanecem baseline contextual e não substituem essa campanha.

## Fase 5 — soak e distribuição

1. Executar oito horas no cenário aprovado mais representativo e 24 horas no caminho principal, com reconexões/ciclos controlados; monitorar memória, handles, buffers, CPU/GPU e continuidade do input.
2. Testar permissão ausente, aplicação elevada/UIPI, usuário diferente, sessão bloqueada, firewall e host indisponível; comunicar limites sem prometer controle da tela segura ou Ctrl+Alt+Del.
3. Criar empacotamento Windows com dependências identificadas e versão coerente, e app Mac com assinatura/notarização apropriadas; testar instalação, atualização, rollback e remoção.
4. Separar logs operacionais de diagnóstico detalhado, aplicar rotação/limites e exportação revisável; pareamento e clipboard permanecem fora dos logs e pacotes.
5. Executar regressão completa dos cenários aprovados com o artefato empacotado em máquina limpa, além dos builds de desenvolvimento.
6. Atualizar manual curto de conexão, controles, monitores, diagnóstico e recuperação; entregar fontes/versionamento, checksums, evidências e limitações abertas ao desenvolvedor.

Aceite: pacote reproduzível, comportamento de sessão e dados protegidos verificados, ausência de crescimento sustentado inesperado no soak e bugs remanescentes classificados antes de chamar a versão de produção.

## Protocolo de operação do laboratório

Priorizar SSH, inventário, logs, builds e testes em segundo plano.
Usar Samsung U28E590 para interação visual e tela integrada como alternativa; confirmar IDs atuais sem ocupar os dois monitores usados pelo usuário.
Manter testes com prazo de saída, nomes próprios de tarefa/processo e firewall restrito ao laboratório; limpar e verificar processos, portas e tarefas ao encerrar.
Não alterar frequência, sessão do usuário ou driver como tentativa silenciosa de recuperação.
Se o usuário voltar a usar o Windows ou pedir parada, encerrar os testes de interação imediatamente e preservar logs.
