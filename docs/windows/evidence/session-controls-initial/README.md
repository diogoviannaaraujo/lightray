# Evidência dos controles de sessão

Incremento de 01/10/2026, interpretado no [relatório de controles](../../session-controls-progress.md).

- `ux03-baseline-swift.log` e `ux03-baseline-python.log`: 106 testes Swift e 31 Python antes das alterações.
- `ux03-final-swift.log` e `ux03-final-python.log`: 111 testes Swift e 31 Python após as alterações.
- `ux03-client-build.log`: build Release Mac do cliente atualizado.
- `ux03-native-build.log`: build Windows com 19 casos de input e 12 de recuperação aprovados.
- `ux03-ui-client.log` e `ux03-session-menu-waiting.png`: inspeção inicial em outro monitor, antes da preferência por Samsung ser aplicada.
- `ux03-samsung-ui-client.log`, `ux03-samsung-session-menu.png` e `ux03-samsung-fullscreen-menu.png`: inspeção subsequente exclusivamente no U28E590, ID 4, em janela e tela cheia.
- `ui-observations.json`: controles e estados observados, sem atribuir validação de input real ao menu sem vídeo.
- `windows-cleanup.json` e `mac-cleanup.json`: ausência de processos de laboratório ao final, com limpeza adicional Windows.
- `source-manifest.json`: hashes do código selecionado e identificação da base Git com alterações locais.
- `MANIFEST.sha256`: integridade de todos os arquivos desta pasta, exceto o próprio manifesto.

Os screenshots mostram o cliente Lightray em espera e não contêm captura de aplicativos pessoais do Windows.
O teste visual desativou persistência com `--no-preferences`; armazenamento foi validado por testes isolados de `UserDefaults`.
O atalho S possui teste de reconhecimento, mas a integração de UI retornou timeout ao tentar pressionar a combinação; o clique no botão foi o caminho visual comprovado.
Alt+Tab/Windows no painel novo e retomada dentro de vídeo ativo ainda precisam de validação real.
