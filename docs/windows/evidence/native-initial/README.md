# Evidências Windows nativo

- `inventory.json`: coleta PowerShell 5.1 após validação da identidade SSH.
- `platform.json`: saída nativa DXGI/D3D11/MFT, compilada com MSVC x64.
- `network.json`: amostras de discovery ping Tailscale sem endereços identificáveis.
- `native-build-tests.log`: build C++, oito testes de geometria, entrada inexistente e controle negativo de adapter, incluindo a observação inicial e a correção.
- `lab-tests.log`: treze testes Python do runner/comparador no Mac.
- `windows-lab-tests.log`: os mesmos treze testes executados no Windows.
- `docs-check.log`: 15 blocos documentais verificados, sem problemas.
- `software/`: decode Windows em software.
- `d3d11va/`: decode Windows na RTX 4090, com frames D3D11 e logs de seleção do device.
- `media-foundation/`: decode nativo com samples em GPU e aplicação da abertura visível.
- `comparison-*/result.json`: igualdade de pixels contra a referência Mac, 360 frames por backend.
- `invalid-adapter/result.json`: recusa do índice inexistente após validação por enumeração DXGI.

Cada diretório de decode contém resultado, hashes por frame e logs; os MP4 temporários do experimento MF e os binários de build permanecem no laboratório e não foram duplicados aqui.
Todas as execuções foram em sessão SSH sem janela, apresentação ou input real.
Os timestamps UTC de 29/09 correspondem à noite de 28/09 em São Paulo.
