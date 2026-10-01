# Evidências do decode 1440p/4K

- `corpus-manifest.json`: comandos VideoToolbox, versão do encoder e hashes/tamanhos dos arquivos de entrada preservados nos laboratórios.
- `mac-software/`: referência de pixels, 120 frames em cada resolução.
- `windows-software/`: decode nativo Windows por software.
- `windows-d3d11va/`: decode por D3D11VA na RTX 4090 com download NV12 explícito.
- `windows-media-foundation/`: decode MF/D3D11; todos os 240 samples expuseram buffers GPU.
- `comparison-*/`: igualdade de pixels contra a referência Mac, zero diferenças nos três backends.

Os MP4 de remux, executáveis e bitstreams sintéticos permanecem em `tools/windows/results`, ignorado pelo Git.
Arquivos `.framehash` e JSON permitem auditar os resultados; o manifesto identifica os bytes necessários à reprodução exata.
Os timestamps UTC de 29/09 correspondem à noite de 28/09 em São Paulo.
